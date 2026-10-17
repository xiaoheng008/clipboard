import Foundation
import Testing
@testable import ClipCore

/// FR27: kind markers in both search indexes (docs/scv/2.2 「分类标记」, 3.1 §4.5).
@Suite struct KindMarkerTests {
    static func snapshot(_ kind: ItemKind, _ text: String) -> PasteboardSnapshot {
        switch kind {
        case .url: return textSnapshot("https://example.com/\(text)")
        case .file:
            var s = textSnapshot("/Users/x/\(text).txt"); s.types.append("public.file-url"); s.fileURLs = ["file:///Users/x/\(text).txt"]; return s
        case .image:
            return PasteboardSnapshot(changeCount: 1, types: ["public.png"],
                                      image: CapturedImage(data: pngBytes(seed: UInt8(text.count % 250)), uti: "public.png", width: 4, height: 4))
        case .rich:
            var s = textSnapshot(text); s.types.append("public.rtf"); s.rtf = Data("{\\rtf1 \(text)}".utf8); return s
        case .text: return textSnapshot(text)
        }
    }

    /// One item of every kind, all containing "clipboard" in their indexed text (images via OCR).
    func library() async throws -> (Database, ReadStore, [ItemKind: Int64]) {
        let clock = TestClock()
        let home = try makeTempHome()
        let db = try Database(home: home, clock: clock.fn)
        var ids: [ItemKind: Int64] = [:]
        for kind in ItemKind.allCases {
            let draft = try #require(CaptureDecision.classify(Self.snapshot(kind, "clipboard-\(kind.rawValue)")).draft)
            #expect(draft.kind == kind, "fixture for \(kind)")
            ids[kind] = try await db.ingest(draft, blobHash: kind == .image ? "h-image" : nil, source: nil, jobs: []).id
            clock.advance(ms: 10)
        }
        // Image text arrives later through OCR — that index write must carry the marker too.
        #expect(try await db.applyOCRResult(itemID: ids[.image]!, ocr: "clipboard screenshot", labels: ""))
        return (db, try ReadStore(home: home), ids)
    }

    // AC27.1: every write path indexes the item's own marker, and only that one.
    @Test func everyKindCarriesItsOwnMarker() async throws {
        let (db, rs, ids) = try await library()
        try await db.touch(id: ids[.text]!)                       // use → new seq → index rows rewritten
        for kind in ItemKind.allCases {
            let fts = try await rs.indexedItemIDs(table: "items_fts", match: "\"\(KindMarker.fts(kind))\"")
            let ngram = try await rs.indexedItemIDs(table: "items_ngram", match: KindMarker.ngram(kind))
            #expect(fts == [ids[kind]!], "\(kind) fts")
            #expect(ngram == [ids[kind]!], "\(kind) ngram")
        }
    }

    // AC27.1 反: private-use characters in user content cannot forge a marker.
    @Test func userTextCannotForgeMarkers() async throws {
        let home = try makeTempHome()
        let db = try Database(home: home)
        let forged = "x" + KindMarker.fts(.image) + "y"
        _ = try await db.ingest(CaptureDecision.classify(textSnapshot(forged)).draft!, blobHash: nil, source: nil, jobs: [])
        let rs = try ReadStore(home: home)
        #expect(try await rs.indexedItemIDs(table: "items_fts", match: "\"\(KindMarker.fts(.image))\"").isEmpty)
        #expect(QueryPlanner.plan(forged).terms == ["xy"])
    }

    // AC27.2: kind tabs return exactly the items of that kind (rich counts as 文本), long and short queries.
    @Test func kindTabsUseMarkersAndStayCorrect() async throws {
        let (_, rs, ids) = try await library()
        let expected: [KindFilter: Set<Int64>] = [.text: [ids[.text]!, ids[.rich]!], .url: [ids[.url]!], .file: [ids[.file]!], .image: [ids[.image]!]]
        for (filter, want) in expected {
            for q in ["clipboard", "cl"] {
                #expect(Set(try await rs.search(QueryPlanner.plan(q), kind: filter, limit: 50).map(\.item.id)) == want, "\(filter) \(q)")
            }
            // With markers ready, the index expression itself carries the kind (no walk over other kinds).
            let sql = try #require(try await rs.searchExpression(QueryPlanner.plan("clipboard"), kind: filter))
            #expect(sql.contains(KindMarker.fts(filter.kinds![0])), "\(filter): \(sql)")
        }
        #expect(Set(try await rs.search(QueryPlanner.plan("clipboard"), kind: .all, limit: 50).map(\.item.id)) == Set(ids.values))
    }

    /// Turns a fresh v2 library into what a v1 library looked like: no markers, user_version 1.
    static func downgradeToV1(_ home: AppHome) throws {
        let c = try SQLiteConnection(path: home.databaseURL.path)
        let rows = try c.query("SELECT seq, text, ocr_text, labels FROM items", []) { ($0.int(0), $0.text(1), $0.text(2), $0.text(3)) }
        try c.transaction {
            for r in rows {
                try c.run("DELETE FROM items_fts WHERE rowid = ?", [r.0])
                try c.run("DELETE FROM items_ngram WHERE rowid = ?", [r.0])
                try c.run("INSERT INTO items_fts(rowid, body) VALUES (?, ?)", [r.0, ftsBody(text: r.1, ocr: r.2, labels: r.3, kind: nil).0])
                try c.run("INSERT INTO items_ngram(rowid, body) VALUES (?, ?)", [r.0, ngramBody(text: r.1, ocr: r.2, labels: r.3, kind: nil)])
            }
            try c.run("DELETE FROM settings WHERE key = ?", [KindMarker.settingKey])
            try c.exec("PRAGMA user_version = 1")
        }
    }

    // AC27.3: v1 → v2 is instant; rebuild runs in batches; kind search stays correct throughout.
    @Test func migrationRebuildsInBatches() async throws {
        let (db0, _, ids) = try await library()
        let home = db0.home
        try Self.downgradeToV1(home)
        let db = try Database(home: home)
        let rs = try ReadStore(home: home)
        #expect(try await db.kindMarkerState() == .rebuilding(cursor: Int64(ItemKind.allCases.count) + 1))   // max(seq) + 1
        // While rebuilding, the kind filter must not rely on markers (old rows have none).
        #expect(try await rs.searchExpression(QueryPlanner.plan("clipboard"), kind: .url)?.contains(KindMarker.fts(.url)) == false)
        var batches = 0
        while try await db.rebuildKindMarkers(batch: 2) { batches += 1
            #expect(Set(try await rs.search(QueryPlanner.plan("clipboard"), kind: .url, limit: 50).map(\.item.id)) == [ids[.url]!])
        }
        #expect(batches == 3)                                     // 5 items, 2 per batch
        #expect(try await db.kindMarkerState() == .done)
        for kind in ItemKind.allCases {
            #expect(try await rs.indexedItemIDs(table: "items_fts", match: "\"\(KindMarker.fts(kind))\"") == [ids[kind]!])
        }
        #expect(try await db.rebuildKindMarkers(batch: 2) == false)   // done stays done
    }

    // AC27.4: a batch that dies before commit leaves the cursor unchanged; the retry finishes with one row each.
    @Test func interruptedBatchResumes() async throws {
        let (db0, _, ids) = try await library()
        try Self.downgradeToV1(db0.home)
        let db = try Database(home: db0.home)
        let before = try await db.kindMarkerState()
        await db.setFaultInjection(.failInMarkerRebuild)
        await #expect(throws: InjectedFault.self) { try await db.rebuildKindMarkers(batch: 2) }
        #expect(try await db.kindMarkerState() == before)
        await db.setFaultInjection(nil)
        while try await db.rebuildKindMarkers(batch: 2) {}
        let rs = try ReadStore(home: db0.home)
        #expect(try await rs.indexedItemIDs(table: "items_fts", match: "\"clipboard\"").count == ids.count)
        #expect(try await rs.ftsRowCount() == ids.count)
    }

    // The driver used by the app / CLI runs batches to completion and reports what is left.
    @Test func driverFinishesTheRebuild() async throws {
        let (db0, _, _) = try await library()
        try Self.downgradeToV1(db0.home)
        let db = try Database(home: db0.home)
        #expect(try await db.kindMarkerRemaining() == ItemKind.allCases.count)
        let left = LockedArray()
        #expect(try await db.rebuildAllKindMarkers(batch: 2, pause: .zero) { left.append($0) } == 3)
        #expect(left.values == [3, 1, 0])
        #expect(try await db.kindMarkerState() == .done)
        #expect(try await db.kindMarkerRemaining() == 0)
    }

    // A library created by this version needs no rebuild.
    @Test func freshLibraryIsDone() async throws {
        let db = try Database(home: try makeTempHome())
        #expect(try await db.kindMarkerState() == .done)
        #expect(try await db.rebuildKindMarkers(batch: 10) == false)
    }
}

final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    func append(_ v: Int) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return items }
}
