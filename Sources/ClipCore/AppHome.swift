import Foundation

/// On-disk layout. Everything the app owns lives under one root (see 2.1-architecture.md).
public struct AppHome: Sendable {
    public let root: URL

    public var databaseURL: URL { root.appendingPathComponent("clipvault.sqlite") }
    public var blobsURL: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    public var thumbsURL: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    public var modelsURL: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var tmpURL: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    public var logsURL: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// Per-home record of capture write failures, readable by any process (R13). One ISO timestamp per line.
    public var writeFailuresURL: URL { logsURL.appendingPathComponent("write-failures.log") }

    public func recordWriteFailure(at date: Date = Date()) {
        let line = Data((ISO8601DateFormatter().string(from: date) + "\n").utf8)
        if let fh = try? FileHandle(forWritingTo: writeFailuresURL) {
            _ = try? fh.seekToEnd(); try? fh.write(contentsOf: line); try? fh.close()
        } else {
            try? line.write(to: writeFailuresURL)
        }
    }

    public func writeFailures(within seconds: TimeInterval) -> Int {
        guard let text = try? String(contentsOf: writeFailuresURL, encoding: .utf8) else { return 0 }
        let cutoff = Date(timeIntervalSinceNow: -seconds)
        let parser = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { parser.date(from: String($0)) }.filter { $0 >= cutoff }.count
    }

    public init(root: URL) throws {
        self.root = root
        for dir in [root, blobsURL, thumbsURL, modelsURL, tmpURL, logsURL] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// `CLIPVAULT_HOME` overrides the default location (tests, bench, isolated runs).
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AppHome {
        if let override = environment["CLIPVAULT_HOME"], !override.isEmpty {
            return try AppHome(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return try AppHome(root: support.appendingPathComponent("ClipVault", isDirectory: true))
    }

    /// Removes leftovers of interrupted writes / downloads. Another process (CLI or app) may be using
    /// tmp/ right now (E23), so only entries untouched for `olderThan` seconds are removed (R3).
    public func cleanTmp(olderThan age: TimeInterval = 6 * 3600) {
        let fm = FileManager.default
        let cutoff = Date(timeIntervalSinceNow: -age)
        for name in (try? fm.contentsOfDirectory(atPath: tmpURL.path)) ?? [] {
            let url = tmpURL.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
