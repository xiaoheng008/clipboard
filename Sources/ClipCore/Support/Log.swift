import Foundation

/// Log field values. There is deliberately no case for arbitrary user strings: clipboard content
/// cannot be logged by construction (AC16.1). `.label` takes short identifiers (kinds, model ids).
public enum LogValue: Sendable {
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case label(String)
    case error(any Error)

    var rendered: String {
        switch self {
        case .int(let v): String(v)
        case .double(let v): String(format: "%.2f", v)
        case .bool(let v): String(v)
        case .label(let v): String(v.prefix(64)).replacingOccurrences(of: "\n", with: " ")
        case .error(let e): String(String(describing: e).prefix(300)).replacingOccurrences(of: "\n", with: " ")
        }
    }
}

/// Rolling file log (H7: 5 MB × 3). Thread-safe; writes are synchronous and small.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var fileURL: URL?
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let keep = 3
    public var echoToStderr = false

    public func configure(directory: URL) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        let url = directory.appendingPathComponent("clipvault.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        fileURL = url
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    public var currentFile: URL? { lock.lock(); defer { lock.unlock() }; return fileURL }

    public func event(_ name: StaticString, _ fields: KeyValuePairs<StaticString, LogValue> = [:]) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        var line = "\(ts) \(name)"
        for (k, v) in fields { line += " \(k)=\(v.rendered)" }
        line += "\n"
        lock.lock(); defer { lock.unlock() }
        if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        guard let handle else { return }
        let data = Data(line.utf8)
        try? handle.write(contentsOf: data)
        size += UInt64(data.count)
        if size > maxBytes { rotate() }
    }

    private func rotate() {
        guard let fileURL else { return }
        try? handle?.close()
        let fm = FileManager.default
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let src = i == 1 ? fileURL : fileURL.appendingPathExtension(String(i - 1))
            let dst = fileURL.appendingPathExtension(String(i))
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        fm.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        size = 0
    }

    /// Copies all log files into `directory`. Logs never contain clipboard content.
    public func export(to directory: URL) throws -> [URL] {
        lock.lock(); let base = fileURL; lock.unlock()
        guard let base else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var out: [URL] = []
        for u in [base] + (1..<keep).map({ base.appendingPathExtension(String($0)) }) where FileManager.default.fileExists(atPath: u.path) {
            let dst = directory.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: u, to: dst)
            out.append(dst)
        }
        return out
    }
}
