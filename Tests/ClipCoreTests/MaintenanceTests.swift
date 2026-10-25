import Foundation
import Testing
@testable import ClipCore

@Suite struct MaintenanceScopeTests {
    // AC14.1 — exactly one ladder step; unknown arguments fail.
    @Test func parsesExactlyOneStep() throws {
        #expect(try MaintenanceScope.parse(["--dry-run"]) == .dryRun)
        #expect(try MaintenanceScope.parse(["--only", "42"]) == .only("42"))
        #expect(try MaintenanceScope.parse(["--all"]) == .all)
        #expect(throws: CLIError.self) { try MaintenanceScope.parse([]) }
        #expect(throws: CLIError.self) { try MaintenanceScope.parse(["--dry-run", "--all"]) }
        #expect(throws: CLIError.self) { try MaintenanceScope.parse(["--only"]) }
        #expect(throws: CLIError.self) { try MaintenanceScope.parse(["--all", "--force"]) }
    }
}

@Suite struct MaintenanceTests {
    var servicesForTests: PlatformServices {
        PlatformServices(ocr: FakeOCR(), translator: NoTranslator(), pasteboard: FakeWriter(),
                         makeProvider: { m in var e = FakeEmbedder(); e.modelID = m.id; e.dimension = m.dim; return e }, memoryGB: { 16 })
    }

    func runtime() async throws -> Runtime {
        let services = PlatformServices(ocr: FakeOCR(), translator: NoTranslator(), pasteboard: FakeWriter(),
                                        makeProvider: { m in var e = FakeEmbedder(); e.modelID = m.id; e.dimension = m.dim; return e }, memoryGB: { 16 })
        return try await Runtime.open(home: try makeTempHome(), services: services, startWorker: false)
    }

    var ctx: CaptureContext { CaptureContext(frontmostBundleID: nil, frontmostName: nil, excludedBundleIDs: [], lastSelfWriteChangeCount: nil) }

    func image(_ seed: UInt8) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: 1, types: ["public.png"], image: CapturedImage(data: pngBytes(seed: seed), uti: "public.png", width: 1, height: 1))
    }

    // AC4.3 / I2 — verify reports a missing blob; healthy store verifies clean.
    @Test func verifyDetectsMissingBlob() async throws {
        let rt = try await runtime()
        guard case .stored(let id, _) = await rt.service.ingest(image(1), context: ctx) else { Issue.record("ingest did not store"); return }
        #expect(try await Maintenance.verify(rt).problems.isEmpty)
        let hash = try #require(try await rt.db.blobHash(itemID: id))
        try FileManager.default.removeItem(at: rt.blobs.url(for: hash))
        let report = try await Maintenance.verify(rt)
        #expect(report.missingBlobs == [id])
        #expect(!report.problems.isEmpty)
    }

    // C31 ladder — gc never touches referenced blobs; dry-run deletes nothing.
    @Test func gcLadder() async throws {
        let rt = try await runtime()
        _ = await rt.service.ingest(image(1), context: ctx)
        let o1 = try rt.blobs.put(pngBytes(seed: 50))       // orphans: written but never committed (E13)
        let o2 = try rt.blobs.put(pngBytes(seed: 51))
        let dry = try await Maintenance.gc(rt, scope: .dryRun, minAge: 0)
        #expect(Set(dry.orphans) == [o1, o2] && dry.deleted.isEmpty)
        #expect(rt.blobs.exists(o1))
        let one = try await Maintenance.gc(rt, scope: .only(o1), minAge: 0)
        #expect(one.deleted == [o1] && !rt.blobs.exists(o1) && rt.blobs.exists(o2))
        await #expect(throws: CLIError.self) { _ = try await Maintenance.gc(rt, scope: .only("not-an-orphan"), minAge: 0) }
        let all = try await Maintenance.gc(rt, scope: .all, minAge: 0)
        #expect(all.deleted == [o2])
        #expect(try await Maintenance.verify(rt).problems.isEmpty)
        #expect(try rt.blobs.allHashes().count == 1)
    }

    @Test func reindexResetsFailedAndEnqueuesMissing() async throws {
        let rt = try await runtime()
        guard case .stored(let id, _) = await rt.service.ingest(image(1), context: ctx) else { Issue.record("ingest did not store"); return }
        // Make the vision job fail terminally.
        for _ in 0..<3 {
            let jobs = try await rt.db.claimJobs(limit: 5, activeModel: nil, leaseMs: 1)
            for j in jobs { try await rt.db.failJob(job: j, error: "x", maxAttempts: 3) }
            try await rt.db.forceJobsClaimable()
        }
        #expect(try await rt.db.counts().jobsFailed == 1)
        let dry = try await Maintenance.reindex(rt, scope: .dryRun)
        #expect(dry.failedToReset == 1 && dry.changed == 0)
        let all = try await Maintenance.reindex(rt, scope: .all)
        #expect(all.changed >= 1)
        let c = try await rt.db.counts()
        #expect(c.jobsFailed == 0 && c.jobsPending == 1)
        let report = await rt.worker.drain()
        #expect(report.completed == 1)
        #expect(try await rt.db.item(id: id)?.ocrText != nil)
        #expect(try await Maintenance.reindex(rt, scope: .dryRun).missingOCR == 0)
    }

    // Q5 — purge only touches vectors of models other than the active one.
    @Test func purgeInactiveLadder() async throws {
        let rt = try await runtime()
        try await rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
        _ = await rt.service.ingest(image(1), context: ctx)
        _ = await rt.worker.drain()
        try await rt.service.activateModel(id: "mobileclip-s2@1", requireInstalled: false)
        _ = await rt.worker.drain()
        let dry = try await Maintenance.purgeInactive(rt, scope: .dryRun)
        #expect(dry.byModel == ["mobileclip-s0@1": 1] && dry.deleted == 0)
        let all = try await Maintenance.purgeInactive(rt, scope: .all)
        #expect(all.deleted == 1)
        #expect(try await rt.db.semanticCoverage(modelID: "mobileclip-s2@1").indexed == 1)
        #expect(try await rt.db.semanticCoverage(modelID: "mobileclip-s0@1").indexed == 0)
    }

    // FR20 — the active text model's vectors are never "inactive".
    @Test func purgeKeepsActiveTextModel() async throws {
        let rt = try await runtime()
        try await rt.service.activateModel(id: "multilingual-e5-small@1", requireInstalled: false)
        _ = await rt.service.ingest(textSnapshot("hello world"), context: ctx)
        _ = await rt.worker.drain()
        let dry = try await Maintenance.purgeInactive(rt, scope: .dryRun)
        #expect(dry.byModel.isEmpty && dry.active == ["multilingual-e5-small@1"])
    }
}

@Suite struct DiagnosticsTests {
    @Test func healthyStoreHasNoFailures() async throws {
        let rt = try await MaintenanceTests().runtime()
        let report = await Diagnostics.run(rt, probes: .unavailable)
        #expect(report.checks.contains { $0.name == "schema" && $0.status == .pass })
        #expect(report.exitCode == 0)
        #expect(report.rendered.contains("PASS"))
    }

    // AC13.1 — an invariant violation makes the run fail with the observed value.
    @Test func brokenInvariantFails() async throws {
        let rt = try await MaintenanceTests().runtime()
        guard case .stored(let id, _) = await rt.service.ingest(MaintenanceTests().image(3), context: MaintenanceTests().ctx) else { Issue.record("ingest did not store"); return }
        try FileManager.default.removeItem(at: rt.blobs.url(for: try #require(try await rt.db.blobHash(itemID: id))))
        let report = await Diagnostics.run(rt, probes: .unavailable)
        let check = try #require(report.checks.first { $0.name == "invariant.blobs" })
        #expect(check.status == .fail && check.observed.contains("1"))
        #expect(report.exitCode == 1)
    }

    // AC13.2 — denied pasteboard access is a FAIL, not silently "empty".
    @Test func deniedPasteboardFails() async throws {
        let rt = try await MaintenanceTests().runtime()
        var probes = PlatformProbes.unavailable
        probes.pasteboardAccess = "alwaysDeny"
        let report = await Diagnostics.run(rt, probes: probes)
        #expect(report.checks.first { $0.name == "permission.pasteboard" }?.status == .fail)
    }

    // AC28.4 — without Accessibility, Enter only copies: visible as a WARN (the app still works), PASS when granted.
    @Test func accessibilityShowsInDiagnostics() async throws {
        let rt = try await MaintenanceTests().runtime()
        var probes = PlatformProbes.unavailable
        probes.accessibility = false
        let off = await Diagnostics.run(rt, probes: probes).checks.first { $0.name == "permission.accessibility" }
        #expect(off?.status == .warn)
        #expect(off?.observed.contains("⌘V") == true)
        probes.accessibility = true
        #expect(await Diagnostics.run(rt, probes: probes).checks.first { $0.name == "permission.accessibility" }?.status == .pass)
    }
}


@Suite struct ConcurrencySafetyTests {
    // R3 — opening a runtime from the CLI must not touch tmp/; the app only sweeps stale leftovers.
    @Test func tmpSweepOnlyRemovesStaleEntries() throws {
        let home = try makeTempHome()
        let fresh = home.tmpURL.appendingPathComponent("model-inflight")
        let stale = home.tmpURL.appendingPathComponent("blob-crashed")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stale.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 3600)], ofItemAtPath: stale.path)
        home.cleanTmp(olderThan: 6 * 3600)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func cliRuntimeDoesNotSweepTmp() async throws {
        let home = try makeTempHome()
        let inflight = home.tmpURL.appendingPathComponent("blob-inflight")
        FileManager.default.createFile(atPath: inflight.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 3600)], ofItemAtPath: inflight.path)
        _ = try await Runtime.open(home: home, services: MaintenanceTests().servicesForTests, startWorker: false, sweepTmp: false)
        #expect(FileManager.default.fileExists(atPath: inflight.path))
    }

    // R4 — gc never deletes a blob younger than the grace period (it may be about to be committed).
    @Test func gcSkipsRecentOrphans() async throws {
        let rt = try await MaintenanceTests().runtime()
        let young = try rt.blobs.put(pngBytes(seed: 70))
        let dry = try await Maintenance.gc(rt, scope: .all)
        #expect(dry.orphans.isEmpty && dry.deleted.isEmpty && rt.blobs.exists(young))
        let aged = try await Maintenance.gc(rt, scope: .all, minAge: 0)
        #expect(aged.deleted == [young])
    }

    // R4 — a blob being re-ingested (put done, commit pending) survives a concurrent delete of the old item.
    @Test func deleteKeepsBlobPendingIngest() async throws {
        let rt = try await MaintenanceTests().runtime()
        guard case .stored(let id, _) = await rt.service.ingest(MaintenanceTests().image(5), context: MaintenanceTests().ctx) else {
            Issue.record("ingest failed"); return
        }
        let hash = try #require(try await rt.db.blobHash(itemID: id))
        await rt.service.markBlobPending(hash)
        try await rt.service.delete(id: id)
        #expect(rt.blobs.exists(hash))
        await rt.service.unmarkBlobPending(hash)
    }
}

@Suite struct ReviewP3Tests {
    // R19 — structural scans must actually see the sources.
    @Test func structureScansSeeSources() {
        #expect(swiftSources(under: "Sources/ClipCore").count > 15)
        #expect(swiftSources(under: "Sources").first { $0.path.hasSuffix("Storage/SQLite.swift") }?.text.contains("sqlite3_") == true)
    }

    // AC16.1 — log labels never carry clipboard content (static scan) and export works.
    @Test func logLabelsCarryNoContent() {
        let banned = ["text", "string", "query", "preview", "ocr", "snapshot", "content", "draft.text"]
        var offenders: [String] = []
        for f in swiftSources(under: "Sources") {
            for line in f.text.split(separator: "\n") where line.contains(".label(") {
                for arg in line.components(separatedBy: ".label(").dropFirst() {
                    let inside = arg.prefix { $0 != ")" }.lowercased()
                    if banned.contains(where: { inside.contains($0) }) { offenders.append("\(f.path): \(line.trimmingCharacters(in: .whitespaces))") }
                }
            }
        }
        #expect(offenders == [])
    }

    @Test func logExportCopiesFiles() throws {
        let home = try makeTempHome()
        let log = Log()
        log.configure(directory: home.logsURL)
        log.event("test.event", ["n": .int(1)])
        let out = try log.export(to: home.tmpURL.appendingPathComponent("export"))
        #expect(out.count == 1)
        #expect(try String(contentsOf: out[0], encoding: .utf8).contains("test.event n=1"))
        #expect(log.recentCount(of: "test.event", within: 60) == 1)
    }

    // AC4.2 (blob side) — a failing blob write leaves nothing behind and the next capture still works.
    @Test func blobWriteFailureIsAtomic() async throws {
        let rt = try await MaintenanceTests().runtime()
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rt.home.blobsURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rt.home.blobsURL.path) }
        guard case .failed = await rt.service.ingest(MaintenanceTests().image(40), context: MaintenanceTests().ctx) else {
            Issue.record("expected .failed"); return
        }
        let c = try await rt.db.counts()
        #expect(c.items == 0 && c.ftsRows == 0 && c.jobsPending == 0)
        #expect(try fm.contentsOfDirectory(atPath: rt.home.tmpURL.path).isEmpty)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rt.home.blobsURL.path)
        guard case .stored = await rt.service.ingest(MaintenanceTests().image(41), context: MaintenanceTests().ctx) else {
            Issue.record("next capture failed"); return
        }
    }

    // AC7.3 — a job whose claimant died is reclaimed after the lease and completed by the next drain.
    @Test func reclaimedJobCompletes() async throws {
        let clock = TestClock()
        let db = try Database(home: try makeTempHome(), clock: clock.fn)
        let (id, _) = try await JobQueueTests().imageItem(db, seed: 8)
        _ = try await db.claimJobs(limit: 5, activeModels: [], leaseMs: 120_000)      // claimant "dies"
        let worker = IndexWorker(db: db, blobs: BlobStore(home: db.home), ocr: FakeOCR())
        #expect(await worker.drain().completed == 0)
        clock.advance(ms: 120_001)
        #expect(await worker.drain().completed == 1)
        #expect(try await db.item(id: id)?.ocrText != nil)
    }

    // R22 — a database whose user_version says 1 but lacks the seq column fails loudly.
    @Test func incompatibleV1DatabaseIsRejected() throws {
        let home = try makeTempHome()
        let c = try SQLiteConnection(path: home.databaseURL.path)
        try c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY, kind TEXT); PRAGMA user_version = 1")
        #expect(throws: SchemaError.self) { _ = try Database(home: home) }
    }

    // AC5.3 — the panel's row window never exceeds its cap and never duplicates rows.
    struct R: Identifiable, Equatable { let id: Int64 }
    @Test func rowWindowIsBounded() {
        var rows: [R] = []
        var cursor: Int64 = 10_000
        for _ in 0..<15 {
            let page = (0..<60).map { _ -> R in cursor -= 1; return R(id: cursor) }
            rows = RowWindow.append(page, to: rows, cap: 600)
        }
        #expect(rows.count == 600 && Set(rows.map(\.id)).count == 600)
        let merged = RowWindow.mergeTop([R(id: 20_000), rows[5]], onto: rows, cap: 600)
        #expect(merged.count == 600 && merged.first?.id == 20_000 && Set(merged.map(\.id)).count == 600)
    }
}

@Suite struct WriteFailureRecordTests {
    // R13 — write failures are visible to diagnostics in any process, per data directory.
    @Test func recordedPerHomeAndCountedByDiagnostics() async throws {
        let rt = try await MaintenanceTests().runtime()
        #expect(rt.home.writeFailures(within: 3600) == 0)
        rt.home.recordWriteFailure()
        rt.home.recordWriteFailure(at: Date(timeIntervalSinceNow: -2 * 86400))     // too old
        #expect(rt.home.writeFailures(within: 24 * 3600) == 1)
        let report = await Diagnostics.run(rt, probes: .unavailable)
        #expect(report.checks.first { $0.name == "capture.write_failures" }?.status == .fail)
    }
}
