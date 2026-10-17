import ClipCore
import CoreML
import CryptoKit
import Foundation

public struct InstallProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case downloading, verifying, compiling, optimizing, done }
    public var modelID: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var phase: Phase
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 1 }
    public init(modelID: String, bytesDone: Int64, bytesTotal: Int64, phase: Phase) {
        self.modelID = modelID; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.phase = phase
    }
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
            try Task.checkCancellation()
            let total = m.downloadBytes
            var finished: Int64 = 0
            var dests: [(ModelFile, URL)] = []
            // 1. Download everything (byte-level progress; cancellable).
            for f in m.files {
                try Task.checkCancellation()
                // Lexical check (no filesystem normalisation: /private/tmp vs /tmp differ for existing vs new paths).
                // isSafeRelativePath already excluded "..", "." and absolute paths; this is a second guard.
                let dest = staging.appendingPathComponent(f.path)
                guard dest.path.hasPrefix(staging.path.hasSuffix("/") ? staging.path : staging.path + "/") else { throw InstallError.unsafe("path \(f.path)") }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = finished
                try await Downloader.fetch(f, to: dest) { written in
                    progress?(InstallProgress(modelID: m.id, bytesDone: base + min(written, f.size), bytesTotal: total, phase: .downloading))
                }
                finished += f.size
                progress?(InstallProgress(modelID: m.id, bytesDone: finished, bytesTotal: total, phase: .downloading))
                dests.append((f, dest))
            }
            // 2. Verify every file before anything is used (E16).
            progress?(InstallProgress(modelID: m.id, bytesDone: total, bytesTotal: total, phase: .verifying))
            for (f, dest) in dests {
                try Task.checkCancellation()
                try Self.verify(f, at: dest)
            }
            // 3. Compile Core ML packages.
            try Task.checkCancellation()
            progress?(InstallProgress(modelID: m.id, bytesDone: total, bytesTotal: total, phase: .compiling))
            var compiled: [String: String] = [:]
            for role in Self.packageRoles(in: m.files.map(\.path)) {
                let pkg = staging.appendingPathComponent("\(role).mlpackage")
                guard fm.fileExists(atPath: pkg.path) else { continue }
                let out = try await MLModel.compileModel(at: pkg)
                let name = "\(role).mlmodelc"
                try? fm.removeItem(at: staging.appendingPathComponent(name))
                try fm.moveItem(at: out, to: staging.appendingPathComponent(name))
                try fm.removeItem(at: pkg)          // source package no longer needed
                compiled[role] = name
            }
            try Task.checkCancellation()
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
            let record = InstallRecord(modelID: m.id, installedAt: Date(), compiled: compiled)
            try enc.encode(record).write(to: staging.appendingPathComponent("install.json"), options: .atomic)
            let final = try ModelPaths.safeDirectory(home: home, id: m.id)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staging, to: final)
            // 4. First load in its final location: the system builds and caches the Neural Engine program
            //    (measured: Qwen3 72 s the first time, < 1 s afterwards), so activation later stays fast and
            //    within its 60 s deadline. Failure here does not undo the install; activation retries it.
            progress?(InstallProgress(modelID: m.id, bytesDone: total, bytesTotal: total, phase: .optimizing))
            let warmStart = Date()
            let config = MLModelConfiguration()
            config.computeUnits = CoreMLSupport.computeUnits(m.computeUnits)
            for name in compiled.values.sorted() {
                try Task.checkCancellation()
                _ = try? MLModel(contentsOf: final.appendingPathComponent(name), configuration: config)
            }
            Log.shared.event("model.warmed", ["model": .label(m.id), "ms": .int(Int64(Date().timeIntervalSince(warmStart) * 1000))])
            progress?(InstallProgress(modelID: m.id, bytesDone: total, bytesTotal: total, phase: .done))
            Log.shared.event("model.installed", ["model": .label(m.id), "bytes": .int(total)])
        } catch {
            try? fm.removeItem(at: staging)
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            Log.shared.event(cancelled ? "model.install_cancelled" : "model.install_failed", ["model": .label(m.id), "error": .error(error)])
            if cancelled { throw CancellationError() }
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

    /// Every top-level "<role>.mlpackage/…" in the manifest (image, text, text512, …), sorted.
    public static func packageRoles(in paths: [String]) -> [String] {
        Array(Set(paths.compactMap { p -> String? in
            guard let first = p.split(separator: "/").first, first.hasSuffix(".mlpackage") else { return nil }
            return String(first.dropLast(".mlpackage".count))
        })).sorted()
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

/// One file download with byte progress (throttled) and cooperative cancellation.
enum Downloader {
    static func fetch(_ f: ModelFile, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let url = URL(string: f.url) else { throw InstallError.http(file: f.path, status: -1) }
        try? FileManager.default.removeItem(at: dest)
        if url.isFileURL {
            // Offline install from a local copy (also used by tests).
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: url, to: dest)
            progress(f.size)
            return
        }
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // URLSession follows the system proxy configuration.
                let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                    if let error { cont.resume(throwing: error); return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200, let tmp else { cont.resume(throwing: InstallError.http(file: f.path, status: status)); return }
                    do {
                        // The temp file is deleted when this handler returns: move it now.
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        cont.resume()
                    } catch { cont.resume(throwing: error) }
                }
                var last = Date.distantPast
                box.observation = task.progress.observe(\.completedUnitCount) { p, _ in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.15 else { return }   // ~7 updates / s
                    last = now
                    progress(p.completedUnitCount)
                }
                box.task = task
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            box.cancel()
        }
        box.observation = nil
    }

    /// Shares the URLSession task with the cancellation handler.
    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _task: URLSessionDownloadTask?
        private var cancelled = false
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask? {
            get { lock.withLock { _task } }
            set { lock.withLock { _task = newValue; if cancelled { newValue?.cancel() } } }
        }
        func cancel() { lock.withLock { cancelled = true; _task?.cancel() } }
    }
}
