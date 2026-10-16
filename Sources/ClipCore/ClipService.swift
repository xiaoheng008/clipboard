import Foundation

/// Writes an item back to the system pasteboard (implemented in ClipPlatform).
/// Must include `SelfWriteMarker.type`; returns the pasteboard change count after writing.
public protocol PasteboardWriting: Sendable {
    func write(text: String?, representations: [Representation], imageFile: URL?) throws -> Int
}

/// Platform capabilities injected into the core.
public struct PlatformServices: Sendable {
    public var ocr: OCRProvider?
    public var translator: QueryTranslator
    public var pasteboard: PasteboardWriting
    public var makeProvider: @Sendable (ModelManifest) async throws -> EmbeddingProvider
    public var memoryGB: @Sendable () -> Int

    public init(ocr: OCRProvider?, translator: QueryTranslator, pasteboard: PasteboardWriting,
                makeProvider: @escaping @Sendable (ModelManifest) async throws -> EmbeddingProvider,
                memoryGB: @escaping @Sendable () -> Int) {
        self.ocr = ocr; self.translator = translator; self.pasteboard = pasteboard
        self.makeProvider = makeProvider; self.memoryGB = memoryGB
    }
}

public enum IngestOutcome: Sendable, Equatable {
    case stored(id: Int64, isNew: Bool)
    case skipped(SkipReason)
    case failed(String)
}

public enum ClipEvent: Sendable, Equatable {
    case itemsChanged          // ingest / touch / pin / delete / clear
    case indexProgress         // a job finished
    case modelChanged(String?)
}

public struct SearchRequest: Sendable, Equatable {
    public var requestID: UInt64
    public var text: String
    public var kind: KindFilter
    public var semantic: Bool
    public var limit: Int
    /// Skip the relative filter (CLI calibration, iron law 25).
    public var rawSemantic = false
    public init(requestID: UInt64, text: String, kind: KindFilter, semantic: Bool, limit: Int, rawSemantic: Bool = false) {
        self.requestID = requestID; self.text = text; self.kind = kind; self.semantic = semantic; self.limit = limit; self.rawSemantic = rawSemantic
    }
}

public struct SearchResponse: Sendable, Equatable {
    public var requestID: UInt64
    public var hits: [Hit]
    public var semantic: SemanticStatus
    public var untranslatedCJK: Bool
    public var error: String?
    public var elapsedMs: Double
}

public enum ServiceError: Error, CustomStringConvertible {
    case unknownModel(String), modelNotInstalled(String), unsupportedFamily(String), notFound(Int64)
    public var description: String {
        switch self {
        case .unknownModel(let m): "Unknown model \(m)"
        case .modelNotInstalled(let m): "Model \(m) is not installed (run --model install \(m))"
        case .unsupportedFamily(let f): "Unsupported model family \(f)"
        case .notFound(let id): "Item \(id) not found"
        }
    }
}

public enum SettingKey {
    public static let activeModel = "active_model"
    public static let activeTextModel = "active_text_model"
    public static let hotkey = "hotkey"
    public static let excludedApps = "excluded_apps"
    public static let semanticThreshold = "semantic_threshold"
}

/// The business façade. UI and CLI go through here; nothing else mutates storage.
public actor ClipService {
    let db: Database
    let reads: ReadStore
    let blobs: BlobStore
    let engine: SemanticEngine        // image slot
    let textEngine: SemanticEngine    // text slot (FR19)
    let worker: IndexWorker
    let services: PlatformServices
    public nonisolated let catalog: ModelCatalog

    private var lastSelfWriteChangeCount: Int?
    private var excluded: Set<String> = []
    private var skips: [SkipReason: Int] = [:]
    private var lastCaptureAt: Date?
    private var changeHandler: (@Sendable (ClipEvent) -> Void)?
    private var active: [ModelSlot: ModelManifest] = [:]
    public private(set) var activationError: String?
    private var activeModel: ModelManifest? { active[.image] }

    init(db: Database, reads: ReadStore, blobs: BlobStore, engine: SemanticEngine, textEngine: SemanticEngine, worker: IndexWorker,
         services: PlatformServices, catalog: ModelCatalog) {
        self.db = db; self.reads = reads; self.blobs = blobs; self.engine = engine; self.textEngine = textEngine; self.worker = worker
        self.services = services; self.catalog = catalog
    }

    static let textEmbeddedKinds: [ItemKind] = [.text, .rich]
    static func kinds(for slot: ModelSlot) -> [ItemKind] { slot == .image ? [.image] : textEmbeddedKinds }
    func engine(_ slot: ModelSlot) -> SemanticEngine { slot == .image ? engine : textEngine }

    func loadSettings() async {
        if let json = try? await db.setting(SettingKey.excludedApps), let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
            excluded = Set(arr)
        }
    }

    public func setChangeHandler(_ h: (@Sendable (ClipEvent) -> Void)?) { changeHandler = h }
    private func emit(_ e: ClipEvent) { changeHandler?(e) }

    // MARK: Capture

    public func captureContext(frontmost: SourceApp?) -> CaptureContext {
        CaptureContext(frontmostBundleID: frontmost?.bundleID, frontmostName: frontmost?.name,
                       excludedBundleIDs: excluded, lastSelfWriteChangeCount: lastSelfWriteChangeCount)
    }

    /// Type-only decision made *before* the watcher reads content (I7).
    public func preflight(types: [String], changeCount: Int, frontmost: SourceApp?) -> Preflight {
        let p = CaptureDecision.preflight(types: types, changeCount: changeCount, context: captureContext(frontmost: frontmost))
        if case .skip(let r) = p { recordSkip(r) }
        return p
    }

    public func recordSkip(_ r: SkipReason) { skips[r, default: 0] += 1 }
    public func skipCounts() -> [SkipReason: Int] { skips }
    public func lastCapture() -> Date? { lastCaptureAt }

    public func ingest(_ snapshot: PasteboardSnapshot, context: CaptureContext) async -> IngestOutcome {
        if case .skip(let r) = CaptureDecision.preflight(types: snapshot.types, changeCount: snapshot.changeCount, context: context) {
            recordSkip(r); return .skipped(r)
        }
        guard case .record(let draft) = CaptureDecision.classify(snapshot) else {
            if case .skip(let r) = CaptureDecision.classify(snapshot) { recordSkip(r); return .skipped(r) }
            return .skipped(.unsupported)
        }
        do {
            var blobHash: String?
            var jobs: [JobSpec] = []
            if let image = draft.image {
                blobHash = try blobs.put(image.data)            // file before transaction (I2)
                jobs.append(.vision)
                if let m = active[.image] { jobs.append(.embed(m.id)) }
            } else if Self.textEmbeddedKinds.contains(draft.kind), let m = active[.text] {
                jobs.append(.embed(m.id))
            }
            let source = SourceApp(bundleID: context.frontmostBundleID, name: context.frontmostName)
            let r = try await db.ingest(draft, blobHash: blobHash, source: source, jobs: jobs)
            lastCaptureAt = Date()
            Log.shared.event("capture.stored", ["id": .int(r.id), "kind": .label(draft.kind.rawValue), "new": .bool(r.isNew), "bytes": .int(Int64(draft.byteSize))])
            emit(.itemsChanged)
            if !jobs.isEmpty && r.isNew { await worker.wake() }
            return .stored(id: r.id, isNew: r.isNew)
        } catch {
            recordSkip(.writeFailed)
            Log.shared.event("capture.write_failed", ["kind": .label(draft.kind.rawValue), "error": .error(error)])
            return .failed(String(describing: error))
        }
    }

    // MARK: Item actions

    /// Q3: copy only (no simulated ⌘V). Touches the item; the resulting pasteboard change is ignored.
    public func copyBack(id: Int64) async throws {
        guard let item = try await db.item(id: id) else { throw ServiceError.notFound(id) }
        let reps = try await db.representations(id: id)
        let imageURL = item.summary.blobHash.map(blobs.url(for:))
        let cc = try services.pasteboard.write(text: item.text, representations: reps, imageFile: imageURL)
        lastSelfWriteChangeCount = cc
        try await db.touch(id: id)
        Log.shared.event("item.copied", ["id": .int(id)])
        emit(.itemsChanged)
    }

    public func setPinned(id: Int64, _ on: Bool) async throws {
        try await db.setPinned(id: id, on)
        emit(.itemsChanged)
    }

    public func delete(id: Int64) async throws {
        let freed = try await db.delete(id: id)
        for h in freed { try? blobs.delete(h) }           // failure leaves an orphan for --gc
        await engine.activeIndex?.remove(ids: [id])
        await textEngine.activeIndex?.remove(ids: [id])
        Log.shared.event("item.deleted", ["id": .int(id)])
        emit(.itemsChanged)
    }

    /// Q4: everything, pinned included. Caller is responsible for the confirmation step.
    public func clearAll() async throws {
        let freed = try await db.clearAll()
        for h in freed { try? blobs.delete(h) }
        if let idx = await engine.activeIndex { await idx.replaceAll([]) }
        if let idx = await textEngine.activeIndex { await idx.replaceAll([]) }
        Log.shared.event("items.cleared", ["blobs": .int(Int64(freed.count))])
        emit(.itemsChanged)
    }

    public func setExcludedApps(_ ids: [String]) async throws {
        let json = String(data: try JSONEncoder().encode(ids.sorted()), encoding: .utf8)!
        try await db.setSetting(SettingKey.excludedApps, json)
        excluded = Set(ids)
    }

    public func excludedApps() -> [String] { excluded.sorted() }

    // MARK: Reads

    public func page(after cursor: PageCursor?, kind: KindFilter, limit: Int) async throws -> [ItemSummary] {
        try await reads.page(after: cursor, kind: kind, limit: limit)
    }

    public func detail(id: Int64) async throws -> ItemDetail? { try await db.item(id: id) }

    public func coverage(modelID: String) async throws -> SemanticCoverage {
        let slot = catalog.model(id: modelID)?.slot ?? .image
        return try await db.semanticCoverage(modelID: modelID, kinds: Self.kinds(for: slot))
    }
    public func counts() async throws -> StoreCounts { try await db.counts() }
    public func embeddingCounts() async throws -> [String: Int] { try await db.embeddingCounts() }
    public nonisolated var home: AppHome { db.home }
    public nonisolated func blobURL(_ hash: String) -> URL { blobs.url(for: hash) }

    public func search(_ req: SearchRequest) async -> SearchResponse {
        let started = Date()
        let plan = QueryPlanner.plan(req.text)
        var textHits: [TextHit] = []
        var searchError: String?
        do { textHits = try await reads.search(plan, kind: req.kind, limit: req.limit) }
        catch { searchError = String(describing: error) }

        // Two semantic routes: image slot (kind all/image) and text slot (kind all/text).
        var status: SemanticStatus = .notEnabled
        var untranslated = false
        var semanticHits: [SemanticHit] = []
        if req.semantic && !plan.terms.isEmpty {
            for slot in ModelSlot.allCases {
                let wanted = slot == .image ? (req.kind == .all || req.kind == .image) : (req.kind == .all || req.kind == .text)
                guard wanted, let manifest = active[slot] else { continue }
                let r = await engine(slot).search(req.text, k: max(req.limit, 50))
                if slot == .image || status == .notEnabled { status = r.status; untranslated = r.untranslatedCJK }
                let kept = req.rawSemantic ? r.hits : SemanticFilter.apply(r.hits, floor: manifest.floor, margin: manifest.margin)
                if !kept.isEmpty, let summaries = try? await reads.summaries(ids: kept.map(\.id)) {
                    semanticHits += kept.compactMap { s in summaries[s.id].map { SemanticHit(item: $0, score: s.score) } }
                }
            }
        } else if !active.isEmpty {
            status = .ready(translated: nil)
        }
        // Each route is already judged relative to its own scale; order across routes by RRF rank.
        semanticHits.sort { $0.score > $1.score }
        let hits = RankFusion.fuse(text: textHits, semantic: semanticHits, threshold: -.infinity, limit: req.limit)
        return SearchResponse(requestID: req.requestID, hits: hits, semantic: status, untranslatedCJK: untranslated,
                              error: searchError, elapsedMs: Date().timeIntervalSince(started) * 1000)
    }

    // MARK: Models

    public func activeModelManifest(slot: ModelSlot = .image) -> ModelManifest? { active[slot] }

    static func settingKey(_ slot: ModelSlot) -> String { slot == .image ? SettingKey.activeModel : SettingKey.activeTextModel }

    /// Makes `id` the active model of its slot: provider → index loaded from DB → backfill queued.
    public func activateModel(id: String, requireInstalled: Bool = true) async throws {
        guard let m = catalog.model(id: id) else { throw ServiceError.unknownModel(id) }
        guard m.isSupportedFamily else { throw ServiceError.unsupportedFamily(m.family) }
        if requireInstalled && !ModelPaths.isInstalled(home: db.home, model: m) { throw ServiceError.modelNotInstalled(id) }
        let slot = m.slot
        let provider = try await services.makeProvider(m)
        let index: VectorIndex = slot == .text
            ? Int8VectorIndex(modelID: m.id, dimension: provider.dimension)       // Q11
            : FlatVectorIndex(modelID: m.id, dimension: provider.dimension)
        let loaded = try await db.loadEmbeddings(modelID: m.id, dim: provider.dimension)
        await index.replaceAll(loaded.entries)
        await engine(slot).activate(provider: provider, index: index)
        await worker.setEmbedding(slot: slot, provider, index: index)
        try await db.setSetting(Self.settingKey(slot), m.id)
        active[slot] = m
        activationError = nil
        let queued = try await db.enqueueMissingEmbeddings(modelID: m.id, kinds: Self.kinds(for: slot))
        Log.shared.event("model.activated", ["model": .label(m.id), "slot": .label(slot.rawValue), "vectors": .int(Int64(loaded.entries.count)),
                                             "skipped_dim": .int(Int64(loaded.skippedWrongDim)), "queued": .int(Int64(queued))])
        emit(.modelChanged(m.id))
        await worker.wake()
    }

    public func deactivateModel(slot: ModelSlot = .image) async throws {
        await engine(slot).activate(provider: nil, index: nil)
        await worker.setEmbedding(slot: slot, nil, index: nil)
        try await db.setSetting(Self.settingKey(slot), nil)
        active[slot] = nil
        emit(.modelChanged(nil))
    }

    func restoreActiveModels(requireInstalled: Bool) async {
        var errors: [String] = []
        for slot in ModelSlot.allCases {
            guard let id = try? await db.setting(Self.settingKey(slot)) else { continue }
            do { try await activateModel(id: id, requireInstalled: requireInstalled) }
            catch {
                errors.append("\(slot.rawValue): \(error)")
                Log.shared.event("model.restore_failed", ["model": .label(id), "error": .error(error)])
            }
        }
        activationError = errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    public func recommendedModel(slot: ModelSlot = .image) -> ModelManifest? { catalog.recommended(memoryGB: services.memoryGB(), slot: slot) }

    func notifyIndexProgress() { emit(.indexProgress) }
}
/// Everything the app or CLI needs, wired together. Startup performs recovery (sync-recovery §8).
public struct Runtime: Sendable {
    public let home: AppHome
    public let db: Database
    public let reads: ReadStore
    public let blobs: BlobStore
    public let engine: SemanticEngine
    public let textEngine: SemanticEngine
    public let worker: IndexWorker
    public let service: ClipService
    public let services: PlatformServices

    public static func open(home: AppHome, services: PlatformServices,
                            clock: @escaping @Sendable () -> Int64 = Database.systemClock,
                            startWorker: Bool = true, requireInstalledModel: Bool = true) async throws -> Runtime {
        Log.shared.configure(directory: home.logsURL)
        home.cleanTmp()
        let db = try Database(home: home, clock: clock)
        let reads = try ReadStore(home: home)
        let blobs = BlobStore(home: home)
        let engine = SemanticEngine(translator: services.translator)
        // Text models are multilingual: no translation step.
        let textEngine = SemanticEngine(translator: NoTranslator())
        let worker = IndexWorker(db: db, blobs: blobs, ocr: services.ocr)
        let (catalog, customError) = ModelCatalog.load(home: home)
        if let customError { Log.shared.event("models.custom_invalid", ["error": .label(customError)]) }
        let service = ClipService(db: db, reads: reads, blobs: blobs, engine: engine, textEngine: textEngine, worker: worker, services: services, catalog: catalog)
        await service.loadSettings()
        await worker.setProgressHandler { [service] in Task { await service.notifyIndexProgress() } }
        await service.restoreActiveModels(requireInstalled: requireInstalledModel)
        let rt = Runtime(home: home, db: db, reads: reads, blobs: blobs, engine: engine, textEngine: textEngine, worker: worker, service: service, services: services)
        if startWorker {
            Task.detached(priority: .utility) { await worker.runLoop() }
        }
        Log.shared.event("runtime.opened", ["version": .label(AppVersion.marketing), "worker": .bool(startWorker)])
        return rt
    }
}
