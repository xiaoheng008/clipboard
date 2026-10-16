import Foundation

public struct DrainReport: Sendable, Equatable {
    public var completed = 0
    public var dropped = 0     // item deleted while processing
    public var retried = 0
    public var failed = 0
}

/// Background executor for index jobs (the local "Outbox" executor). Recovery is driven by
/// `drain()` at startup and on every wake; leases make a killed run resumable by anyone.
public actor IndexWorker {
    let db: Database
    let blobs: BlobStore
    let ocr: OCRProvider?
    let maxAttempts: Int
    let leaseMs: Int64
    var embedder: EmbeddingProvider?
    var index: VectorIndex?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var progress: (@Sendable () -> Void)?

    public func setProgressHandler(_ h: (@Sendable () -> Void)?) { progress = h }
    private var running = false

    public init(db: Database, blobs: BlobStore, ocr: OCRProvider?, maxAttempts: Int = 3, leaseMs: Int64 = 120_000) {
        self.db = db; self.blobs = blobs; self.ocr = ocr; self.maxAttempts = maxAttempts; self.leaseMs = leaseMs
    }

    /// Swaps the active embedding backend. nil disables semantic indexing (jobs wait).
    public func setEmbedding(_ provider: EmbeddingProvider?, index: VectorIndex?) {
        embedder = provider
        self.index = index
    }

    public var activeModelID: String? { embedder?.modelID }

    /// Processes claimable jobs until none are left (respecting backoff). Used by CLI `--run-jobs` and the loop.
    public func drain(batch: Int = 16) async -> DrainReport {
        var report = DrainReport()
        while true {
            let jobs: [IndexJob]
            do { jobs = try await db.claimJobs(limit: batch, activeModel: embedder?.modelID, leaseMs: leaseMs) }
            catch { Log.shared.event("jobs.claim_failed", ["error": .error(error)]); return report }
            if jobs.isEmpty { return report }
            for job in jobs { await process(job, &report) }
        }
    }

    private func process(_ job: IndexJob, _ report: inout DrainReport) async {
        do {
            guard let hash = try await db.blobHash(itemID: job.itemID) else {
                // Not an image or already deleted: complete as dropped.
                _ = try await db.completeVision(job: job, result: OCRResult(text: "", labels: []))
                report.dropped += 1
                return
            }
            let url = blobs.url(for: hash)
            let started = Date()
            switch job.kind {
            case "vision":
                guard let ocr else { throw ProviderError.unsupported("no OCR provider") }
                let r = try await ocr.recognize(imageAt: url)
                if try await db.completeVision(job: job, result: r) { report.completed += 1 } else { report.dropped += 1 }
            case "embed":
                guard let embedder, embedder.modelID == job.modelID else { throw ProviderError.modelUnavailable(job.modelID) }
                let v = try await embedder.embed(imageAt: url)
                if try await db.completeEmbedding(job: job, vector: v) {
                    if let index, index.modelID == job.modelID { await index.upsert(id: job.itemID, vector: v) }
                    report.completed += 1
                } else { report.dropped += 1 }
            default:
                throw ProviderError.unsupported("job kind \(job.kind)")
            }
            progress?()
            Log.shared.event("jobs.done", ["kind": .label(job.kind), "item": .int(job.itemID), "ms": .int(Int64(Date().timeIntervalSince(started) * 1000))])
        } catch {
            Log.shared.event("jobs.error", ["kind": .label(job.kind), "item": .int(job.itemID), "error": .error(error)])
            do {
                try await db.failJob(id: job.id, error: String(describing: error), maxAttempts: maxAttempts)
                if job.attempts + 1 >= maxAttempts { report.failed += 1 } else { report.retried += 1 }
            } catch {
                Log.shared.event("jobs.fail_record_failed", ["error": .error(error)])
            }
        }
    }

    /// Runs forever: drain, then sleep until woken or `tick` elapses (backoff deadlines).
    public func runLoop(tick: Duration = .seconds(5)) async {
        guard !running else { return }
        running = true
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeContinuation = cont
        while !Task.isCancelled {
            _ = await drain()
            await withTaskGroup(of: Void.self) { g in
                g.addTask { var it = stream.makeAsyncIterator(); _ = await it.next() }
                g.addTask { try? await Task.sleep(for: tick) }
                await g.next()
                g.cancelAll()
            }
        }
        running = false
    }

    public func wake() { wakeContinuation?.yield() }
}
