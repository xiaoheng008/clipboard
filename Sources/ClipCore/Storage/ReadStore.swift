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
        let markers = try markersReady()
        guard let pinnedQ = Self.searchSQL(plan, kind: kind, pass: .pinned, markers: markers),
              let recentQ = Self.searchSQL(plan, kind: kind, pass: .recent, markers: markers) else { return [] }
        func run(_ q: (sql: String, args: [any SQLBindable]), limit: Int) throws -> [TextHit] {
            guard limit > 0 else { return [] }
            return try conn.query(q.sql, q.args + [limit]) { r in
                TextHit(item: readSummary(r), sources: r.int(14) != 0 ? [.text] : [.ocr])
            }
        }
        let pinned = try run(pinnedQ, limit: limit)
        return pinned + (try run(recentQ, limit: limit - pinned.count))
    }

    enum Pass { case recent, pinned }

    /// One pass of a text search (LIMIT bound last by the caller).
    ///
    /// - recent: driven by the FTS / n-gram index, whose rowid = items.seq, so matches stream newest
    ///   first and the scan stops at LIMIT.
    /// - pinned: driven by `items_recent (pinned=1)`, probing the index by rowid (CROSS JOIN fixes the join
    ///   order). A common term can match a quarter of all items; walking all of them just to find the few
    ///   pinned ones made 1M-item searches take ~100 ms. Probing costs ≈ 0.2 ms per pinned item (1M items:
    ///   0 / 20 / 200 pinned ≈ 0.3 / 15 / 25 ms; 1000 ≈ 190 ms) — fine because pinned items are few (9.2).
    ///
    /// Kind tabs (FR27): with markers ready the kind is part of the index expression (an AND with a short
    /// posting list); `i.kind IN (…)` stays as well, so results are correct even while markers are rebuilt.
    static func searchSQL(_ plan: QueryPlan, kind: KindFilter, pass: Pass, markers: Bool) -> (sql: String, args: [any SQLBindable])? {
        if plan.isEmpty { return nil }
        let table: String
        var expr: String
        var filters: [String] = []
        var filterArgs: [any SQLBindable] = []
        if let fts = plan.ftsExpression {
            table = "items_fts"; expr = fts
            if markers, let kinds = kind.kinds {
                expr = "(\(fts)) AND (" + kinds.map { "\"" + KindMarker.fts($0) + "\"" }.joined(separator: " OR ") + ")"
            }
            for p in plan.likePatterns {
                filters.append("(i.text LIKE ? ESCAPE '\\' OR i.ocr_text LIKE ? ESCAPE '\\' OR i.labels LIKE ? ESCAPE '\\')")
                filterArgs += [p, p, p]
            }
        } else if let ngram = plan.ngramExpression {
            table = "items_ngram"; expr = ngram
            if markers, let kinds = kind.kinds {
                expr = "(\(ngram)) AND (" + kinds.map(KindMarker.ngram).joined(separator: " OR ") + ")"
            }
        } else { return nil }
        if let kinds = kind.kinds {
            filters.append("i.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
            filterArgs += kinds.map(\.rawValue)
        }
        // Attribution: did the first term match the item's own text?
        let first = plan.terms.first.map { "%" + QueryPlanner.escapeLike($0) + "%" } ?? "%"
        let extra = filters.isEmpty ? "" : " AND " + filters.joined(separator: " AND ")
        let sql = pass == .pinned ? """
            SELECT \(summaryColumnsQualified),
                   (i.text LIKE ? ESCAPE '\\')
            FROM items i CROSS JOIN \(table) f ON f.rowid = i.seq
            WHERE i.pinned = ? AND f.\(table) MATCH ?\(extra)
            ORDER BY i.seq DESC LIMIT ?
            """ : """
            SELECT \(summaryColumnsQualified),
                   (i.text LIKE ? ESCAPE '\\')
            FROM \(table) f JOIN items i ON i.seq = f.rowid
            WHERE i.pinned = ? AND f.\(table) MATCH ?\(extra)
            ORDER BY f.rowid DESC LIMIT ?
            """
        return (sql, [first, pass == .pinned, expr] + filterArgs)
    }


    func markersReady() throws -> Bool {
        let s = try conn.query("SELECT value FROM settings WHERE key = ?", [KindMarker.settingKey]) { $0.text(0) }.first ?? nil
        return KindMarkerState(setting: s) == .done
    }

    /// For tests: the MATCH expression of the recent pass.
    func searchExpression(_ plan: QueryPlan, kind: KindFilter) throws -> String? {
        Self.searchSQL(plan, kind: kind, pass: .recent, markers: try markersReady())?.args[2] as? String
    }

    /// For tests: item ids whose index row matches `match`.
    func indexedItemIDs(table: String, match: String) throws -> [Int64] {
        precondition(["items_fts", "items_ngram"].contains(table))
        return try conn.query("SELECT i.id FROM \(table) f JOIN items i ON i.seq = f.rowid WHERE f.\(table) MATCH ? ORDER BY i.id", [match]) { $0.int(0) }
    }

    /// For tests: number of rows in the trigram index.
    func ftsRowCount() throws -> Int { Int(try conn.scalarInt("SELECT count(*) FROM items_fts_docsize")) }

    /// For tests / bench: the query plan SQLite chose for one pass (one line per plan step).
    func explain(_ plan: QueryPlan, pass: Pass, kind: KindFilter = .all) throws -> [String] {
        guard let q = Self.searchSQL(plan, kind: kind, pass: pass, markers: try markersReady()) else { return [] }
        return try conn.query("EXPLAIN QUERY PLAN " + q.sql, q.args + [200]) { $0.text(3) ?? "" }
    }
}
