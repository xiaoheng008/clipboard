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

@Suite struct SimilarImageTests {
    var ctx: CaptureContext { CaptureContext(frontmostBundleID: nil, frontmostName: nil, excludedBundleIDs: [], lastSelfWriteChangeCount: nil) }
    func image(_ seed: UInt8) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: 1, types: ["public.png"], image: CapturedImage(data: pngBytes(seed: seed), uti: "public.png", width: 1, height: 1))
    }

    // Image → similar images, using the stored vector of the active image model; never returns itself.
    @Test func similarToStoredImage() async throws {
        let services = PlatformServices(ocr: FakeOCR(), translator: NoTranslator(), pasteboard: FakeWriter(),
                                        makeProvider: { m in var e = FakeEmbedder(); e.modelID = m.id; e.dimension = m.dim; return e }, memoryGB: { 16 })
        let rt = try await Runtime.open(home: try makeTempHome(), services: services, startWorker: false)
        // No image model: explicit status, no results.
        guard case .stored(let a, _) = await rt.service.ingest(image(1), context: ctx) else { return }
        let none = await rt.service.similarImages(to: a, limit: 10)
        #expect(none.semantic == .notEnabled && none.hits.isEmpty)

        try await rt.service.activateModel(id: "vision-featureprint@1", requireInstalled: false)
        guard case .stored(let b, _) = await rt.service.ingest(image(2), context: ctx) else { return }
        _ = await rt.service.ingest(textSnapshot("not an image"), context: ctx)
        _ = await rt.worker.drain()
        let r = await rt.service.similarImages(to: a, limit: 10)
        #expect(r.hits.map(\.id) == [b])
        #expect(r.hits.first?.sources == [.semantic])
    }
}

@Suite struct ReviewP1Tests {
    var ctx: CaptureContext { CaptureContext(frontmostBundleID: nil, frontmostName: nil, excludedBundleIDs: [], lastSelfWriteChangeCount: nil) }

    final class CountingTranslator: QueryTranslator, @unchecked Sendable {
        let calls = Counter()
        func toEnglish(_ text: String) async -> String? { _ = calls.increment(); return "cat" }
    }

    func services(_ t: QueryTranslator = NoTranslator()) -> PlatformServices {
        PlatformServices(ocr: FakeOCR(), translator: t, pasteboard: FakeWriter(),
                         makeProvider: { m in var e = FakeEmbedder(); e.modelID = m.id; e.dimension = m.dim; return e }, memoryGB: { 16 })
    }

    // R5 — a multilingual image model gets the Chinese query as-is; English-only models are translated.
    @Test func multilingualModelSkipsTranslation() async throws {
        let t = CountingTranslator()
        let rt = try await Runtime.open(home: try makeTempHome(), services: services(t), startWorker: false)
        try await rt.service.activateModel(id: "siglip2-base@1", requireInstalled: false)
        let r = await rt.service.search(SearchRequest(requestID: 1, text: "大海", kind: .image, semantic: true, limit: 5))
        #expect(t.calls.value == 0 && !r.untranslatedCJK)
        try await rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
        _ = await rt.service.search(SearchRequest(requestID: 2, text: "大海", kind: .image, semantic: true, limit: 5))
        #expect(t.calls.value == 1)
    }

    // R8 — model changes and vectors written by another process (CLI) reach the running app on sync.
    @Test func appPicksUpChangesFromAnotherProcess() async throws {
        let home = try makeTempHome()
        let app = try await Runtime.open(home: home, services: services(), startWorker: false, requireInstalledModel: false)
        let image = PasteboardSnapshot(changeCount: 1, types: ["public.png"], image: CapturedImage(data: pngBytes(seed: 3), uti: "public.png", width: 1, height: 1))
        _ = await app.service.ingest(image, context: ctx)
        let cli = try await Runtime.open(home: home, services: services(), startWorker: false, sweepTmp: false)
        try await cli.service.activateModel(id: "siglip2-base@1", requireInstalled: false)
        _ = await cli.worker.drain()
        #expect(await app.service.activeModelManifest(slot: .image) == nil)
        await app.service.syncWithStore()
        #expect(await app.service.activeModelManifest(slot: .image)?.id == "siglip2-base@1")
        #expect(await app.engine.activeIndex?.count() == 1)
        try await cli.service.deactivateModel(slot: .image)
        await app.service.syncWithStore()
        #expect(await app.service.activeModelManifest(slot: .image) == nil)
    }

    // R9 — only captures emit `.captured`; the user's own delete / pin do not.
    @Test func capturedEventOnlyForCaptures() async throws {
        let rt = try await Runtime.open(home: try makeTempHome(), services: services(), startWorker: false)
        let events = EventLog()
        await rt.service.setChangeHandler { events.append($0) }
        guard case .stored(let id, _) = await rt.service.ingest(textSnapshot("one"), context: ctx) else { Issue.record("ingest"); return }
        try await rt.service.setPinned(id: id, true)
        try await rt.service.delete(id: id)
        #expect(events.all.filter { if case .captured = $0 { true } else { false } }.count == 1)
    }

    // R11 — the semantic status says why: not enabled / unavailable / not applicable to the filter.
    @Test func semanticStatusExplainsWhy() async throws {
        let rt = try await Runtime.open(home: try makeTempHome(), services: services(), startWorker: false)
        #expect(await rt.service.search(SearchRequest(requestID: 1, text: "x", kind: .all, semantic: true, limit: 5)).semantic == .notEnabled)
        try await rt.service.activateModel(id: "siglip2-base@1", requireInstalled: false)
        #expect(await rt.service.search(SearchRequest(requestID: 2, text: "x", kind: .file, semantic: true, limit: 5)).semantic == .notApplicable)
        #expect(await rt.service.search(SearchRequest(requestID: 3, text: "x", kind: .text, semantic: true, limit: 5)).semantic == .notApplicable)
        // Restore failure (model files gone): unavailable, not "not enabled".
        let failing = PlatformServices(ocr: nil, translator: NoTranslator(), pasteboard: FakeWriter(),
                                       makeProvider: { _ in throw ProviderError.modelUnavailable("gone") }, memoryGB: { 16 })
        let rt2 = try await Runtime.open(home: rt.home, services: failing, startWorker: false, requireInstalledModel: false, sweepTmp: false)
        guard case .unavailable = await rt2.service.search(SearchRequest(requestID: 4, text: "x", kind: .all, semantic: true, limit: 5)).semantic else {
            Issue.record("expected .unavailable"); return
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock(); private var events: [ClipEvent] = []
    func append(_ e: ClipEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [ClipEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
