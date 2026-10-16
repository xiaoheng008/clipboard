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
        guard case .stored(let id, _) = await rt.service.ingest(image(1), context: ctx) else { return }
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
        guard case .stored(let id, _) = await rt.service.ingest(image(1), context: ctx) else { return }
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
        guard case .stored(let id, _) = await rt.service.ingest(MaintenanceTests().image(3), context: MaintenanceTests().ctx) else { return }
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
