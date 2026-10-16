import AppKit
import ClipCore
@testable import ClipPlatform
import Foundation
import Testing

/// Shares the parent directory and stale-run cleanup with ClipCoreTests' test homes.
let platformTestRoot: URL = {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipvault-ptests", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cutoff = Date(timeIntervalSinceNow: -600)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
        let u = root.appendingPathComponent(name)
        if ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: u)
        }
    }
    return root
}()

func tempHome() throws -> AppHome {
    try AppHome(root: platformTestRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
}

/// Renders text into a PNG (for OCR tests with known ground truth).
func renderText(_ lines: [String], size: CGSize = CGSize(width: 900, height: 300)) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
    for (i, line) in lines.enumerated() {
        (line as NSString).draw(at: NSPoint(x: 30, y: size.height - CGFloat(80 + i * 70)), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

@Suite struct VisionOCRTests {
    // AC7.1 — real Vision on known text, Chinese + English.
    @Test func recognisesChineseAndEnglish() async throws {
        let home = try tempHome()
        let url = home.tmpURL.appendingPathComponent("ocr.png")
        try renderText(["发票号码 2026-1017", "Invoice Total 128.50"]).write(to: url)
        let r = try await VisionOCR().recognize(imageAt: url)
        #expect(r.text.contains("发票号码"))
        #expect(r.text.contains("Invoice"))
        #expect(r.text.contains("128.50"))
    }

    @Test func unreadableImageThrows() async throws {
        let home = try tempHome()
        let url = home.tmpURL.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: url)
        await #expect(throws: ProviderError.unreadableImage) { try await VisionOCR().recognize(imageAt: url) }
    }
}

@Suite struct InstallerVerifyTests {
    // AC9.3 — tampered content or size is rejected.
    @Test func detectsTampering() throws {
        let home = try tempHome()
        let url = home.tmpURL.appendingPathComponent("f.bin")
        try Data("hello".utf8).write(to: url)
        let good = ModelFile(path: "f.bin", url: "", sha256: try ModelInstaller.sha256(of: url), size: 5)
        try ModelInstaller.verify(good, at: url)
        var badHash = good; badHash.sha256 = String(repeating: "0", count: 64)
        #expect(throws: InstallError.self) { try ModelInstaller.verify(badHash, at: url) }
        var badSize = good; badSize.size = 6
        #expect(throws: InstallError.self) { try ModelInstaller.verify(badSize, at: url) }
    }

    // E16 — a failed install leaves nothing behind.
    @Test func failedInstallCleansUp() async throws {
        let home = try tempHome()
        let src = home.tmpURL.appendingPathComponent("src.bin")
        try Data("abc".utf8).write(to: src)
        let m = ModelManifest(id: "broken@1", family: "coreml-clip", displayName: "x", tier: 0, dim: 4, imageSize: nil, contextLength: nil,
                              minMemoryGB: 0, imageInput: nil, textInput: nil, output: nil, tokenizer: nil,
                              files: [ModelFile(path: "a.bin", url: src.absoluteString, sha256: String(repeating: "f", count: 64), size: 3)], notes: nil)
        await #expect(throws: InstallError.self) { try await ModelInstaller(home: home).install(m) }
        #expect(!FileManager.default.fileExists(atPath: ModelPaths.directory(home: home, id: m.id).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.tmpURL.path).filter { $0.hasPrefix("model-") }
        #expect(leftovers.isEmpty)
    }
}

/// Real MobileCLIP, installed from local copies via file:// URLs (no network).
/// Set CLIPVAULT_TEST_MODELS to a directory holding mobileclip_s0_{image,text}.mlpackage + vocab.json + merges.txt.
let localModels = ProcessInfo.processInfo.environment["CLIPVAULT_TEST_MODELS"]

@Suite(.enabled(if: localModels != nil, "set CLIPVAULT_TEST_MODELS"), .serialized)
struct MobileCLIPIntegrationTests {
    func localManifest(variant: String, id: String) throws -> ModelManifest {
        var m = try #require(try ModelCatalog.builtin().model(id: id))
        let base = URL(fileURLWithPath: localModels!)
        m.files = m.files.map { f in
            var f = f
            if f.path.hasPrefix("image.mlpackage/") || f.path.hasPrefix("text.mlpackage/") {
                let role = f.path.hasPrefix("image") ? "image" : "text"
                let rest = f.path.split(separator: "/", maxSplits: 1)[1]
                f.url = base.appendingPathComponent("mobileclip_\(variant)_\(role).mlpackage/\(rest)").absoluteString
            } else {
                f.url = base.appendingPathComponent(f.path).absoluteString
            }
            return f
        }
        return m
    }

    @Test func installEmbedAndRank() async throws {
        let home = try tempHome()
        let m = try localManifest(variant: "s0", id: "mobileclip-s0@1")
        try await ModelInstaller(home: home).install(m)
        #expect(ModelPaths.isInstalled(home: home, model: m))
        let p = try ProviderRegistry.make(m, home: home)

        let beach = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/The Beach.heic")
        let codeURL = home.tmpURL.appendingPathComponent("code.png")
        try renderText(["func main() {", "    print(\"hello\")", "}"]).write(to: codeURL)

        let vBeach = try await p.embed(imageAt: beach)
        let vCode = try await p.embed(imageAt: codeURL)
        #expect(vBeach.count == 512)
        #expect(abs(vBeach.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)

        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        let tBeach = try await p.embed(text: "a photo of a beach with ocean waves")
        let tCode = try await p.embed(text: "a screenshot of source code")
        #expect(dot(vBeach, tBeach) > dot(vBeach, tCode))
        #expect(dot(vCode, tCode) > dot(vCode, tBeach))
    }
}

@Suite struct HotKeySettingTests {
    // Q6 (revised 2026-10-17): default ⌥Space when never configured; an explicit clear stays empty.
    @Test func defaultAndExplicitClear() {
        #expect(HotKeyCombo.resolve(setting: nil) == HotKeyCombo.defaultCombo)
        #expect(HotKeyCombo.defaultCombo.display == "⌥Space")
        #expect(HotKeyCombo.resolve(setting: HotKeyCombo.clearedSetting) == nil)
        #expect(HotKeyCombo.resolve(setting: "9:256") == HotKeyCombo(keyCode: 9, carbonModifiers: 256))
        #expect(HotKeyCombo.resolve(setting: "garbage") == nil)
    }
}

@Suite struct ModelPathSafetyTests {
    // R1 — ids that resolve outside models/ are rejected; nothing is deleted.
    @Test(arguments: ["..", ".", "", "a/b", "../x", "x/../..", "/abs"])
    func removeRejectsUnsafeIDs(id: String) async throws {
        let home = try tempHome()
        try Data("db".utf8).write(to: home.databaseURL)
        await #expect(throws: (any Error).self) { try await ModelInstaller(home: home).remove(id) }
        #expect(FileManager.default.fileExists(atPath: home.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: home.modelsURL.path))
    }

    // R2 — a manifest file path escaping the staging directory is rejected before anything is written.
    @Test(arguments: ["../../clipvault.sqlite", "image.mlpackage/../../../x", "/etc/x", ""])
    func installRejectsEscapingPaths(path: String) async throws {
        let home = try tempHome()
        try Data("precious".utf8).write(to: home.databaseURL)
        let src = home.root.appendingPathComponent("payload.bin")
        try Data("evil".utf8).write(to: src)
        let m = ModelManifest(id: "evil@1", family: "coreml-clip", displayName: "x", tier: 0, dim: 4, imageSize: nil, contextLength: nil,
                              minMemoryGB: 0, imageInput: nil, textInput: nil, output: nil, tokenizer: nil,
                              files: [ModelFile(path: path, url: src.absoluteString, sha256: String(repeating: "0", count: 64), size: 4)], notes: nil)
        await #expect(throws: InstallError.self) { try await ModelInstaller(home: home).install(m) }
        #expect(try Data(contentsOf: home.databaseURL) == Data("precious".utf8))
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent("x").path))
    }

    @Test func catalogDropsUnsafeCustomEntries() throws {
        let custom = """
        {"models":[{"id":"..","family":"coreml-clip","displayName":"bad","tier":0,"dim":4,"minMemoryGB":0,"files":[]},
                   {"id":"ok@1","family":"coreml-clip","displayName":"bad path","tier":0,"dim":4,"minMemoryGB":0,
                    "files":[{"path":"../x","url":"https://example.com/x","sha256":"00","size":1}]},
                   {"id":"good@1","family":"coreml-clip","displayName":"good","tier":0,"dim":4,"minMemoryGB":0,"files":[]}]}
        """
        let merged = try ModelCatalog.builtin().merging(customJSON: Data(custom.utf8))
        #expect(merged.model(id: "..") == nil && merged.model(id: "ok@1") == nil && merged.model(id: "good@1") != nil)
    }
}

@Suite struct InstallFailureTests {
    // AC9.4 — a transport failure leaves nothing behind; a later install succeeds.
    @Test func failedDownloadThenRetry() async throws {
        let home = try tempHome()
        let good = home.root.appendingPathComponent("a.bin")
        try Data("model".utf8).write(to: good)
        func manifest(_ url: String) throws -> ModelManifest {
            ModelManifest(id: "tiny@1", family: "coreml-clip", displayName: "tiny", tier: 0, dim: 4, imageSize: nil, contextLength: nil,
                          minMemoryGB: 0, imageInput: nil, textInput: nil, output: nil, tokenizer: nil,
                          files: [ModelFile(path: "a.bin", url: url, sha256: try ModelInstaller.sha256(of: good), size: 5)], notes: nil)
        }
        await #expect(throws: (any Error).self) { try await ModelInstaller(home: home).install(try manifest("file:///nonexistent/a.bin")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.tmpURL.path).filter { $0.hasPrefix("model-") }.isEmpty)
        #expect(!ModelPaths.isInstalled(home: home, model: try manifest(good.absoluteString)))
        try await ModelInstaller(home: home).install(try manifest(good.absoluteString))
        #expect(ModelPaths.isInstalled(home: home, model: try manifest(good.absoluteString)))
    }
}

@Suite struct InstallProgressAndCancelTests {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock(); private var items: [InstallProgress] = []
        func add(_ p: InstallProgress) { lock.lock(); items.append(p); lock.unlock() }
        var all: [InstallProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func manifest(_ home: AppHome, files: Int, size: Int) throws -> ModelManifest {
        var list: [ModelFile] = []
        for i in 0..<files {
            let u = home.root.appendingPathComponent("src\(i).bin")
            try Data(repeating: UInt8(i), count: size).write(to: u)
            list.append(ModelFile(path: "f\(i).bin", url: u.absoluteString, sha256: try ModelInstaller.sha256(of: u), size: Int64(size)))
        }
        return ModelManifest(id: "prog@1", family: "coreml-clip", displayName: "p", tier: 0, dim: 4, imageSize: nil, contextLength: nil,
                             minMemoryGB: 0, imageInput: nil, textInput: nil, output: nil, tokenizer: nil, files: list, notes: nil)
    }

    // Progress is monotonic, reaches the total, and walks the phases in order.
    @Test func progressIsMonotonicAndPhased() async throws {
        let home = try tempHome()
        let m = try manifest(home, files: 3, size: 4096)
        let rec = Recorder()
        try await ModelInstaller(home: home).install(m) { rec.add($0) }
        let ps = rec.all
        #expect(zip(ps, ps.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone })
        #expect(ps.last?.bytesDone == m.downloadBytes && ps.last?.phase == .done)
        let phases = ps.map(\.phase).reduce(into: [InstallProgress.Phase]()) { if $0.last != $1 { $0.append($1) } }
        #expect(phases == [.downloading, .verifying, .compiling, .done])
        #expect(ps.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
    }

    // Cancelling stops the install, leaves no staging files and no installed model; a retry works.
    @Test func cancelLeavesNothingBehind() async throws {
        let home = try tempHome()
        let m = try manifest(home, files: 2, size: 1024)
        let installer = ModelInstaller(home: home)
        let task = Task { try await installer.install(m) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.tmpURL.path).filter { $0.hasPrefix("model-") }.isEmpty)
        #expect(!ModelPaths.isInstalled(home: home, model: m))
        try await installer.install(m)
        #expect(ModelPaths.isInstalled(home: home, model: m))
    }
}

@Suite struct InstallUnderSymlinkedPathTests {
    // Regression: a data directory under /private/tmp (symlinked /tmp) rejected every legit path.
    @Test func installsUnderPrivateTmp() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/clipvault-ptest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try AppHome(root: root)
        let src = root.appendingPathComponent("src.bin")
        try Data("model".utf8).write(to: src)
        let m = ModelManifest(id: "sym@1", family: "coreml-clip", displayName: "s", tier: 0, dim: 4, imageSize: nil, contextLength: nil,
                              minMemoryGB: 0, imageInput: nil, textInput: nil, output: nil, tokenizer: nil,
                              files: [ModelFile(path: "nested/dir/Manifest.json", url: src.absoluteString,
                                                sha256: try ModelInstaller.sha256(of: src), size: 5)], notes: nil)
        try await ModelInstaller(home: home).install(m)
        #expect(ModelPaths.isInstalled(home: home, model: m))
    }
}
