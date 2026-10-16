import Foundation
import Testing
@testable import ClipCore

final class FakeWriter: PasteboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 100
    var written: [(String?, [Representation], URL?)] = []
    func write(text: String?, representations: [Representation], imageFile: URL?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        written.append((text, representations, imageFile))
        return count
    }
}

@Suite struct ClipServiceTests {
    func makeRuntime(clock: TestClock = TestClock()) async throws -> (Runtime, FakeWriter) {
        let writer = FakeWriter()
        let services = PlatformServices(
            ocr: FakeOCR(), translator: NoTranslator(), pasteboard: writer,
            makeProvider: { m in var e = FakeEmbedder(); e.modelID = m.id; return e },
            memoryGB: { 16 })
        let rt = try await Runtime.open(home: try makeTempHome(), services: services, clock: clock.fn, startWorker: false)
        return (rt, writer)
    }

    var ctx: CaptureContext { CaptureContext(frontmostBundleID: "com.example.app", frontmostName: "Example", excludedBundleIDs: [], lastSelfWriteChangeCount: nil) }

    func image(_ seed: UInt8, cc: Int = 1) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: cc, types: ["public.png"], image: CapturedImage(data: pngBytes(seed: seed), uti: "public.png", width: 4, height: 4))
    }

    @Test func ingestTextRecordsSourceApp() async throws {
        let (rt, _) = try await makeRuntime()
        let out = await rt.service.ingest(textSnapshot("hello"), context: ctx)
        guard case .stored(let id, true) = out else { Issue.record("\(out)"); return }
        let item = try #require(try await rt.db.item(id: id))
        #expect(item.summary.sourceName == "Example" && item.sourceBundle == "com.example.app")
    }

    @Test func ingestImageWritesBlobAndEnqueuesJobs() async throws {
        let (rt, _) = try await makeRuntime()
        try await rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
        let out = await rt.service.ingest(image(1), context: ctx)
        guard case .stored(let id, true) = out else { Issue.record("\(out)"); return }
        let hash = try #require(try await rt.db.blobHash(itemID: id))
        #expect(rt.blobs.exists(hash))
        #expect(try await rt.db.counts().jobsPending == 2)
        let report = await rt.worker.drain()
        #expect(report.completed == 2)
        #expect(try await rt.db.semanticCoverage(modelID: "mobileclip-s0@1").indexed == 1)
    }

    // AC3.3 / AC11.1 — copy back writes the pasteboard, touches the item, and the echo is skipped.
    @Test func copyBackIsNotRecapturedAsNewItem() async throws {
        let (rt, writer) = try await makeRuntime()
        guard case .stored(let id, _) = await rt.service.ingest(textSnapshot("again"), context: ctx) else { return }
        try await rt.service.copyBack(id: id)
        #expect(writer.written.count == 1 && writer.written[0].0 == "again")
        // The watcher then sees the change it caused (changeCount 101) with no marker type.
        let echo = await rt.service.ingest(textSnapshot("again", changeCount: 101), context: await rt.service.captureContext(frontmost: nil))
        #expect(echo == .skipped(.selfWrite))
        #expect(try await rt.db.item(id: id)?.useCount == 2)
    }

    @Test func excludedAppsComeFromSettings() async throws {
        let (rt, _) = try await makeRuntime()
        try await rt.service.setExcludedApps(["com.example.secret"])
        let c = await rt.service.captureContext(frontmost: SourceApp(bundleID: "com.example.secret", name: "S"))
        #expect(await rt.service.ingest(textSnapshot("pw"), context: c) == .skipped(.excludedApp))
        #expect(await rt.service.skipCounts()[.excludedApp] == 1)
    }

    // AC12.2 / AC8.5 — delete removes blob file and vector.
    @Test func deleteRemovesEverything() async throws {
        let (rt, _) = try await makeRuntime()
        try await rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
        guard case .stored(let id, _) = await rt.service.ingest(image(2), context: ctx) else { return }
        _ = await rt.worker.drain()
        let hash = try #require(try await rt.db.blobHash(itemID: id))
        #expect(await rt.engine.activeIndex?.count() == 1)
        try await rt.service.delete(id: id)
        #expect(!rt.blobs.exists(hash))
        #expect(await rt.engine.activeIndex?.count() == 0)
        #expect(try await rt.db.counts().items == 0)
    }

    @Test func clearAllRemovesBlobsAndVectors() async throws {
        let (rt, _) = try await makeRuntime()
        try await rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
        _ = await rt.service.ingest(image(3), context: ctx)
        _ = await rt.service.ingest(textSnapshot("t"), context: ctx)
        _ = await rt.worker.drain()
        try await rt.service.clearAll()
        #expect(try rt.blobs.allHashes().isEmpty)
        #expect(await rt.engine.activeIndex?.count() == 0)
        #expect(try await rt.db.counts().items == 0)
    }

    @Test func searchFusesTextAndSemantic() async throws {
        let (rt, _) = try await makeRuntime()
        try await rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
        guard case .stored(let img, _) = await rt.service.ingest(image(4), context: ctx) else { return }
        guard case .stored(let txt, _) = await rt.service.ingest(textSnapshot("a cat photo"), context: ctx) else { return }
        _ = await rt.worker.drain()
        let r = await rt.service.search(SearchRequest(requestID: 1, text: "cat", kind: .all, semantic: true, limit: 20))
        #expect(Set(r.hits.map(\.id)) == [img, txt])
        #expect(r.hits.first { $0.id == img }?.sources == [.semantic])
        #expect(r.semantic == .ready(translated: nil))
        // Text-only kind filter skips semantic search.
        let t = await rt.service.search(SearchRequest(requestID: 2, text: "cat", kind: .text, semantic: true, limit: 20))
        #expect(t.hits.map(\.id) == [txt])
    }

    // AC8.2
    @Test func searchWithoutModelReportsNotEnabled() async throws {
        let (rt, _) = try await makeRuntime()
        _ = await rt.service.ingest(textSnapshot("cat"), context: ctx)
        let r = await rt.service.search(SearchRequest(requestID: 1, text: "cat", kind: .all, semantic: true, limit: 20))
        #expect(r.semantic == .notEnabled && r.hits.count == 1)
    }

    // Restart: the active model and its vectors are restored from the database (I5).
    @Test func restartRestoresActiveModelIndex() async throws {
        let home = try makeTempHome()
        let services = PlatformServices(ocr: FakeOCR(), translator: NoTranslator(), pasteboard: FakeWriter(),
                                        makeProvider: { m in var e = FakeEmbedder(); e.modelID = m.id; return e }, memoryGB: { 16 })
        do {
            let rt = try await Runtime.open(home: home, services: services, startWorker: false)
            try await rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
            _ = await rt.service.ingest(image(5), context: ctx)
            _ = await rt.worker.drain()
        }
        let rt2 = try await Runtime.open(home: home, services: services, startWorker: false, requireInstalledModel: false)
        #expect(await rt2.engine.activeModelID == "mobileclip-s0@1")
        #expect(await rt2.engine.activeIndex?.count() == 1)
    }
}

@Suite struct TwoSlotTests {
    var ctx: CaptureContext { CaptureContext(frontmostBundleID: nil, frontmostName: nil, excludedBundleIDs: [], lastSelfWriteChangeCount: nil) }
    func image(_ seed: UInt8) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: 1, types: ["public.png"], image: CapturedImage(data: pngBytes(seed: seed), uti: "public.png", width: 1, height: 1))
    }
    var services: PlatformServices {
        PlatformServices(ocr: FakeOCR(), translator: NoTranslator(), pasteboard: FakeWriter(),
                         makeProvider: { m in var e = FakeEmbedder(); e.modelID = m.id; e.dimension = m.dim; return e }, memoryGB: { 16 })
    }

    // AC19.4 — image and text models are independent slots; both restore after restart (I5).
    @Test func imageAndTextModelsCoexist() async throws {
        let home = try makeTempHome()
        do {
            let rt = try await Runtime.open(home: home, services: services, startWorker: false)
            try await rt.service.activateModel(id: "siglip2-base@1", requireInstalled: false)
            try await rt.service.activateModel(id: "multilingual-e5-small@1", requireInstalled: false)
            _ = await rt.service.ingest(image(1), context: ctx)
            _ = await rt.service.ingest(textSnapshot("明天下午三点开会"), context: ctx)
            _ = await rt.service.ingest(textSnapshot("https://example.com"), context: ctx)   // url: not text-embedded
            let report = await rt.worker.drain()
            #expect(report.completed == 3 && report.failed == 0)   // vision + image embed + text embed
            #expect(try await rt.db.semanticCoverage(modelID: "siglip2-base@1").indexed == 1)
            #expect(try await rt.db.semanticCoverage(modelID: "multilingual-e5-small@1", kinds: [.text, .rich]) == SemanticCoverage(indexed: 1, images: 1, pending: 0, failed: 0))
            let r = await rt.service.search(SearchRequest(requestID: 1, text: "meeting", kind: .all, semantic: true, limit: 20))
            #expect(r.hits.count == 2)                     // fake vectors: image + text both match semantically
            #expect(r.hits.allSatisfy { $0.sources == [.semantic] })
            let textOnly = await rt.service.search(SearchRequest(requestID: 2, text: "meeting", kind: .text, semantic: true, limit: 20))
            #expect(textOnly.hits.count == 1)
            try await rt.service.deactivateModel(slot: .image)
            #expect(await rt.service.activeModelManifest(slot: .text)?.id == "multilingual-e5-small@1")
            try await rt.service.activateModel(id: "siglip2-base@1", requireInstalled: false)
        }
        let rt2 = try await Runtime.open(home: home, services: services, startWorker: false, requireInstalledModel: false)
        #expect(await rt2.engine.activeModelID == "siglip2-base@1")
        #expect(await rt2.textEngine.activeModelID == "multilingual-e5-small@1")
        #expect(await rt2.textEngine.activeIndex?.count() == 1)
    }

    @Test func recommendationPerSlot() throws {
        let c = try ModelCatalog.builtin()
        #expect(c.recommended(memoryGB: 32, slot: .image)?.id == "siglip2-base@1")
        #expect(c.recommended(memoryGB: 4, slot: .image)?.id == "mobileclip-s0@1")
        #expect(c.recommended(memoryGB: 32, slot: .text)?.id == "multilingual-e5-small@1")
    }
}
