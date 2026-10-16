import Foundation

extension Database {
    /// Writes OCR text + labels and rewrites the item's FTS row, in one transaction.
    /// Returns false when the item no longer exists (deleted while being processed, E15).
    @discardableResult
    public func applyOCRResult(itemID: Int64, ocr: String, labels: String) throws -> Bool {
        try conn.transaction { try writeVision(itemID: itemID, ocr: ocr, labels: labels) }
    }

    func writeVision(itemID: Int64, ocr: String, labels: String) throws -> Bool {
        guard let (seq, text) = try conn.query("SELECT seq, text FROM items WHERE id = ?", [itemID], { r in (r.int(0), r.text(1)) }).first else { return false }
        // Empty string (not NULL) = processed with no text found; NULL = never processed (reindex relies on this).
        try conn.run("UPDATE items SET ocr_text = ?, labels = ? WHERE id = ?", [ocr, labels, itemID])
        try deleteIndexes(seq: seq)
        try writeIndexes(seq: seq, ftsBody: ftsBody(text: text, ocr: ocr, labels: labels).0, ngram: ngramBody(text: text, ocr: ocr, labels: labels))
        return true
    }
}

public struct IndexJob: Sendable, Equatable {
    public let id: Int64
    public let itemID: Int64
    public let kind: String      // "vision" | "embed"
    public let modelID: String
    public let attempts: Int
}

public struct SemanticCoverage: Sendable, Equatable {
    public var indexed: Int
    public var images: Int
    public var pending: Int
    public var failed: Int
    public init(indexed: Int, images: Int, pending: Int, failed: Int) {
        self.indexed = indexed; self.images = images; self.pending = pending; self.failed = failed
    }
}

extension Database {
    /// Claims claimable jobs (pending past backoff, or running with an expired lease) in one transaction.
    /// Only vision jobs and embed jobs for `activeModel` are eligible; others wait for their model (C32:
    /// `--model purge-inactive` is their exit).
    public func claimJobs(limit: Int, activeModel: String?, leaseMs: Int64) throws -> [IndexJob] {
        let t = now()
        return try conn.transaction {
            let jobs = try conn.query("""
                SELECT id, item_id, kind, model_id, attempts FROM index_jobs
                WHERE ((state = 'pending' AND not_before <= ?) OR (state = 'running' AND lease_until < ?))
                  AND (kind = 'vision' OR model_id = ?)
                ORDER BY id LIMIT ?
                """, [t, t, activeModel ?? "\u{0}", limit]) {
                IndexJob(id: $0.int(0), itemID: $0.int(1), kind: $0.text(2) ?? "", modelID: $0.text(3) ?? "", attempts: Int($0.int(4)))
            }
            for j in jobs {
                try conn.run("UPDATE index_jobs SET state = 'running', lease_until = ? WHERE id = ?", [t + leaseMs, j.id])
            }
            return jobs
        }
    }

    public func blobHash(itemID: Int64) throws -> String? {
        try conn.query("SELECT blob_hash FROM items WHERE id = ?", [itemID]) { $0.text(0) }.first ?? nil
    }

    /// Result + job deletion in one transaction. false = item gone; the job row went with it.
    public func completeVision(job: IndexJob, result: OCRResult) throws -> Bool {
        try conn.transaction {
            let ok = try writeVision(itemID: job.itemID, ocr: result.text, labels: result.labels.joined(separator: " "))
            try conn.run("DELETE FROM index_jobs WHERE id = ?", [job.id])
            return ok
        }
    }

    /// UPSERT so a job processed twice (expired lease) is idempotent.
    public func completeEmbedding(job: IndexJob, vector: [Float]) throws -> Bool {
        try conn.transaction {
            let exists = try conn.scalarInt("SELECT count(*) FROM items WHERE id = ?", [job.itemID]) > 0
            if exists {
                try conn.run("""
                    INSERT INTO embeddings(item_id, model_id, dim, vec) VALUES (?,?,?,?)
                    ON CONFLICT(item_id, model_id) DO UPDATE SET dim = excluded.dim, vec = excluded.vec
                    """, [job.itemID, job.modelID, vector.count, VectorCodec.encode(vector)])
            }
            try conn.run("DELETE FROM index_jobs WHERE id = ?", [job.id])
            return exists
        }
    }

    /// attempts+1; below the limit → pending with exponential backoff (2^attempts s), else failed.
    public func failJob(id: Int64, error: String, maxAttempts: Int) throws {
        let t = now()
        try conn.transaction {
            guard let attempts = try conn.query("SELECT attempts FROM index_jobs WHERE id = ?", [id], { Int($0.int(0)) }).first else { return }
            let next = attempts + 1
            if next >= maxAttempts {
                try conn.run("UPDATE index_jobs SET state = 'failed', attempts = ?, last_error = ?, lease_until = 0 WHERE id = ?", [next, String(error.prefix(500)), id])
            } else {
                try conn.run("UPDATE index_jobs SET state = 'pending', attempts = ?, last_error = ?, lease_until = 0, not_before = ? WHERE id = ?",
                             [next, String(error.prefix(500)), t + (Int64(1000) << Int64(next)), id])
            }
        }
    }

    /// Backfill on model activation: one transaction per batch; UNIQUE makes re-runs idempotent.
    public func enqueueMissingEmbeddings(modelID: String, batchSize: Int = 1000) throws -> Int {
        var total = 0
        while true {
            let n = try conn.transaction {
                try conn.run("""
                    INSERT INTO index_jobs(item_id, kind, model_id, state)
                    SELECT i.id, 'embed', ?, 'pending' FROM items i
                    WHERE i.kind = 'image'
                      AND NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.item_id = i.id AND e.model_id = ?)
                      AND NOT EXISTS (SELECT 1 FROM index_jobs j WHERE j.item_id = i.id AND j.kind = 'embed' AND j.model_id = ?)
                    LIMIT ?
                    """, [modelID, modelID, modelID, batchSize])
            }
            total += n
            if n < batchSize { return total }
        }
    }

    public func semanticCoverage(modelID: String) throws -> SemanticCoverage {
        SemanticCoverage(
            indexed: Int(try conn.scalarInt("SELECT count(*) FROM embeddings WHERE model_id = ?", [modelID])),
            images: Int(try conn.scalarInt("SELECT count(*) FROM items WHERE kind = 'image'")),
            pending: Int(try conn.scalarInt("SELECT count(*) FROM index_jobs WHERE kind = 'embed' AND model_id = ? AND state != 'failed'", [modelID])),
            failed: Int(try conn.scalarInt("SELECT count(*) FROM index_jobs WHERE kind = 'embed' AND model_id = ? AND state = 'failed'", [modelID])))
    }

    /// Streams one model's vectors for building the in-memory index.
    public func loadEmbeddings(modelID: String, dim: Int) throws -> (entries: [(id: Int64, vector: [Float16])], skippedWrongDim: Int) {
        var out: [(id: Int64, vector: [Float16])] = []
        var skipped = 0
        try conn.forEach("SELECT item_id, dim, vec FROM embeddings WHERE model_id = ?", [modelID]) { r in
            guard Int(r.int(1)) == dim, let d = r.blob(2), d.count == dim * 2 else { skipped += 1; return }
            out.append((r.int(0), VectorCodec.decodeHalves(d)))
        }
        return (out, skipped)
    }
}
