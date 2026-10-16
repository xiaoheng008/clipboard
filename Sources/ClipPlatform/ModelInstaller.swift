import ClipCore
import CoreML
import CryptoKit
import Foundation

public struct InstallProgress: Sendable {
    public var modelID: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var phase: String     // "download" | "verify" | "compile" | "done"
}

public enum InstallError: Error, CustomStringConvertible {
    case checksumMismatch(file: String, expected: String, actual: String)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case http(file: String, status: Int)
    case notDownloadable(String)
    case alreadyInstalling(String)
    case unsafe(String)
    public var description: String {
        switch self {
        case let .checksumMismatch(f, e, a): "sha256 mismatch for \(f): expected \(e.prefix(12))…, got \(a.prefix(12))…"
        case let .sizeMismatch(f, e, a): "size mismatch for \(f): expected \(e), got \(a)"
        case let .http(f, s): "HTTP \(s) downloading \(f)"
        case .notDownloadable(let m): "\(m) has nothing to download"
        case .alreadyInstalling(let m): "\(m) is already being installed"
        case .unsafe(let s): "rejected unsafe manifest: \(s)"
        }
    }
}

/// Download → verify sha256 → compile → atomic rename into models/<id>/ → install.json.
/// Any failure removes the temp directory, leaving the model "not installed" (E16).
public actor ModelInstaller {
    let home: AppHome
    private var active: Set<String> = []

    public init(home: AppHome) { self.home = home }

    public func install(_ m: ModelManifest, progress: (@Sendable (InstallProgress) -> Void)? = nil) async throws {
        guard m.requiresInstall else { throw InstallError.notDownloadable(m.id) }
        // R1/R2: validate everything that becomes a path before touching the disk.
        guard ModelPaths.isSafeID(m.id) else { throw InstallError.unsafe("id \(m.id)") }
        for f in m.files where !ModelPaths.isSafeRelativePath(f.path) { throw InstallError.unsafe("path \(f.path)") }
        guard !active.contains(m.id) else { throw InstallError.alreadyInstalling(m.id) }
        active.insert(m.id)
        defer { active.remove(m.id) }

        let staging = home.tmpURL.appendingPathComponent("model-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var done: Int64 = 0
            let total = m.downloadBytes
            for f in m.files {
                let dest = staging.appendingPathComponent(f.path).standardizedFileURL
                guard dest.path.hasPrefix(staging.standardizedFileURL.path + "/") else { throw InstallError.unsafe("path \(f.path)") }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await download(f, to: dest)
                try Self.verify(f, at: dest)
                done += f.size
                progress?(InstallProgress(modelID: m.id, bytesDone: done, bytesTotal: total, phase: "download"))
            }
            progress?(InstallProgress(modelID: m.id, bytesDone: total, bytesTotal: total, phase: "compile"))
            var compiled: [String: String] = [:]
            for role in ["image", "text"] {
                let pkg = staging.appendingPathComponent("\(role).mlpackage")
                guard fm.fileExists(atPath: pkg.path) else { continue }
                let out = try await MLModel.compileModel(at: pkg)
                let name = "\(role).mlmodelc"
                try? fm.removeItem(at: staging.appendingPathComponent(name))
                try fm.moveItem(at: out, to: staging.appendingPathComponent(name))
                try fm.removeItem(at: pkg)          // source package no longer needed
                compiled[role] = name
            }
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
            let record = InstallRecord(modelID: m.id, installedAt: Date(), compiled: compiled)
            try enc.encode(record).write(to: staging.appendingPathComponent("install.json"), options: .atomic)
            let final = try ModelPaths.safeDirectory(home: home, id: m.id)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staging, to: final)
            progress?(InstallProgress(modelID: m.id, bytesDone: total, bytesTotal: total, phase: "done"))
            Log.shared.event("model.installed", ["model": .label(m.id), "bytes": .int(total)])
        } catch {
            try? fm.removeItem(at: staging)
            Log.shared.event("model.install_failed", ["model": .label(m.id), "error": .error(error)])
            throw error
        }
    }

    public func remove(_ id: String) throws {
        let dir = try ModelPaths.safeDirectory(home: home, id: id)    // R1: never resolves outside models/
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// A model directory without install.json is a half-finished install: remove it (startup recovery).
    public nonisolated func cleanIncomplete() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: home.modelsURL.path)) ?? [] {
            let dir = home.modelsURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if !fm.fileExists(atPath: dir.appendingPathComponent("install.json").path) { try? fm.removeItem(at: dir) }
        }
    }

    private func download(_ f: ModelFile, to dest: URL) async throws {
        guard let url = URL(string: f.url) else { throw InstallError.http(file: f.path, status: -1) }
        if url.isFileURL {
            // Offline install from a local copy (also used by integration tests).
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            return
        }
        // URLSession follows the system proxy configuration.
        let (tmp, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { try? FileManager.default.removeItem(at: tmp); throw InstallError.http(file: f.path, status: status) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Pure check, exposed for tests (AC9.3).
    public static func verify(_ f: ModelFile, at url: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == f.size else { throw InstallError.sizeMismatch(file: f.path, expected: f.size, actual: size) }
        let actual = try sha256(of: url)
        guard actual == f.sha256 else { throw InstallError.checksumMismatch(file: f.path, expected: f.sha256, actual: actual) }
    }

    public static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
