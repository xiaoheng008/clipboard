import Foundation
import Testing
@testable import ClipCore

@Suite struct DatabaseTests {
    func draft(_ s: String) -> CaptureDraft { CaptureDecision.classify(textSnapshot(s)).draft! }

    // AC2.1 — same content twice → one item, use_count 2, last_used advanced.
    @Test func dedupeTouchesExisting() async throws {
        let clock = TestClock()
        let db = try Database(home: try makeTempHome(), clock: clock.fn)
        let a = try await db.ingest(draft("hello"), blobHash: nil, source: nil, jobs: [])
        clock.advance(ms: 1000)
        let b = try await db.ingest(draft("hello"), blobHash: nil, source: nil, jobs: [])
        #expect(a.isNew && !b.isNew && a.id == b.id)
        let item = try #require(try await db.item(id: a.id))
        #expect(item.useCount == 2)
        #expect(item.lastUsedAt == clock.now)
        #expect(item.createdAt == clock.now - 1000)
        #expect(try await db.counts().items == 1)
    }

    // I3 — every item has exactly one FTS row; deleting removes it.
    @Test func ftsRowLifecycle() async throws {
        let db = try Database(home: try makeTempHome())
        let a = try await db.ingest(draft("剪切板历史记录"), blobHash: nil, source: nil, jobs: [])
        _ = try await db.ingest(draft("another one"), blobHash: nil, source: nil, jobs: [])
        #expect(try await db.counts().ftsRows == 2)
        _ = try await db.delete(id: a.id)
        let c = try await db.counts()
        #expect(c.items == 1 && c.ftsRows == 1)
    }

    // AC4.2 — a failure inside ingest leaves no partial item / FTS / job rows.
    @Test func ingestIsAtomic() async throws {
        let db = try Database(home: try makeTempHome())
        await db.setFaultInjection(.failAfterItemInsert)
        await #expect(throws: (any Error).self) {
            _ = try await db.ingest(draft("boom"), blobHash: nil, source: nil, jobs: [.vision])
        }
        await db.setFaultInjection(nil)
        let c = try await db.counts()
        #expect(c.items == 0 && c.ftsRows == 0 && c.jobsPending == 0)
    }

    // AC12.1 — pinned first, then most recently used.
    @Test func pageOrdering() async throws {
        let clock = TestClock()
        let db = try Database(home: try makeTempHome(), clock: clock.fn)
        var ids: [Int64] = []
        for s in ["one", "two", "three"] { ids.append(try await db.ingest(draft(s), blobHash: nil, source: nil, jobs: []).id); clock.advance(ms: 10) }
        try await db.setPinned(id: ids[0], true)
        let page = try await db.page(after: nil, kind: .all, limit: 10)
        #expect(page.map(\.id) == [ids[0], ids[2], ids[1]])
        // Cursor pagination returns the rest without overlap.
        let first = try await db.page(after: nil, kind: .all, limit: 2)
        let rest = try await db.page(after: first.last.map(PageCursor.init), kind: .all, limit: 10)
        #expect(first.map(\.id) + rest.map(\.id) == page.map(\.id))
    }

    // AC12.2 — delete returns now-unreferenced blobs; cascades jobs.
    @Test func deleteCascades() async throws {
        let db = try Database(home: try makeTempHome())
        let img = CaptureDecision.classify(PasteboardSnapshot(changeCount: 1, types: ["public.png"], image: CapturedImage(data: pngBytes(seed: 2), uti: "public.png", width: 1, height: 1))).draft!
        let r = try await db.ingest(img, blobHash: "abc", source: nil, jobs: [.vision, .embed("m@1")])
        #expect(try await db.counts().jobsPending == 2)
        let freed = try await db.delete(id: r.id)
        #expect(freed == ["abc"])
        #expect(try await db.counts().jobsPending == 0)
    }

    // AC12.3 / Q4 — clear removes everything, pinned included.
    @Test func clearAllIncludesPinned() async throws {
        let db = try Database(home: try makeTempHome())
        let a = try await db.ingest(draft("keep?"), blobHash: nil, source: nil, jobs: [])
        try await db.setPinned(id: a.id, true)
        _ = try await db.ingest(draft("other"), blobHash: nil, source: nil, jobs: [])
        _ = try await db.clearAll()
        let c = try await db.counts()
        #expect(c.items == 0 && c.ftsRows == 0)
    }

    // AC4.4 / E21 — refuse to open a database from a newer schema.
    @Test func refusesNewerSchema() throws {
        let home = try makeTempHome()
        _ = try Database(home: home)
        let conn = try SQLiteConnection(path: home.databaseURL.path)
        try conn.exec("PRAGMA user_version = \(Schema.currentVersion + 1)")
        #expect(throws: SchemaError.self) { _ = try Database(home: home) }
    }

    @Test func settingsRoundTrip() async throws {
        let db = try Database(home: try makeTempHome())
        #expect(try await db.setting("hotkey") == nil)
        try await db.setSetting("hotkey", "9:256")
        #expect(try await db.setting("hotkey") == "9:256")
        try await db.setSetting("hotkey", nil)
        #expect(try await db.setting("hotkey") == nil)
    }
}

@Suite struct BlobStoreTests {
    @Test func putIsContentAddressedAndIdempotent() throws {
        let home = try makeTempHome()
        let store = BlobStore(home: home)
        let data = pngBytes(seed: 7)
        let h1 = try store.put(data)
        let h2 = try store.put(data)
        #expect(h1 == h2 && h1 == ContentHasher.sha256Hex(data))
        #expect(FileManager.default.contentsEqual(atPath: store.url(for: h1).path, andPath: store.url(for: h1).path))
        #expect(try Data(contentsOf: store.url(for: h1)) == data)
        #expect(try store.allHashes() == [h1])
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.tmpURL.path).isEmpty)
        try store.delete(h1)
        #expect(try store.allHashes().isEmpty)
    }
}

// AC17 — cross-cutting structural constraints, enforced by scanning sources.
@Suite struct StructureTests {
    @Test func sqliteCallsOnlyInWrapper() {
        let offenders = swiftSources(under: "Sources").filter { $0.text.contains("sqlite3_") && !$0.path.hasSuffix("Storage/SQLite.swift") }
        #expect(offenders.map(\.path) == [])
    }

    @Test func coreHasNoPlatformFrameworks() {
        let banned = ["import AppKit", "import Vision", "import CoreML", "import Translation", "import Carbon", "import SwiftUI"]
        let offenders = swiftSources(under: "Sources/ClipCore").filter { f in banned.contains { f.text.contains($0) } }
        #expect(offenders.map(\.path) == [])
    }

    @Test func pasteboardOnlyInPlatform() {
        let offenders = swiftSources(under: "Sources").filter { $0.text.contains("NSPasteboard") && !$0.path.hasPrefix("Sources/ClipPlatform/") }
        #expect(offenders.map(\.path) == [])
    }
}
