import AppKit
import ClipCore
@testable import ClipPlatform
import Foundation
import Testing

func tempHome() throws -> AppHome {
    try AppHome(root: FileManager.default.temporaryDirectory.appendingPathComponent("clipvault-ptests-\(UUID().uuidString)"))
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
