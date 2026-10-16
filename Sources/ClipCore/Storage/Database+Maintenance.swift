import Foundation

extension Database {
    public func userVersion() throws -> Int { try Schema.version(conn) }

    public func quickCheck() throws -> String {
        try conn.query("PRAGMA quick_check", []) { $0.text(0) ?? "" }.joined(separator: "; ")
    }

    /// (item id, blob hash) for every image item.
    public func referencedBlobs() throws -> [(id: Int64, hash: String)] {
        try conn.query("SELECT id, blob_hash FROM items WHERE blob_hash IS NOT NULL") { ($0.int(0), $0.text(1) ?? "") }
    }

    public func isBlobReferenced(_ hash: String) throws -> Bool {
        try conn.scalarInt("SELECT count(*) FROM items WHERE blob_hash = ?", [hash]) > 0
    }

    public func expiredLeases() throws -> Int {
        Int(try conn.scalarInt("SELECT count(*) FROM index_jobs WHERE state = 'running' AND lease_until < ?", [now()]))
    }

    public func failedJobs() throws -> Int {
        Int(try conn.scalarInt("SELECT count(*) FROM index_jobs WHERE state = 'failed'"))
    }

    public func imagesMissingOCR() throws -> Int {
        Int(try conn.scalarInt("""
            SELECT count(*) FROM items i WHERE i.kind = 'image' AND i.ocr_text IS NULL
              AND NOT EXISTS (SELECT 1 FROM index_jobs j WHERE j.item_id = i.id AND j.kind = 'vision')
            """))
    }

    public func imagesMissingEmbedding(modelID: String) throws -> Int {
        Int(try conn.scalarInt("""
            SELECT count(*) FROM items i WHERE i.kind = 'image'
              AND NOT EXISTS (SELECT 1 FROM embeddings e WHERE e.item_id = i.id AND e.model_id = ?)
              AND NOT EXISTS (SELECT 1 FROM index_jobs j WHERE j.item_id = i.id AND j.kind = 'embed' AND j.model_id = ?)
            """, [modelID, modelID]))
    }

    /// failed → pending with a fresh retry budget. Returns rows changed.
    public func resetFailedJobs(itemID: Int64? = nil) throws -> Int {
        if let itemID {
            return try conn.run("UPDATE index_jobs SET state = 'pending', attempts = 0, not_before = 0, last_error = NULL WHERE state = 'failed' AND item_id = ?", [itemID])
        }
        return try conn.run("UPDATE index_jobs SET state = 'pending', attempts = 0, not_before = 0, last_error = NULL WHERE state = 'failed'")
    }

    public func enqueueMissingVision() throws -> Int {
        try conn.transaction {
            try conn.run("""
                INSERT INTO index_jobs(item_id, kind, model_id, state)
                SELECT i.id, 'vision', '', 'pending' FROM items i
                WHERE i.kind = 'image' AND i.ocr_text IS NULL
                  AND NOT EXISTS (SELECT 1 FROM index_jobs j WHERE j.item_id = i.id AND j.kind = 'vision')
                """)
        }
    }

    /// Re-index one item from scratch (vision + optional embed). false if not an image.
    public func reenqueue(itemID: Int64, embedModel: String?) throws -> Bool {
        try conn.transaction {
            guard try conn.scalarInt("SELECT count(*) FROM items WHERE id = ? AND kind = 'image'", [itemID]) > 0 else { return false }
            try conn.run("DELETE FROM index_jobs WHERE item_id = ?", [itemID])
            try insertJob(itemID: itemID, .vision)
            if let embedModel { try insertJob(itemID: itemID, .embed(embedModel)) }
            return true
        }
    }

    public func embeddingCounts() throws -> [String: Int] {
        Dictionary(uniqueKeysWithValues: try conn.query("SELECT model_id, count(*) FROM embeddings GROUP BY model_id") { ($0.text(0) ?? "", Int($0.int(1))) })
    }

    /// Deletes one model's vectors and pending jobs.
    public func purgeModel(_ modelID: String) throws -> Int {
        try conn.transaction {
            try conn.run("DELETE FROM index_jobs WHERE kind = 'embed' AND model_id = ?", [modelID])
            return try conn.run("DELETE FROM embeddings WHERE model_id = ?", [modelID])
        }
    }

    /// Test helper: makes every pending job claimable now.
    func forceJobsClaimable() throws {
        try conn.run("UPDATE index_jobs SET not_before = 0 WHERE state = 'pending'")
    }
}
