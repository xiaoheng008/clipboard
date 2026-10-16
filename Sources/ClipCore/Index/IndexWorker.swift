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
    /// One embedding backend per slot (FR20).
    var backends: [ModelSlot: (provider: EmbeddingProvider, index: VectorIndex?)] = [:]
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var progress: (@Sendable () -> Void)?

    public func setProgressHandler(_ h: (@Sendable () -> Void)?) { progress = h }
    private var running = false

    public init(db: Database, blobs: BlobStore, ocr: OCRProvider?, maxAttempts: Int = 3, leaseMs: Int64 = 120_000) {
        self.db = db; self.blobs = blobs; self.ocr = ocr; self.maxAttempts = maxAttempts; self.leaseMs = leaseMs
    }

    /// Swaps the image-slot backend. nil disables it (its jobs wait).
    public func setEmbedding(_ provider: EmbeddingProvider?, index: VectorIndex?) {
        setEmbedding(slot: .image, provider, index: index)
    }

    public func setEmbedding(slot: ModelSlot, _ provider: EmbeddingProvider?, index: VectorIndex?) {
        if let provider { backends[slot] = (provider, index) } else { backends[slot] = nil }
    }

    public var activeModelID: String? { backends[.image]?.provider.modelID }
    var activeModelIDs: [String] { backends.values.map(\.provider.modelID) }

    /// Processes claimable jobs until none are left (respecting backoff). Used by CLI `--run-jobs` and the loop.
    public func drain(batch: Int = 16) async -> DrainReport {
        var report = DrainReport()
        while true {
            let jobs: [IndexJob]
            do { jobs = try await db.claimJobs(limit: batch, activeModels: activeModelIDs, leaseMs: leaseMs) }
            catch { Log.shared.event("jobs.claim_failed", ["error": .error(error)]); return report }
            if jobs.isEmpty { return report }
            for job in jobs { await process(job, &report) }
        }
    }

    private func process(_ job: IndexJob, _ report: inout DrainReport) async {
        do {
            let started = Date()
            switch job.kind {
            case "vision":
                guard let hash = try await db.blobHash(itemID: job.itemID) else { return try await drop(job, &report) }
                guard let ocr else { throw ProviderError.unsupported("no OCR provider") }
                let r = try await ocr.recognize(imageAt: blobs.url(for: hash))
                if try await db.completeVision(job: job, result: r) { report.completed += 1 } else { report.dropped += 1 }
            case "embed":
                guard let backend = backends.values.first(where: { $0.provider.modelID == job.modelID }) else {
                    throw ProviderError.modelUnavailable(job.modelID)
                }
                let v: [Float]
                if let hash = try await db.blobHash(itemID: job.itemID) {
                    v = try await backend.provider.embed(imageAt: blobs.url(for: hash))
                } else if let text = try await db.embedText(itemID: job.itemID), !text.isEmpty {
                    v = try await backend.provider.embed(document: text)
                } else {
                    return try await drop(job, &report)            // deleted, or nothing to embed
                }
                if try await db.completeEmbedding(job: job, vector: v) {
                    if let index = backend.index, index.modelID == job.modelID { await index.upsert(id: job.itemID, vector: v) }
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

    /// The job has nothing left to act on (item deleted / no content): remove it without a result.
    private func drop(_ job: IndexJob, _ report: inout DrainReport) async throws {
        _ = try await db.completeVision(job: IndexJob(id: job.id, itemID: -1, kind: job.kind, modelID: job.modelID, attempts: job.attempts),
                                        result: OCRResult(text: "", labels: []))
        report.dropped += 1
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
