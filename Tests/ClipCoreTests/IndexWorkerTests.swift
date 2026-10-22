import Foundation
import Testing
@testable import ClipCore

struct FakeOCR: OCRProvider {
    var failures: Int = 0
    let calls = Counter()
    func recognize(imageAt url: URL) async throws -> OCRResult {
        let n = calls.increment()
        if n <= failures { throw ProviderError.failed("boom \(n)") }
        return OCRResult(text: "识别文字 \(url.lastPathComponent.prefix(6))", labels: ["document", "text"])
    }
}

struct FakeEmbedder: EmbeddingProvider {
    var modelID = "fake@1"
    var dimension = 4
    var capabilities = EmbeddingCapabilities(image: true, text: true)
    func embed(imageAt url: URL) async throws -> [Float] { VectorCodec.normalized((0..<dimension).map { Float($0 % 4 + 1) }) }
    func embed(text: String) async throws -> [Float] { VectorCodec.normalized((0..<dimension).map { Float($0 % 4 + 1) }) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

actor FakeIndex: VectorIndex {
    nonisolated let modelID: String
    nonisolated let dimension = 4
    var ids: Set<Int64> = []
    init(modelID: String = "fake@1") { self.modelID = modelID }
    func count() -> Int { ids.count }
    func replaceAll(_ entries: [(id: Int64, vector: [Float16])]) { ids = Set(entries.map(\.id)) }
    func upsert(id: Int64, vector: [Float]) { ids.insert(id) }
    func remove(ids r: [Int64]) { ids.subtract(r) }
    func search(_ query: [Float], k: Int) -> [(id: Int64, score: Float)] { ids.map { ($0, 1) } }
}

@Suite struct JobQueueTests {
    func imageItem(_ db: Database, seed: UInt8, model: String = "fake@1") async throws -> (Int64, String) {
        let store = BlobStore(home: db.home)
        let data = pngBytes(seed: seed)
        let hash = try store.put(data)
        let d = CaptureDecision.classify(PasteboardSnapshot(changeCount: 1, types: ["public.png"], image: CapturedImage(data: data, uti: "public.png", width: 1, height: 1))).draft!
        return (try await db.ingest(d, blobHash: hash, source: nil, jobs: [.vision, .embed(model)]).id, hash)
    }

    // AC7.3 — a running job whose lease expired is reclaimed (process killed mid-job).
    @Test func leaseExpiryReclaims() async throws {
        let clock = TestClock()
        let db = try Database(home: try makeTempHome(), clock: clock.fn)
        _ = try await imageItem(db, seed: 1)
        let first = try await db.claimJobs(limit: 10, activeModel: "fake@1", leaseMs: 120_000)
        #expect(first.count == 2)
        #expect(try await db.claimJobs(limit: 10, activeModel: "fake@1", leaseMs: 120_000).isEmpty)
        clock.advance(ms: 120_001)
        #expect(try await db.claimJobs(limit: 10, activeModel: "fake@1", leaseMs: 120_000).count == 2)
    }

    @Test func inactiveModelJobsAreNotClaimed() async throws {
        let db = try Database(home: try makeTempHome())
        _ = try await imageItem(db, seed: 1, model: "old@1")
        let jobs = try await db.claimJobs(limit: 10, activeModel: "fake@1", leaseMs: 1000)
        #expect(jobs.map(\.kind) == ["vision"])
        #expect(try await db.claimJobs(limit: 10, activeModel: nil, leaseMs: 1000).isEmpty)
    }

    // AC7.2 — backoff then terminal failure, visible in counts.
    @Test func retriesThenFails() async throws {
        let clock = TestClock()
        let db = try Database(home: try makeTempHome(), clock: clock.fn)
        _ = try await imageItem(db, seed: 1)
        for attempt in 1...3 {
            let jobs = try await db.claimJobs(limit: 10, activeModel: nil, leaseMs: 1000)
            #expect(jobs.count == 1, "attempt \(attempt)")
            try await db.failJob(job: jobs[0], error: "boom", maxAttempts: 3)
            // Not claimable until backoff elapses.
            #expect(try await db.claimJobs(limit: 10, activeModel: nil, leaseMs: 1000).isEmpty)
            clock.advance(ms: 1000 << attempt + 1)
        }
        let c = try await db.counts()
        #expect(c.jobsFailed == 1 && c.jobsPending == 1)  // the embed job is still pending (model inactive)
        #expect(try await db.claimJobs(limit: 10, activeModel: nil, leaseMs: 1000).isEmpty)
    }

    // AC7.4 / E15 — the item is deleted while its job runs: result is dropped, not recorded as a failure.
    @Test func deletedItemDropsResult() async throws {
        let db = try Database(home: try makeTempHome())
        let (id, _) = try await imageItem(db, seed: 1)
        let jobs = try await db.claimJobs(limit: 10, activeModel: "fake@1", leaseMs: 1000)
        _ = try await db.delete(id: id)
        let vision = jobs.first { $0.kind == "vision" }!
        let embed = jobs.first { $0.kind == "embed" }!
        #expect(try await db.completeVision(job: vision, result: OCRResult(text: "x", labels: [])) == false)
        #expect(try await db.completeEmbedding(job: embed, vector: [1, 0, 0, 0]) == false)
        let c = try await db.counts()
        #expect(c.jobsFailed == 0 && c.jobsPending == 0 && c.jobsRunning == 0)
    }

    // AC9.5 — activation enqueues every image missing a vector; re-running is idempotent.
    @Test func enqueueMissingEmbeddings() async throws {
        let db = try Database(home: try makeTempHome())
        for s in 1...5 { _ = try await imageItem(db, seed: UInt8(s), model: "old@1") }
        #expect(try await db.enqueueMissingEmbeddings(modelID: "new@1", batchSize: 2) == 5)
        #expect(try await db.enqueueMissingEmbeddings(modelID: "new@1", batchSize: 2) == 0)
        #expect(try await db.semanticCoverage(modelID: "new@1") == SemanticCoverage(indexed: 0, images: 5, pending: 5, failed: 0))
    }
}

@Suite struct IndexWorkerTests {
    @Test func drainProcessesVisionAndEmbeddings() async throws {
        let db = try Database(home: try makeTempHome())
        let (id, _) = try await JobQueueTests().imageItem(db, seed: 9)
        let index = FakeIndex()
        let worker = IndexWorker(db: db, blobs: BlobStore(home: db.home), ocr: FakeOCR())
        await worker.setEmbedding(FakeEmbedder(), index: index)
        let report = await worker.drain()
        #expect(report.completed == 2 && report.failed == 0)
        let item = try #require(try await db.item(id: id))
        #expect(item.ocrText?.hasPrefix("识别文字") == true)
        #expect(item.labels == "document text")
        #expect(await index.ids == [id])
        #expect(try await db.semanticCoverage(modelID: "fake@1").indexed == 1)
        // OCR text is now searchable.
        let rs = try ReadStore(home: db.home)
        #expect(try await rs.search(QueryPlanner.plan("识别文字"), kind: .all, limit: 5).map(\.item.id) == [id])
    }

    @Test func transientFailureIsRetried() async throws {
        let clock = TestClock()
        let db = try Database(home: try makeTempHome(), clock: clock.fn)
        _ = try await JobQueueTests().imageItem(db, seed: 3)
        let ocr = FakeOCR(failures: 1)
        let worker = IndexWorker(db: db, blobs: BlobStore(home: db.home), ocr: ocr, maxAttempts: 3)
        let r1 = await worker.drain()
        #expect(r1.retried == 1 && r1.completed == 0)
        clock.advance(ms: 10_000)
        let r2 = await worker.drain()
        #expect(r2.completed == 1)
        #expect(ocr.calls.value == 2)
    }
}

@Suite struct LeaseOwnershipTests {
    // R12 — after another claimant takes over an expired lease, the old claimant's completion / failure
    // is ignored (no double attempts, no state flip), and the new claimant completes the job.
    @Test func staleClaimantCannotCompleteOrFail() async throws {
        let clock = TestClock()
        let db = try Database(home: try makeTempHome(), clock: clock.fn)
        _ = try await JobQueueTests().imageItem(db, seed: 4)
        let first = try await db.claimJobs(limit: 1, activeModels: [], leaseMs: 1000)
        clock.advance(ms: 1001)
        let second = try await db.claimJobs(limit: 1, activeModels: [], leaseMs: 1000)
        #expect(first.map(\.id) == second.map(\.id))
        try await db.failJob(job: first[0], error: "late", maxAttempts: 3)
        #expect(try await db.counts().jobsRunning == 1)                         // still owned by the second claimant
        #expect(try await db.completeVision(job: first[0], result: OCRResult(text: "old", labels: [])) == false)
        #expect(try await db.completeVision(job: second[0], result: OCRResult(text: "new", labels: [])) == true)
        #expect(try await db.counts().jobsRunning == 0)
    }
}

@Suite struct DiskSpaceTests {
    // R13 — thresholds for the disk check.
    @Test(arguments: [(Int64(200) << 20, CheckStatus.fail), (Int64(2) << 30, CheckStatus.warn), (Int64(50) << 30, CheckStatus.pass)])
    func classify(free: Int64, expected: CheckStatus) {
        #expect(Diagnostics.diskStatus(freeBytes: free) == expected)
    }
}

/// Energy: the idle loop must sleep between ticks. A wait that timed out must not break later waits
/// (cancelling a task that awaits an AsyncStream finishes the stream → every later wait returned at once).
@Suite struct IndexWorkerLoopTests {
    @Test func idleLoopSleepsBetweenTicks() async throws {
        let db = try Database(home: try makeTempHome())
        let worker = IndexWorker(db: db, blobs: BlobStore(home: db.home), ocr: FakeOCR())
        let loop = Task { await worker.runLoop(tick: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))           // ≈ 10 timed-out waits
        let passes = await worker.loopPasses
        loop.cancel()
        #expect(passes <= 20, "drain passes in 500 ms idle: \(passes)")
    }

    @Test func wakeStillWorksAfterTimeouts() async throws {
        let db = try Database(home: try makeTempHome())
        let worker = IndexWorker(db: db, blobs: BlobStore(home: db.home), ocr: FakeOCR())
        let loop = Task { await worker.runLoop(tick: .milliseconds(400)) }
        try await Task.sleep(for: .milliseconds(450))           // one wait has timed out
        let before = await worker.loopPasses
        let (id, _) = try await JobQueueTests().imageItem(db, seed: 7)
        await worker.wake()
        try await Task.sleep(for: .milliseconds(150))           // well before the next tick (≈ 800 ms)
        loop.cancel()
        #expect(await worker.loopPasses == before + 1)
        #expect(try await db.item(id: id)?.ocrText?.hasPrefix("识别文字") == true)
    }
}
