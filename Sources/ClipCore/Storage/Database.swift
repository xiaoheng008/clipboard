import Foundation

public struct SourceApp: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?
    public init(bundleID: String?, name: String?) { self.bundleID = bundleID; self.name = name }
}

public enum JobSpec: Sendable, Equatable {
    case vision
    case embed(String)   // model id
    var kind: String { if case .vision = self { "vision" } else { "embed" } }
    var modelID: String { if case .embed(let m) = self { m } else { "" } }
}

public struct IngestResult: Sendable, Equatable {
    public let id: Int64
    public let isNew: Bool
}

/// Row shown in lists. `preview` is a bounded prefix of the text (C36: no unbounded loads).
public struct ItemSummary: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let seq: Int64
    public let kind: ItemKind
    public let preview: String?
    public let blobHash: String?
    public let byteSize: Int
    public let width: Int?
    public let height: Int?
    public let sourceName: String?
    public let createdAt: Int64
    public let lastUsedAt: Int64
    public let useCount: Int
    public let pinned: Bool
    public let ocrPreview: String?
}

public struct ItemDetail: Sendable, Equatable {
    public let summary: ItemSummary
    public let text: String?
    public let ocrText: String?
    public let labels: String?
    public let sourceBundle: String?
    public var id: Int64 { summary.id }
    public var useCount: Int { summary.useCount }
    public var lastUsedAt: Int64 { summary.lastUsedAt }
    public var createdAt: Int64 { summary.createdAt }
}

public struct PageCursor: Sendable, Equatable {
    public let pinned: Bool
    public let seq: Int64
    public init(_ s: ItemSummary) { pinned = s.pinned; seq = s.seq }
}

public struct StoreCounts: Sendable, Equatable {
    public var items = 0
    public var images = 0
    public var ftsRows = 0
    public var jobsPending = 0
    public var jobsRunning = 0
    public var jobsFailed = 0
}

enum DatabaseFault: Sendable { case failAfterItemInsert }

struct InjectedFault: Error {}

/// Column list shared by every query that builds an ItemSummary.
let summaryColumns = "id, kind, substr(text, 1, 400), blob_hash, byte_size, width, height, source_name, created_at, last_used_at, use_count, pinned, substr(ocr_text, 1, 200), seq"

/// Same columns, qualified with alias `i` (for joins). Keep in sync with `summaryColumns`.
let summaryColumnsQualified = "i.id, i.kind, substr(i.text, 1, 400), i.blob_hash, i.byte_size, i.width, i.height, i.source_name, i.created_at, i.last_used_at, i.use_count, i.pinned, substr(i.ocr_text, 1, 200), i.seq"

func readSummary(_ r: SQLRow, offset o: Int32 = 0) -> ItemSummary {
    ItemSummary(
        id: r.int(o), seq: r.int(o + 13), kind: ItemKind(rawValue: r.text(o + 1) ?? "text") ?? .text, preview: r.text(o + 2),
        blobHash: r.text(o + 3), byteSize: Int(r.int(o + 4)),
        width: r.isNull(o + 5) ? nil : Int(r.int(o + 5)), height: r.isNull(o + 6) ? nil : Int(r.int(o + 6)),
        sourceName: r.text(o + 7), createdAt: r.int(o + 8), lastUsedAt: r.int(o + 9),
        useCount: Int(r.int(o + 10)), pinned: r.int(o + 11) != 0, ocrPreview: r.text(o + 12))
}

/// FTS input: text (bounded, H2) + OCR + labels. Returns whether the text was truncated.
func ftsBody(text: String?, ocr: String?, labels: String?, maxTextBytes: Int = 256 * 1024) -> (String, Bool) {
    var truncated = false
    var t = text ?? ""
    if t.utf8.count > maxTextBytes {
        truncated = true
        var end = t.utf8.index(t.utf8.startIndex, offsetBy: maxTextBytes)
        while end > t.startIndex && !t.indices.contains(end) { end = t.utf8.index(before: end) }
        t = String(t[..<end])
    }
    let body = [t, ocr ?? "", labels ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    return (body, truncated)
}

/// N-gram index input (H9): unigrams + bigrams of each whitespace-separated word, over the first
/// `maxChars` characters of text, OCR and labels. Tokens are hex-encoded UTF-8 so the `ascii`
/// tokenizer keeps them intact (punctuation and CJK included).
func ngramBody(text: String?, ocr: String?, labels: String?, maxChars: Int = 2048) -> String {
    var tokens = Set<String>()
    for part in [text, ocr, labels] {
        guard let part, !part.isEmpty else { continue }
        for word in part.prefix(maxChars).lowercased().split(whereSeparator: \.isWhitespace) {
            let chars = Array(word)
            for i in chars.indices {
                tokens.insert(ngramToken(String(chars[i])))
                if i + 1 < chars.count { tokens.insert(ngramToken(String(chars[i...i + 1]))) }
            }
        }
    }
    return tokens.joined(separator: " ")
}

func ngramToken(_ s: String) -> String {
    "x" + s.utf8.map { String(format: "%02x", $0) }.joined()
}

/// The single writer. Every method runs synchronously on the actor's executor with no `await`
/// inside a transaction, so there is no re-entrancy (C39).
public actor Database {
    let conn: SQLiteConnection
    let now: @Sendable () -> Int64
    public nonisolated let home: AppHome
    var fault: DatabaseFault?

    public static let systemClock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    public init(home: AppHome, clock: @escaping @Sendable () -> Int64 = Database.systemClock) throws {
        self.home = home
        self.now = clock
        conn = try SQLiteConnection(path: home.databaseURL.path)
        try Schema.configure(conn, readOnly: false)
        try Schema.migrate(conn, databaseURL: home.databaseURL)
        try Schema.applyPrivacySettings(conn)
    }

    func setFaultInjection(_ f: DatabaseFault?) { fault = f }

    // MARK: Items

    /// One transaction: upsert item (dedupe on content_hash) + representations + FTS + jobs.
    public func ingest(_ d: CaptureDraft, blobHash: String?, source: SourceApp?, jobs: [JobSpec]) throws -> IngestResult {
        let t = now()
        return try conn.transaction { try upsert(d, blobHash: blobHash, source: source, jobs: jobs, at: t) }
    }

    /// Same write path as `ingest`, many items per transaction (bench / bulk import).
    public func ingestBatch(_ drafts: [CaptureDraft], source: SourceApp?) throws -> Int {
        let t = now()
        return try conn.transaction {
            var n = 0
            for (i, d) in drafts.enumerated() where try upsert(d, blobHash: nil, source: source, jobs: [], at: t + Int64(i)).isNew { n += 1 }
            return n
        }
    }

    private func upsert(_ d: CaptureDraft, blobHash: String?, source: SourceApp?, jobs: [JobSpec], at t: Int64) throws -> IngestResult {
        if let existing = try conn.query("SELECT id FROM items WHERE content_hash = ?", [d.contentHash], { $0.int(0) }).first {
            try touchInTransaction(id: existing, at: t)
            return IngestResult(id: existing, isNew: false)
        }
        let (body, truncated) = ftsBody(text: d.text, ocr: nil, labels: nil)
        let seq = try nextSeq()
        try conn.run("""
            INSERT INTO items(seq, kind, content_hash, text, blob_hash, byte_size, width, height, source_bundle, source_name,
                              created_at, last_used_at, fts_truncated)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [seq, d.kind.rawValue, d.contentHash, d.text, blobHash, d.byteSize, d.image?.width, d.image?.height,
                  source?.bundleID, source?.name, t, t, truncated])
        let id = conn.lastInsertRowID
        if fault == .failAfterItemInsert { throw InjectedFault() }
        for r in d.representations {
            try conn.run("INSERT INTO representations(item_id, uti, data) VALUES (?,?,?)", [id, r.uti, r.data])
        }
        try writeIndexes(seq: seq, ftsBody: body, ngram: ngramBody(text: d.text, ocr: nil, labels: nil))
        for j in jobs { try insertJob(itemID: id, j) }
        return IngestResult(id: id, isNew: true)
    }

    func insertJob(itemID: Int64, _ j: JobSpec) throws {
        try conn.run("""
            INSERT INTO index_jobs(item_id, kind, model_id, state) VALUES (?,?,?,'pending')
            ON CONFLICT(item_id, kind, model_id) DO NOTHING
            """, [itemID, j.kind, j.modelID])
    }

    public func touch(id: Int64) throws {
        let t = now()
        try conn.transaction { try touchInTransaction(id: id, at: t) }
    }

    func nextSeq() throws -> Int64 { try conn.scalarInt("SELECT coalesce(max(seq), 0) + 1 FROM items") }

    func writeIndexes(seq: Int64, ftsBody: String, ngram: String) throws {
        try conn.run("INSERT INTO items_fts(rowid, body) VALUES (?, ?)", [seq, ftsBody])
        try conn.run("INSERT INTO items_ngram(rowid, body) VALUES (?, ?)", [seq, ngram])
    }

    func deleteIndexes(seq: Int64) throws {
        try conn.run("DELETE FROM items_fts WHERE rowid = ?", [seq])
        try conn.run("DELETE FROM items_ngram WHERE rowid = ?", [seq])
    }

    /// Renews the item's recency: new seq, and both index rows move with it (same transaction).
    func touchInTransaction(id: Int64, at t: Int64) throws {
        guard let row = try conn.query("SELECT seq, text, ocr_text, labels FROM items WHERE id = ?", [id], {
            ($0.int(0), $0.text(1), $0.text(2), $0.text(3))
        }).first else { return }
        let seq = try nextSeq()
        try deleteIndexes(seq: row.0)
        try conn.run("UPDATE items SET seq = ?, last_used_at = ?, use_count = use_count + 1 WHERE id = ?", [seq, t, id])
        try writeIndexes(seq: seq, ftsBody: ftsBody(text: row.1, ocr: row.2, labels: row.3).0, ngram: ngramBody(text: row.1, ocr: row.2, labels: row.3))
    }

    public func setPinned(id: Int64, _ on: Bool) throws {
        try conn.run("UPDATE items SET pinned = ? WHERE id = ?", [on, id])
    }

    /// Deletes the item (cascades representations/jobs/embeddings) and its FTS row.
    /// Returns blob hashes no longer referenced; the caller deletes those files after commit.
    public func delete(id: Int64) throws -> [String] {
        defer { Schema.scrubWAL(conn) }
        return try conn.transaction {
            guard let (seq, blob) = try conn.query("SELECT seq, blob_hash FROM items WHERE id = ?", [id], { ($0.int(0), $0.text(1)) }).first else { return [] }
            try deleteIndexes(seq: seq)
            try conn.run("DELETE FROM items WHERE id = ?", [id])
            guard let blob else { return [] }
            let still = try conn.scalarInt("SELECT count(*) FROM items WHERE blob_hash = ?", [blob])
            return still == 0 ? [blob] : []
        }
    }

    /// Q4: removes every item, pinned included. Returns all blob hashes that were referenced.
    public func clearAll() throws -> [String] {
        let blobs = try conn.transaction {
            let blobs = try conn.query("SELECT DISTINCT blob_hash FROM items WHERE blob_hash IS NOT NULL") { $0.text(0) ?? "" }
            try conn.run("DELETE FROM items_fts")
            try conn.run("DELETE FROM items_ngram")
            try conn.run("DELETE FROM items")
            return blobs
        }
        // Everything is gone: rebuild the file so no freed page or FTS segment keeps old content (R14).
        Schema.scrubWAL(conn)
        try? conn.exec("VACUUM")
        Schema.scrubWAL(conn)
        return blobs
    }

    public func item(id: Int64) throws -> ItemDetail? {
        try conn.query("SELECT \(summaryColumns), text, ocr_text, labels, source_bundle FROM items WHERE id = ?", [id]) { r in
            ItemDetail(summary: readSummary(r), text: r.text(14), ocrText: r.text(15), labels: r.text(16), sourceBundle: r.text(17))
        }.first
    }

    public func representations(id: Int64) throws -> [Representation] {
        try conn.query("SELECT uti, data FROM representations WHERE item_id = ?", [id]) {
            Representation(uti: $0.text(0) ?? "", data: $0.blob(1) ?? Data())
        }
    }

    /// Keyset pagination in display order: pinned first, then most recently used.
    public func page(after cursor: PageCursor?, kind: KindFilter, limit: Int) throws -> [ItemSummary] {
        try Self.page(conn, after: cursor, kind: kind, limit: limit)
    }

    static func page(_ conn: SQLiteConnection, after cursor: PageCursor?, kind: KindFilter, limit: Int) throws -> [ItemSummary] {
        var clauses: [String] = []
        var args: [any SQLBindable] = []
        if let kinds = kind.kinds {
            clauses.append("kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
            args += kinds.map(\.rawValue)
        }
        if let c = cursor {
            clauses.append("(pinned, seq) < (?, ?)")
            args += [c.pinned, c.seq]
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        args.append(limit)
        return try conn.query("SELECT \(summaryColumns) FROM items \(whereSQL) ORDER BY pinned DESC, seq DESC LIMIT ?", args) { readSummary($0) }
    }

    public func counts() throws -> StoreCounts {
        var c = StoreCounts()
        c.items = Int(try conn.scalarInt("SELECT count(*) FROM items"))
        c.images = Int(try conn.scalarInt("SELECT count(*) FROM items WHERE kind = 'image'"))
        // Contentless FTS: count docsize rows (one per indexed document).
        c.ftsRows = Int(try conn.scalarInt("SELECT count(*) FROM items_fts_docsize"))
        for (state, n) in try conn.query("SELECT state, count(*) FROM index_jobs GROUP BY state", [], { ($0.text(0) ?? "", Int($0.int(1))) }) {
            switch state {
            case "pending": c.jobsPending = n
            case "running": c.jobsRunning = n
            case "failed": c.jobsFailed = n
            default: break
            }
        }
        return c
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try conn.query("SELECT value FROM settings WHERE key = ?", [key]) { $0.text(0) }.first ?? nil
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try conn.run("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
        } else {
            try conn.run("DELETE FROM settings WHERE key = ?", [key])
        }
    }
}
