import Foundation

public enum CheckStatus: String, Sendable { case pass = "PASS", warn = "WARN", fail = "FAIL", skip = "SKIP" }

public struct DiagnosticCheck: Sendable, Equatable {
    public let name: String
    public let status: CheckStatus
    public let observed: String
}

/// Facts only the platform / running app can observe. nil = not observable here (SKIP, not PASS).
public struct PlatformProbes: Sendable {
    public var pasteboardAccess: String?        // pasteboard accessBehavior (macOS 15.4+)
    public var translation: String?
    public var hotkey: String?                  // "unset" / "⌘⇧V registered" / "failed …"
    public var watcherHeartbeatAgeSeconds: Double?
    public var hardware: String?
    public var loginItem: String?
    public static let unavailable = PlatformProbes()
    public init(pasteboardAccess: String? = nil, translation: String? = nil, hotkey: String? = nil,
                watcherHeartbeatAgeSeconds: Double? = nil, loginItem: String? = nil, hardware: String? = nil) {
        self.pasteboardAccess = pasteboardAccess; self.translation = translation; self.hotkey = hotkey
        self.watcherHeartbeatAgeSeconds = watcherHeartbeatAgeSeconds; self.loginItem = loginItem; self.hardware = hardware
    }
}

public struct DiagnosticReport: Sendable {
    public let checks: [DiagnosticCheck]
    public var exitCode: Int32 { checks.contains { $0.status == .fail } ? 1 : 0 }
    public var rendered: String {
        let width = (checks.map(\.name.count).max() ?? 10) + 2
        return checks.map { c in
            "[Diag] " + c.name.padding(toLength: width, withPad: " ", startingAt: 0) + c.status.rawValue + "  " + c.observed
        }.joined(separator: "\n")
    }
}

/// Read-only, idempotent self-check shared by `--diagnose` and the settings page (iron law 24a).
public enum Diagnostics {
    /// R13 / E22: < 500 MB free is a failure (captures will start failing), < 5 GB a warning.
    public static func diskStatus(freeBytes: Int64) -> CheckStatus {
        freeBytes < 500 << 20 ? .fail : (freeBytes < 5 << 30 ? .warn : .pass)
    }

    public static func run(_ rt: Runtime, probes: PlatformProbes) async -> DiagnosticReport {
        var out: [DiagnosticCheck] = []
        func add(_ n: String, _ s: CheckStatus, _ o: String) { out.append(DiagnosticCheck(name: n, status: s, observed: o)) }

        add("version", .pass, "\(AppVersion.marketing) (build \(AppVersion.build))")
        if let hw = probes.hardware { add("hardware", .pass, hw) }
        add("home", .pass, rt.home.root.path)
        add("sqlite", .pass, SQLiteConnection.libraryVersion)

        do {
            let v = try await rt.db.userVersion()
            add("schema", v == Schema.currentVersion ? .pass : .fail, "v\(v) (expected v\(Schema.currentVersion))")
            let qc = try await rt.db.quickCheck()
            add("integrity", qc == "ok" ? .pass : .fail, qc)
        } catch { add("schema", .fail, String(describing: error)) }

        switch probes.pasteboardAccess {
        case nil: add("permission.pasteboard", .skip, "not observable from this process")
        case "alwaysDeny"?: add("permission.pasteboard", .fail, "alwaysDeny → nothing will be recorded; allow in System Settings › Privacy & Security › Paste from Other Apps")
        case "ask"?: add("permission.pasteboard", .warn, "ask → macOS prompts before each read")
        case let v?: add("permission.pasteboard", .pass, v)
        }

        if let age = probes.watcherHeartbeatAgeSeconds {
            add("watcher", age < 5 ? .pass : .fail, String(format: "last poll %.1fs ago", age))
        } else {
            add("watcher", .skip, "app not running in this process")
        }
        if let free = (try? rt.home.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage {
            add("disk.free", diskStatus(freeBytes: free), ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " available")
        }
        // Write failures from any process are in the shared log (skip counters are per process).
        let recentWriteFailures = Log.shared.recentCount(of: "capture.write_failed", within: 24 * 3600)
        add("capture.write_failures", recentWriteFailures > 0 ? .fail : .pass, "\(recentWriteFailures) in the last 24 h")
        let skips = await rt.service.skipCounts()
        add("capture.skips", .pass,
            skips.isEmpty ? "none this session" : skips.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))

        do {
            let c = try await rt.db.counts()
            let mb = Double(rt.blobs.totalBytes()) / 1_048_576
            add("storage", .pass, "items=\(c.items) images=\(c.images) blobs=\(String(format: "%.1f", mb)) MB")
            let verify = try await Maintenance.verify(rt)
            add("invariant.blobs", verify.missingBlobs.isEmpty ? .pass : .fail, "missing blob files: \(verify.missingBlobs.count)")
            add("invariant.fts", c.ftsRows == c.items ? .pass : .fail, "fts rows \(c.ftsRows) / items \(c.items)")
            add("jobs", c.jobsFailed > 0 ? .warn : .pass, "pending=\(c.jobsPending) running=\(c.jobsRunning) failed=\(c.jobsFailed)" + (c.jobsFailed > 0 ? " → --reindex --all" : ""))
            let expired = try await rt.db.expiredLeases()
            add("jobs.leases", expired > 0 ? .warn : .pass, "expired running leases: \(expired)" + (expired > 0 ? " (will be reclaimed)" : ""))
        } catch { add("storage", .fail, String(describing: error)) }

        if let err = await rt.service.activationError { add("model.restore", .fail, err) }
        for slot in ModelSlot.allCases {
            let name = "model.\(slot.rawValue)"
            if let m = await rt.service.activeModelManifest(slot: slot) {
                add(name, .pass, "\(m.id) — \(m.displayName)")
                if let cov = try? await rt.service.coverage(modelID: m.id) {
                    add(name + ".coverage", cov.failed > 0 ? .warn : .pass, "indexed \(cov.indexed)/\(cov.images), pending \(cov.pending), failed \(cov.failed)")
                    let engine = slot == .image ? rt.engine : rt.textEngine
                    if let idx = await engine.activeIndex {
                        let mem = await idx.count()
                        add(name + ".index", mem == cov.indexed ? .pass : .fail, "in-memory vectors \(mem) / stored \(cov.indexed)")
                    }
                }
            } else {
                let rec = await rt.service.recommendedModel(slot: slot)
                add(name, .warn, "none → \(slot == .image ? "image" : "text") semantic search disabled" + (rec.map { "; recommended: \($0.id)" } ?? ""))
            }
        }
        let installed = rt.service.catalog.models.filter { $0.requiresInstall && ModelPaths.isInstalled(home: rt.home, model: $0) }.map(\.id)
        add("models.installed", .pass, installed.isEmpty ? "none" : installed.joined(separator: ", "))
        if let customErr = ModelCatalog.load(home: rt.home).customError { add("models.custom", .warn, customErr) }

        add("translation.zh-en", probes.translation == nil ? .skip : (probes.translation == "installed" ? .pass : .warn),
            probes.translation ?? "not probed")
        add("hotkey", probes.hotkey == nil ? .skip : (probes.hotkey!.hasPrefix("failed") ? .fail : .pass), probes.hotkey ?? "app not running in this process")
        if let li = probes.loginItem {
            add("login_item", li == "requiresApproval" ? .warn : .pass, li)
        }
        add("logs", .pass, Log.shared.currentFile?.path ?? "not configured")
        return DiagnosticReport(checks: out)
    }
}
