import Foundation
@testable import ClipCore

/// A throwaway CLIPVAULT_HOME per test.
func makeTempHome() throws -> AppHome {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipvault-tests-\(UUID().uuidString)", isDirectory: true)
    return try AppHome(root: url)
}

/// Deterministic clock for lease / backoff tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowMs: Int64
    init(_ start: Int64 = 1_800_000_000_000) { nowMs = start }
    func advance(ms: Int64) { lock.lock(); nowMs += ms; lock.unlock() }
    var now: Int64 { lock.lock(); defer { lock.unlock() }; return nowMs }
    var fn: @Sendable () -> Int64 { { self.now } }
}

func textSnapshot(_ s: String, changeCount: Int = 1) -> PasteboardSnapshot {
    PasteboardSnapshot(changeCount: changeCount, types: ["public.utf8-plain-text"], string: s)
}

func pngBytes(seed: UInt8) -> Data {
    // Not a decodable PNG; storage layer treats bytes opaquely.
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    d.append(contentsOf: [UInt8](repeating: seed, count: 64))
    return d
}

/// Repository root, for static source scans.
let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
    }
    fatalError("Package.swift not found")
}()

func swiftSources(under relative: String) -> [(path: String, text: String)] {
    let base = repoRoot.appendingPathComponent(relative)
    guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
    var out: [(String, String)] = []
    for case let u as URL in e where u.pathExtension == "swift" {
        out.append((u.path.replacingOccurrences(of: repoRoot.path + "/", with: ""), (try? String(contentsOf: u, encoding: .utf8)) ?? ""))
    }
    return out
}
