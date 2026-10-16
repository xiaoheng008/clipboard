import Foundation

/// Read-only connection (WAL allows reads concurrent with the writer). Results are always committed data.
public actor ReadStore {
    let conn: SQLiteConnection

    public init(home: AppHome) throws {
        conn = try SQLiteConnection(path: home.databaseURL.path, readOnly: true)
        try Schema.configure(conn, readOnly: true)
        let v = try Schema.version(conn)
        if v > Schema.currentVersion { throw SchemaError.newerThanApp(found: v, supported: Schema.currentVersion) }
    }

    public func page(after cursor: PageCursor?, kind: KindFilter, limit: Int) throws -> [ItemSummary] {
        try Database.page(conn, after: cursor, kind: kind, limit: limit)
    }

    public func summaries(ids: [Int64]) throws -> [Int64: ItemSummary] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: ItemSummary] = [:]
        // Chunk to stay under SQLite's variable limit.
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let sql = "SELECT \(summaryColumns) FROM items WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))"
            for s in try conn.query(sql, chunk, { readSummary($0) }) { out[s.id] = s }
        }
        return out
    }

    /// Text search, newest first. The driving index (trigram FTS when any term has ≥3 chars, otherwise
    /// the n-gram index) has rowid = items.seq, so SQLite streams matches in recency order and stops at
    /// LIMIT instead of sorting every match (bench: 1M items). Other short terms are verified with LIKE.
    public func search(_ plan: QueryPlan, kind: KindFilter, limit: Int) throws -> [TextHit] {
        if plan.isEmpty { return [] }
        let table: String
        let expr: String
        var filters: [String] = []
        var filterArgs: [any SQLBindable] = []
        if let fts = plan.ftsExpression {
            table = "items_fts"; expr = fts
            for p in plan.likePatterns {
                filters.append("(i.text LIKE ? ESCAPE '\\' OR i.ocr_text LIKE ? ESCAPE '\\' OR i.labels LIKE ? ESCAPE '\\')")
                filterArgs += [p, p, p]
            }
        } else if let ngram = plan.ngramExpression {
            table = "items_ngram"; expr = ngram
        } else { return [] }
        if let kinds = kind.kinds {
            filters.append("i.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
            filterArgs += kinds.map(\.rawValue)
        }
        // Attribution: did the first term match the item's own text?
        let first = plan.terms.first.map { "%" + QueryPlanner.escapeLike($0) + "%" } ?? "%"
        let extra = filters.isEmpty ? "" : " AND " + filters.joined(separator: " AND ")
        func run(pinned: Bool, limit: Int) throws -> [TextHit] {
            guard limit > 0 else { return [] }
            let sql = """
                SELECT \(summaryColumnsQualified),
                       (i.text LIKE ? ESCAPE '\\')
                FROM \(table) f JOIN items i ON i.seq = f.rowid
                WHERE f.\(table) MATCH ? AND i.pinned = ?\(extra)
                ORDER BY f.rowid DESC LIMIT ?
                """
            return try conn.query(sql, [first, expr, pinned] + filterArgs + [limit]) { r in
                TextHit(item: readSummary(r), sources: r.int(14) != 0 ? [.text] : [.ocr])
            }
        }
        let pinned = try run(pinned: true, limit: limit)
        return pinned + (try run(pinned: false, limit: limit - pinned.count))
    }

    /// For diagnostics / bench: the query plan SQLite chose.
    public func explain(_ plan: QueryPlan) throws -> String {
        guard let fts = plan.ftsExpression else { return "" }
        return try conn.query("EXPLAIN QUERY PLAN SELECT i.id FROM items_fts f JOIN items i ON i.seq = f.rowid WHERE f.items_fts MATCH ? AND i.pinned = 0 ORDER BY f.rowid DESC LIMIT 200", [fts]) { $0.text(3) ?? "" }.joined(separator: " | ")
    }
}
