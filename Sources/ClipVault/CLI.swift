import AppKit
import ClipCore
import ClipPlatform
import Foundation

/// Command-line entry (iron law 24a): same runtime as the app, no UI, non-zero exit on failure.
enum CLI {
    static let usage = """
    ClipVault \(AppVersion.marketing)
    Usage: ClipVault [command]          (no command = start the menu-bar app)

      --diagnose                         self-check; exit 1 on any FAIL
      --verify                           check storage invariants (read-only)
      --list [--limit N] [--kind K]      recent items
      --search <query> [--kind K] [--limit N] [--no-semantic] [--raw]   --raw: show unfiltered semantic scores
      --import <image-file>...           add images as if copied (source "cli")
      --add-text <text>...               add text items as if copied (source "cli")
      --copy <id>                        put an item back on the pasteboard
      --run-jobs                         run pending OCR / embedding jobs until done
      --reindex  (--dry-run | --only <item-id> | --all)
      --gc       (--dry-run | --only <blob-hash> | --all)
      --model list | recommend | install <id> | activate <id> | deactivate [image|text] | remove <id>
      --model purge-inactive (--dry-run | --only <model-id> | --all)
      --model threshold <id> [--floor X] [--margin Y] | --reset     semantic match strictness (FR24)
      --bench [--items N] [--images N] [--dim N]   synthetic benchmark in a temporary home
      --login-item status | on | off     launch at login (off by default)
      --slow-ops [--limit N]             slowest button / shortcut actions (1000 kept)
      --eval-text <dataset.json> --model <id>   text-model retrieval eval in a fresh temporary home
      --export-logs <dir>
      --version | --help

      kinds: all text image file url        env CLIPVAULT_HOME overrides the data directory
    """

    static func run(_ args: [String]) async -> Int32 {
        do {
            return try await dispatch(args)
        } catch let e as CLIError {
            FileHandle.standardError.write(Data("error: \(e)\n\nRun ClipVault --help\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    static func openRuntime() async throws -> Runtime {
        let home = try AppHome.resolve()
        ModelInstaller(home: home).cleanIncomplete()
        // R3: the CLI may run next to the app; never sweep tmp/ from here.
        return try await Runtime.open(home: home, services: .system(home: home), startWorker: false, sweepTmp: false)
    }

    static func probes() async -> PlatformProbes {
        PlatformProbes(pasteboardAccess: PasteboardAccess.current().rawValue, translation: await AppleTranslator.availability(),
                       hotkey: nil, watcherHeartbeatAgeSeconds: nil, loginItem: LoginItem.state.rawValue,
                       hardware: "\(HardwareProbe.cpuBrand), \(HardwareProbe.memoryGB) GB, \(HardwareProbe.osVersion)")
    }

    static func option(_ args: [String], _ name: String) throws -> String? {
        guard let i = args.firstIndex(of: name) else { return nil }
        guard i + 1 < args.count else { throw CLIError.usage("\(name) needs a value") }
        return args[i + 1]
    }

    /// Rejects anything not in `allowed` (flags) / `valued` (flags taking a value).
    static func check(_ args: [String], allowed: Set<String> = [], valued: Set<String> = [], positional: Int = 0) throws -> [String] {
        var pos: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if valued.contains(a) { i += 2; continue }
            if allowed.contains(a) { i += 1; continue }
            if a.hasPrefix("--") { throw CLIError.usage("unknown argument \(a)") }
            pos.append(a); i += 1
        }
        if positional >= 0 && pos.count > positional { throw CLIError.usage("unexpected argument \(pos[positional])") }
        return pos
    }

    static func kind(_ args: [String]) throws -> KindFilter {
        guard let k = try option(args, "--kind") else { return .all }
        guard let f = KindFilter(rawValue: k) else { throw CLIError.usage("unknown kind \(k)") }
        return f
    }

    static func print(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    static func describe(_ s: ItemSummary) -> String {
        let text = (s.preview ?? (s.kind == .image ? "[image \(s.width ?? 0)×\(s.height ?? 0)]" : "")).replacingOccurrences(of: "\n", with: "⏎ ")
        let date = Date(timeIntervalSince1970: Double(s.lastUsedAt) / 1000).formatted(date: .numeric, time: .standard)
        return "\(s.id)\t\(s.kind.rawValue)\(s.pinned ? "📌" : "")\t\(date)\t\(String(text.prefix(80)))"
    }

    static func dispatch(_ args: [String]) async throws -> Int32 {
        guard let cmd = args.first else { throw CLIError.usage("no command") }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "--help", "-h": print(usage); return 0
        case "--version": print("\(AppVersion.marketing) (\(AppVersion.build))"); return 0

        case "--diagnose":
            _ = try check(rest)
            let rt = try await openRuntime()
            let report = await Diagnostics.run(rt, probes: await probes())
            print(report.rendered)
            return report.exitCode

        case "--verify":
            _ = try check(rest)
            let rt = try await openRuntime()
            let v = try await Maintenance.verify(rt)
            print("items=\(v.items) fts=\(v.ftsRows) integrity=\(v.integrity) missingBlobs=\(v.missingBlobs.count)")
            for p in v.problems { print("PROBLEM \(p)") }
            return v.problems.isEmpty ? 0 : 1

        case "--list":
            _ = try check(rest, valued: ["--limit", "--kind"])
            let rt = try await openRuntime()
            let limit = Int(try option(rest, "--limit") ?? "20") ?? 20
            for s in try await rt.service.page(after: nil, kind: try kind(rest), limit: limit) { print(describe(s)) }
            return 0

        case "--search":
            let pos = try check(rest, allowed: ["--no-semantic", "--raw"], valued: ["--limit", "--kind"], positional: -1)
            guard !pos.isEmpty else { throw CLIError.usage("--search needs a query") }
            let rt = try await openRuntime()
            let r = await rt.service.search(SearchRequest(requestID: 1, text: pos.joined(separator: " "), kind: try kind(rest),
                                                          semantic: !rest.contains("--no-semantic"),
                                                          limit: Int(try option(rest, "--limit") ?? "20") ?? 20,
                                                          rawSemantic: rest.contains("--raw")))
            print(String(format: "# %d hits in %.1fms; semantic: %@%@", r.hits.count, r.elapsedMs, "\(r.semantic)", r.untranslatedCJK ? " (CJK query not translated)" : ""))
            if let e = r.error { print("# error: \(e)") }
            for h in r.hits {
                let src = h.sources.map(\.rawValue).sorted().joined(separator: "+")
                print(describe(h.item) + "\t[\(src)\(h.similarity.map { String(format: " sim=%.3f", $0) } ?? "")]")
            }
            return r.error == nil ? 0 : 1

        case "--import":
            let files = try check(rest, positional: -1)
            guard !files.isEmpty else { throw CLIError.usage("--import needs at least one file") }
            let rt = try await openRuntime()
            var failures: Int32 = 0
            for f in files {
                let url = URL(fileURLWithPath: f)
                guard let data = try? Data(contentsOf: url) else { print("FAIL \(f): unreadable"); failures += 1; continue }
                let isPNGorJPEG = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8])
                guard let stored = isPNGorJPEG ? data : ImageInfo.pngData(from: data), let dims = ImageInfo.dimensions(stored) else {
                    print("FAIL \(f): not an image"); failures += 1; continue
                }
                let uti = stored.starts(with: [0xFF, 0xD8]) ? "public.jpeg" : "public.png"
                let snap = PasteboardSnapshot(changeCount: -1, types: [uti], image: CapturedImage(data: stored, uti: uti, width: dims.0, height: dims.1))
                let ctx = CaptureContext(frontmostBundleID: "cli", frontmostName: "cli import", excludedBundleIDs: [], lastSelfWriteChangeCount: nil)
                print("\(f): \(await rt.service.ingest(snap, context: ctx))")
            }
            return failures == 0 ? 0 : 1

        case "--add-text":
            let texts = try check(rest, positional: -1)
            guard !texts.isEmpty else { throw CLIError.usage("--add-text needs text") }
            let rt = try await openRuntime()
            let ctx = CaptureContext(frontmostBundleID: "cli", frontmostName: "cli import", excludedBundleIDs: [], lastSelfWriteChangeCount: nil)
            for t in texts {
                let out = await rt.service.ingest(PasteboardSnapshot(changeCount: -1, types: ["public.utf8-plain-text"], string: t), context: ctx)
                print("\(out)")
            }
            return 0

        case "--copy":
            let pos = try check(rest, positional: 1)
            guard let s = pos.first, let id = Int64(s) else { throw CLIError.usage("--copy needs an item id") }
            let rt = try await openRuntime()
            try await rt.service.copyBack(id: id)
            print("copied \(id)")
            return 0

        case "--run-jobs":
            _ = try check(rest)
            let rt = try await openRuntime()
            let t = Date()
            let r = await rt.worker.drain()
            print(String(format: "completed=%d dropped=%d retried=%d failed=%d in %.1fs", r.completed, r.dropped, r.retried, r.failed, Date().timeIntervalSince(t)))
            let c = try await rt.db.counts()
            print("jobs now: pending=\(c.jobsPending) running=\(c.jobsRunning) failed=\(c.jobsFailed)")
            return r.failed == 0 ? 0 : 1

        case "--reindex":
            let scope = try MaintenanceScope.parse(rest)
            let rt = try await openRuntime()
            let r = try await Maintenance.reindex(rt, scope: scope)
            print("failed jobs: \(r.failedToReset)  images missing OCR: \(r.missingOCR)  missing vectors (active model): \(r.missingEmbeddings)")
            print(scope == .dryRun ? "dry run: nothing changed" : "changed: \(r.changed) (run --run-jobs or keep the app open to process)")
            return 0

        case "--gc":
            let scope = try MaintenanceScope.parse(rest)
            let rt = try await openRuntime()
            let r = try await Maintenance.gc(rt, scope: scope)
            print("orphan blobs: \(r.orphans.count)")
            for h in r.orphans.prefix(50) { print("  \(h)") }
            print(scope == .dryRun ? "dry run: nothing deleted" : "deleted: \(r.deleted.count)")
            return 0

        case "--model":
            return try await model(rest)

        case "--bench":
            _ = try check(rest, valued: ["--items", "--images", "--dim"])
            let items = Int(try option(rest, "--items") ?? "100000") ?? 100_000
            let images = Int(try option(rest, "--images") ?? "100000") ?? 100_000
            let dim = Int(try option(rest, "--dim") ?? "512") ?? 512
            // AC15.1: never touches the real library.
            let tmp = FileManager.default.temporaryDirectory
            // Runs that were killed cannot clean up after themselves: remove their leftovers (> 1 h old).
            for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("clipvault-bench-") {
                let u = tmp.appendingPathComponent(name)
                if ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < Date(timeIntervalSinceNow: -3600) {
                    try? FileManager.default.removeItem(at: u)
                }
            }
            let root = tmp.appendingPathComponent("clipvault-bench-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let home = try AppHome(root: root)
            print("bench home: \(root.path)")
            let r = try await Bench.run(home: home, items: items, images: images, dim: dim) { print($0) }
            print(r.budgetsMet ? "ALL BUDGETS MET" : "SOME BUDGETS MISSED")
            return r.budgetsMet ? 0 : 1

        case "--eval-text":
            let pos = try check(rest, valued: ["--model"], positional: 1)
            guard let file = pos.first, let modelID = try option(rest, "--model") else { throw CLIError.usage("--eval-text <dataset.json> --model <id>") }
            let dataset = try JSONDecoder().decode(TextEval.Dataset.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            // Models come from the real home (installed there); data goes to a throwaway home.
            let realHome = try AppHome.resolve()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipvault-eval-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let home = try AppHome(root: root)
            try? FileManager.default.removeItem(at: home.modelsURL)
            try FileManager.default.createSymbolicLink(at: home.modelsURL, withDestinationURL: realHome.modelsURL)
            let rt = try await Runtime.open(home: home, services: .system(home: home), startWorker: false, sweepTmp: false)
            let r = try await TextEval.run(rt, dataset: dataset, modelID: modelID) { print($0) }
            r.lines.forEach { print($0) }
            return 0

        case "--slow-ops":
            _ = try check(rest, valued: ["--limit"])
            let home = try AppHome.resolve()
            print(try await TelemetryStore(home: home).report(limit: Int(try option(rest, "--limit") ?? "50") ?? 50))
            return 0

        case "--login-item":
            let pos = try check(rest, positional: 1)
            switch pos.first ?? "status" {
            case "status": break
            case "on": try LoginItem.set(true)
            case "off": try LoginItem.set(false)
            default: throw CLIError.usage("--login-item takes status, on or off")
            }
            print("login item: \(LoginItem.state.rawValue)")
            return 0

        case "--export-logs":
            let pos = try check(rest, positional: 1)
            guard let dir = pos.first else { throw CLIError.usage("--export-logs needs a directory") }
            let rt = try await openRuntime()
            for u in try Log.shared.export(to: URL(fileURLWithPath: dir)) { print(u.path) }
            let report = URL(fileURLWithPath: dir).appendingPathComponent("slow-ops.txt")
            try await TelemetryStore(home: rt.home).report(limit: TelemetryStore.keep).write(to: report, atomically: true, encoding: .utf8)
            print(report.path)
            return 0

        default:
            throw CLIError.usage("unknown command \(cmd)")
        }
    }

    static func model(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else { throw CLIError.usage("--model needs a subcommand") }
        let rest = Array(args.dropFirst())
        let rt = try await openRuntime()
        let catalog = rt.service.catalog
        switch sub {
        case "list":
            _ = try check(rest)
            let active = Set([await rt.service.activeModelManifest(slot: .image)?.id, await rt.service.activeModelManifest(slot: .text)?.id].compactMap { $0 })
            let counts = try await rt.db.embeddingCounts()
            for m in catalog.models {
                let installed = ModelPaths.isInstalled(home: rt.home, model: m)
                let size = m.requiresInstall ? String(format: "%.0f MB", Double(m.downloadBytes) / 1_048_576) : "built-in"
                print("\(active.contains(m.id) ? "*" : " ") [\(m.slot.rawValue)] \(m.id)\t\(m.displayName)\t\(size)\t\(installed ? "installed" : "not installed")\tvectors=\(counts[m.id] ?? 0)\(m.isSupportedFamily ? "" : "\tUNSUPPORTED FAMILY")")
            }
            return 0
        case "recommend":
            _ = try check(rest)
            for slot in ModelSlot.allCases {
                print("\(HardwareProbe.memoryGB) GB RAM, \(slot.rawValue) → \(await rt.service.recommendedModel(slot: slot)?.id ?? "none")")
            }
            return 0
        case "install":
            let pos = try check(rest, positional: 1)
            guard let id = pos.first, let m = catalog.model(id: id) else { throw CLIError.usage("unknown model \(pos.first ?? "")") }
            print(String(format: "downloading %@ (%.0f MB)…", id, Double(m.downloadBytes) / 1_048_576))
            try await ModelInstaller(home: rt.home).install(m) { p in
                FileHandle.standardError.write(Data(String(format: "\r  %@ %3.0f%%  %.0f / %.0f MB   ", p.phase.rawValue, p.fraction * 100,
                                                            Double(p.bytesDone) / 1_048_576, Double(p.bytesTotal) / 1_048_576).utf8))
            }
            print("\ninstalled \(id)")
            return 0
        case "activate":
            let pos = try check(rest, positional: 1)
            guard let id = pos.first else { throw CLIError.usage("activate needs a model id") }
            try await rt.service.activateModel(id: id)
            let cov = try await rt.service.coverage(modelID: id)
            print("active: \(id); indexed \(cov.indexed)/\(cov.images), queued \(cov.pending)")
            return 0
        case "deactivate":
            let pos = try check(rest, positional: 1)
            guard let slot = ModelSlot(rawValue: pos.first ?? "image") else { throw CLIError.usage("slot must be image or text") }
            try await rt.service.deactivateModel(slot: slot)
            print("\(slot.rawValue) semantic search disabled")
            return 0
        case "remove":
            let pos = try check(rest, positional: 1)
            guard let id = pos.first, catalog.model(id: id) != nil else { throw CLIError.usage("unknown model \(pos.first ?? "")") }
            if await rt.service.activeModelManifest(slot: catalog.model(id: id)?.slot ?? .image)?.id == id { throw CLIError.usage("\(id) is active; deactivate or activate another first") }
            try await ModelInstaller(home: rt.home).remove(id)
            print("removed files of \(id) (vectors kept; see --model purge-inactive)")
            return 0
        case "threshold":
            let pos = try check(rest, allowed: ["--reset"], valued: ["--floor", "--margin"], positional: 1)
            guard let id = pos.first else { throw CLIError.usage("threshold needs a model id") }
            if rest.contains("--reset") {
                try await rt.service.setSemanticThresholds(modelID: id, floor: nil, margin: nil)
            } else if rest.contains("--floor") || rest.contains("--margin") {
                let cur = await rt.service.semanticThresholds(modelID: id)
                guard let f = Float(try option(rest, "--floor") ?? String(cur.floor)), let g = Float(try option(rest, "--margin") ?? String(cur.margin)) else {
                    throw CLIError.usage("--floor / --margin need numbers")
                }
                try await rt.service.setSemanticThresholds(modelID: id, floor: f, margin: g)
            }
            let t = await rt.service.semanticThresholds(modelID: id)
            print(String(format: "%@  floor=%.3f  margin=%.3f%@", id, t.floor, t.margin, t.isDefault ? "  (default)" : ""))
            return 0
        case "purge-inactive":
            let scope = try MaintenanceScope.parse(rest)
            let r = try await Maintenance.purgeInactive(rt, scope: scope)
            print("active: \(r.active.isEmpty ? "none" : r.active.joined(separator: ", "))")
            for (m, n) in r.byModel.sorted(by: { $0.key < $1.key }) { print("  \(m): \(n) vectors") }
            print(scope == .dryRun ? "dry run: nothing deleted" : "deleted: \(r.deleted)")
            return 0
        default:
            throw CLIError.usage("unknown --model subcommand \(sub)")
        }
    }
}
