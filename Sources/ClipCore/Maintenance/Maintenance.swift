import Foundation

public enum CLIError: Error, CustomStringConvertible, Equatable {
    case usage(String)
    public var description: String { if case .usage(let s) = self { s } else { "" } }
}

/// Iron law 28 ladder: `--dry-run` (report only) → `--only <id>` (one target) → `--all`. Exactly one, nothing else.
public enum MaintenanceScope: Equatable, Sendable {
    case dryRun
    case only(String)
    case all

    public static func parse(_ args: [String]) throws -> MaintenanceScope {
        var scope: MaintenanceScope?
        var i = 0
        func set(_ s: MaintenanceScope) throws {
            if scope != nil { throw CLIError.usage("give exactly one of --dry-run, --only <id>, --all") }
            scope = s
        }
        while i < args.count {
            switch args[i] {
            case "--dry-run": try set(.dryRun)
            case "--all": try set(.all)
            case "--only":
                guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw CLIError.usage("--only needs an id") }
                try set(.only(args[i + 1])); i += 1
            default: throw CLIError.usage("unknown argument \(args[i])")
            }
            i += 1
        }
        guard let scope else { throw CLIError.usage("give exactly one of --dry-run, --only <id>, --all") }
        return scope
    }
}

public struct VerifyReport: Sendable {
    public var items = 0
    public var ftsRows = 0
    public var missingBlobs: [Int64] = []
    public var integrity = ""
    public var problems: [String] {
        var p: [String] = []
        if !missingBlobs.isEmpty { p.append("I2: \(missingBlobs.count) image item(s) without blob file: \(missingBlobs.prefix(10))") }
        if ftsRows != items { p.append("I3: FTS rows \(ftsRows) ≠ items \(items)") }
        if integrity != "ok" { p.append("integrity: \(integrity)") }
        return p
    }
}

public struct GCReport: Sendable { public var orphans: [String] = []; public var deleted: [String] = [] }
public struct ReindexReport: Sendable { public var failedToReset = 0; public var missingOCR = 0; public var missingEmbeddings = 0; public var changed = 0 }
public struct PurgeReport: Sendable { public var active: String?; public var byModel: [String: Int] = [:]; public var deleted = 0 }

/// Read-only verification and the three write tools. All writes go through Database transactions.
public enum Maintenance {
    public static func verify(_ rt: Runtime) async throws -> VerifyReport {
        var r = VerifyReport()
        let c = try await rt.db.counts()
        r.items = c.items
        r.ftsRows = c.ftsRows
        r.integrity = try await rt.db.quickCheck()
        for (id, hash) in try await rt.db.referencedBlobs() where !rt.blobs.exists(hash) { r.missingBlobs.append(id) }
        return r
    }

    /// Orphan = blob file no item references (E13). Referenced blobs are never touched.
    public static func gc(_ rt: Runtime, scope: MaintenanceScope) async throws -> GCReport {
        let referenced = Set(try await rt.db.referencedBlobs().map(\.hash))
        var r = GCReport()
        r.orphans = try rt.blobs.allHashes().subtracting(referenced).sorted()
        switch scope {
        case .dryRun: break
        case .only(let h):
            guard r.orphans.contains(h) else { throw CLIError.usage("\(h) is not an orphan blob") }
            try rt.blobs.delete(h); r.deleted = [h]
        case .all:
            for h in r.orphans { try rt.blobs.delete(h) }
            r.deleted = r.orphans
        }
        Log.shared.event("maint.gc", ["orphans": .int(Int64(r.orphans.count)), "deleted": .int(Int64(r.deleted.count))])
        return r
    }

    public static func reindex(_ rt: Runtime, scope: MaintenanceScope) async throws -> ReindexReport {
        var r = ReindexReport()
        let active = await rt.service.activeModelManifest()?.id
        r.failedToReset = try await rt.db.failedJobs()
        r.missingOCR = try await rt.db.imagesMissingOCR()
        if let active { r.missingEmbeddings = try await rt.db.imagesMissingEmbedding(modelID: active) }
        switch scope {
        case .dryRun: break
        case .only(let s):
            guard let id = Int64(s) else { throw CLIError.usage("--only needs a numeric item id") }
            guard try await rt.db.reenqueue(itemID: id, embedModel: active) else { throw CLIError.usage("item \(id) is not an image") }
            r.changed = 1
        case .all:
            r.changed += try await rt.db.resetFailedJobs()
            r.changed += try await rt.db.enqueueMissingVision()
            if let active { r.changed += try await rt.db.enqueueMissingEmbeddings(modelID: active) }
        }
        if r.changed > 0 { await rt.worker.wake() }
        Log.shared.event("maint.reindex", ["changed": .int(Int64(r.changed))])
        return r
    }

    /// Q5: vectors of non-active models are kept until purged here.
    public static func purgeInactive(_ rt: Runtime, scope: MaintenanceScope) async throws -> PurgeReport {
        var r = PurgeReport()
        r.active = await rt.service.activeModelManifest()?.id
        r.byModel = try await rt.db.embeddingCounts().filter { $0.key != r.active }
        switch scope {
        case .dryRun: break
        case .only(let m):
            guard m != r.active else { throw CLIError.usage("\(m) is the active model") }
            guard r.byModel[m] != nil else { throw CLIError.usage("no vectors for \(m)") }
            r.deleted = try await rt.db.purgeModel(m)
        case .all:
            for m in r.byModel.keys { r.deleted += try await rt.db.purgeModel(m) }
        }
        Log.shared.event("maint.purge", ["deleted": .int(Int64(r.deleted))])
        return r
    }
}
