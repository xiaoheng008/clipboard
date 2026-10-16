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
    case captured(Int64)       // a copy was recorded (new or moved to the top) — R9
    case cleared               // clear-all
    case itemsChanged          // pin / delete / copy-back (the panel updates itself for its own actions)
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

/// FR24 — effective relative-filter thresholds for a model (H5); isDefault = no user override.
public struct SemanticThresholds: Sendable, Equatable {
    public var floor: Float
    public var margin: Float
    public var isDefault: Bool
    public init(floor: Float, margin: Float, isDefault: Bool) { self.floor = floor; self.margin = margin; self.isDefault = isDefault }
}

/// FR23 — model slot state machine (3.4 §2). previous keeps serving search while a new model loads.
public enum ModelSlotState: Sendable, Equatable {
    case inactive
    case activating(target: String, previous: String?)
    case active(String)
    case failed(target: String, error: String, previous: String?)
}

public enum ServiceError: Error, CustomStringConvertible {
    case unknownModel(String), modelNotInstalled(String), unsupportedFamily(String), notFound(Int64)
    case slotBusy(String)
    case invalidThreshold(String)
    public var description: String {
        switch self {
        case .unknownModel(let m): "Unknown model \(m)"
        case .modelNotInstalled(let m): "Model \(m) is not installed (run --model install \(m))"
        case .unsupportedFamily(let f): "Unsupported model family \(f)"
        case .notFound(let id): "Item \(id) not found"
        case .slotBusy(let m): "正在启用 \(m)，请稍候"
        case .invalidThreshold(let s): "阈值无效：\(s)"
        }
    }
}

public enum SettingKey {
    public static let activeModel = "active_model"
    public static let activeTextModel = "active_text_model"
    public static let hotkey = "hotkey"
    public static let excludedApps = "excluded_apps"
    /// FR24 per-model overrides: "semantic_floor:<model id>", "semantic_margin:<model id>".
    public static let semanticFloorPrefix = "semantic_floor:"
    public static let semanticMarginPrefix = "semantic_margin:"
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
    /// R4: blobs written to disk whose item is not committed yet; deletes must not unlink them.
    private var pendingBlobs: [String: Int] = [:]
    func markBlobPending(_ h: String) { pendingBlobs[h, default: 0] += 1 }
    func unmarkBlobPending(_ h: String) {
        if let n = pendingBlobs[h], n > 1 { pendingBlobs[h] = n - 1 } else { pendingBlobs[h] = nil }
    }

    /// Unlinks freed blobs, re-checking right before each unlink (R4).
    private func unlinkFreed(_ hashes: [String]) async {
        for h in hashes where pendingBlobs[h] == nil {
            if (try? await db.isBlobReferenced(h)) == false, pendingBlobs[h] == nil { try? blobs.delete(h) }
        }
    }
    private var excluded: Set<String> = []
    private var skips: [SkipReason: Int] = [:]
    private var lastCaptureAt: Date?
    private var changeHandler: (@Sendable (ClipEvent) -> Void)?
    private var active: [ModelSlot: ModelManifest] = [:]
    public private(set) var activationError: String?
    private var slotErrors: [ModelSlot: String] = [:]
    private var slotStates: [ModelSlot: ModelSlotState] = [:]
    private var floorOverrides: [String: Float] = [:]
    private var marginOverrides: [String: Float] = [:]

    func loadThresholdOverrides() async {
        func parse(_ prefix: String) async -> [String: Float] {
            let raw = (try? await db.settings(prefix: prefix)) ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Float(v).map { (String(k.dropFirst(prefix.count)), $0) } })
        }
        floorOverrides = await parse(SettingKey.semanticFloorPrefix)
        marginOverrides = await parse(SettingKey.semanticMarginPrefix)
    }

    public func semanticThresholds(modelID: String) -> SemanticThresholds {
        let m = catalog.model(id: modelID)
        let f = floorOverrides[modelID], g = marginOverrides[modelID]
        return SemanticThresholds(floor: f ?? m?.floor ?? 0.1, margin: g ?? m?.margin ?? 0.06, isDefault: f == nil && g == nil)
    }

    /// nil resets that value to the manifest default. floor ∈ [-1, 1], margin ∈ [0, 1].
    public func setSemanticThresholds(modelID: String, floor: Float?, margin: Float?) async throws {
        guard catalog.model(id: modelID) != nil else { throw ServiceError.unknownModel(modelID) }
        if let floor, !(-1...1).contains(floor) { throw ServiceError.invalidThreshold("下限需在 -1 到 1 之间") }
        if let margin, !(0...1).contains(margin) { throw ServiceError.invalidThreshold("差距需在 0 到 1 之间") }
        try await db.setSetting(SettingKey.semanticFloorPrefix + modelID, floor.map { String($0) })
        try await db.setSetting(SettingKey.semanticMarginPrefix + modelID, margin.map { String($0) })
        floorOverrides[modelID] = floor
        marginOverrides[modelID] = margin
        Log.shared.event("model.thresholds", ["model": .label(modelID), "floor": .double(Double(floor ?? .nan)), "margin": .double(Double(margin ?? .nan))])
    }
    public func slotState(_ slot: ModelSlot) -> ModelSlotState { slotStates[slot] ?? .inactive }
    /// Whether activation requires installed model files (false only in tests).
    var requireInstalledModels = true
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
        await loadThresholdOverrides()
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
                let h = try blobs.put(image.data)               // file before transaction (I2)
                blobHash = h
                markBlobPending(h)
                jobs.append(.vision)
                if let m = active[.image] { jobs.append(.embed(m.id)) }
            } else if Self.textEmbeddedKinds.contains(draft.kind), let m = active[.text] {
                jobs.append(.embed(m.id))
            }
            let source = SourceApp(bundleID: context.frontmostBundleID, name: context.frontmostName)
            let r: IngestResult
            do { r = try await db.ingest(draft, blobHash: blobHash, source: source, jobs: jobs) }
            catch { if let blobHash { unmarkBlobPending(blobHash) }; throw error }
            if let blobHash { unmarkBlobPending(blobHash) }
            lastCaptureAt = Date()
            Log.shared.event("capture.stored", ["id": .int(r.id), "kind": .label(draft.kind.rawValue), "new": .bool(r.isNew), "bytes": .int(Int64(draft.byteSize))])
            emit(.captured(r.id))
            if !jobs.isEmpty && r.isNew { await worker.wake() }
            return .stored(id: r.id, isNew: r.isNew)
        } catch {
            recordSkip(.writeFailed)
            db.home.recordWriteFailure()
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
        await unlinkFreed(freed)                          // failure leaves an orphan for --gc
        await engine.activeIndex?.remove(ids: [id])
        await textEngine.activeIndex?.remove(ids: [id])
        Log.shared.event("item.deleted", ["id": .int(id)])
        emit(.itemsChanged)
    }

    /// Q4: everything, pinned included. Caller is responsible for the confirmation step.
    public func clearAll() async throws {
        let freed = try await db.clearAll()
        await unlinkFreed(freed)
        if let idx = await engine.activeIndex { await idx.replaceAll([]) }
        if let idx = await textEngine.activeIndex { await idx.replaceAll([]) }
        Log.shared.event("items.cleared", ["blobs": .int(Int64(freed.count))])
        emit(.cleared)
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
        let applicable = ModelSlot.allCases.filter { slot in
            slot == .image ? (req.kind == .all || req.kind == .image) : (req.kind == .all || req.kind == .text)
        }
        // R11: say why there is no semantic contribution.
        var status: SemanticStatus
        if applicable.contains(where: { active[$0] != nil }) { status = .ready(translated: nil) }
        else if let err = applicable.compactMap({ slotErrors[$0] }).first { status = .unavailable(err) }
        else if !active.isEmpty { status = .notApplicable }
        else { status = .notEnabled }
        var untranslated = false
        var semanticHits: [SemanticHit] = []
        var reported = false
        if req.semantic && !plan.terms.isEmpty {
            for slot in applicable {
                guard let manifest = active[slot] else { continue }
                let r = await engine(slot).search(req.text, k: max(req.limit, 50))
                if !reported || slot == .image { status = r.status; untranslated = r.untranslatedCJK; reported = true }
                let th = semanticThresholds(modelID: manifest.id)      // FR24: user overrides, else manifest defaults
                let kept = req.rawSemantic ? r.hits : SemanticFilter.apply(r.hits, floor: th.floor, margin: th.margin)
                if !kept.isEmpty, let summaries = try? await reads.summaries(ids: kept.map(\.id)) {
                    semanticHits += kept.compactMap { s in summaries[s.id].map { SemanticHit(item: $0, score: s.score) } }
                }
            }
        }
        // Each route is already judged relative to its own scale; order across routes by RRF rank.
        semanticHits.sort { $0.score > $1.score }
        let hits = RankFusion.fuse(text: textHits, semantic: semanticHits, threshold: -.infinity, limit: req.limit)
        return SearchResponse(requestID: req.requestID, hits: hits, semantic: status, untranslatedCJK: untranslated,
                              error: searchError, elapsedMs: Date().timeIntervalSince(started) * 1000)
    }

    // MARK: Similar images

    /// Images similar to a stored image (shown under the image in the detail pane). Uses its stored
    /// vector in the active image model's space; never returns the image itself.
    public func similarImages(to id: Int64, limit: Int) async -> SearchResponse {
        let started = Date()
        guard let m = active[.image] else { return respond(hits: [], .notEnabled, started) }
        guard let v = try? await db.embeddingVector(itemID: id, modelID: m.id) else {
            return respond(hits: [], .failed("这张图片还没有建立 \(m.displayName) 索引"), started)
        }
        let r = await engine.similar(to: v, k: limit + 1)
        let scores = r.hits.filter { $0.id != id }.prefix(limit)
        let summaries = (try? await reads.summaries(ids: scores.map(\.id))) ?? [:]
        let hits = scores.compactMap { s in summaries[s.id].map { Hit(item: $0, sources: [.semantic], score: Double(s.score), similarity: s.score) } }
        return respond(hits: hits, r.status, started)
    }

    private func respond(hits: [Hit], _ status: SemanticStatus, _ started: Date) -> SearchResponse {
        SearchResponse(requestID: 0, hits: hits, semantic: status, untranslatedCJK: false, error: nil,
                       elapsedMs: Date().timeIntervalSince(started) * 1000)
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
        // 3.4 §2: one activation per slot; the previous model keeps serving until the new one is loaded.
        if case .activating(let target, _) = slotState(slot) { throw ServiceError.slotBusy(target) }
        let previous = active[slot]?.id
        slotStates[slot] = .activating(target: m.id, previous: previous)
        emit(.modelChanged(previous))
        let provider: EmbeddingProvider
        let index: VectorIndex
        let loaded: (entries: [(id: Int64, vector: [Float16])], skippedWrongDim: Int)
        do {
            provider = try await services.makeProvider(m)
            index = slot == .text
                ? Int8VectorIndex(modelID: m.id, dimension: provider.dimension)       // Q11
                : FlatVectorIndex(modelID: m.id, dimension: provider.dimension)
            loaded = try await db.loadEmbeddings(modelID: m.id, dim: provider.dimension)
            await index.replaceAll(loaded.entries)
            // Persist first: if this fails nothing has been switched; if the process dies right after,
            // restart loads the new model from settings — either way memory and settings agree.
            try await db.setSetting(Self.settingKey(slot), m.id)
        } catch {
            slotStates[slot] = .failed(target: m.id, error: String(describing: error), previous: previous)
            emit(.modelChanged(previous))
            throw error
        }
        // Swap. The slot stays .activating until everything below is done, so no other activation can
        // interleave across these awaits (3.4 §2).
        await engine(slot).activate(provider: provider, index: index, translate: !m.isMultilingual)
        await worker.setEmbedding(slot: slot, provider, index: index)
        active[slot] = m
        slotStates[slot] = .active(m.id)
        slotErrors[slot] = nil
        activationError = slotErrors.isEmpty ? nil : slotErrors.values.sorted().joined(separator: "; ")
        let queued = try await db.enqueueMissingEmbeddings(modelID: m.id, kinds: Self.kinds(for: slot))
        Log.shared.event("model.activated", ["model": .label(m.id), "slot": .label(slot.rawValue), "vectors": .int(Int64(loaded.entries.count)),
                                             "skipped_dim": .int(Int64(loaded.skippedWrongDim)), "queued": .int(Int64(queued))])
        emit(.modelChanged(m.id))
        await worker.wake()
    }

    public func deactivateModel(slot: ModelSlot = .image) async throws {
        if case .activating(let target, _) = slotState(slot) { throw ServiceError.slotBusy(target) }
        slotStates[slot] = .inactive
        await engine(slot).activate(provider: nil, index: nil)
        await worker.setEmbedding(slot: slot, nil, index: nil)
        try await db.setSetting(Self.settingKey(slot), nil)
        active[slot] = nil
        slotErrors[slot] = nil
        activationError = slotErrors.isEmpty ? nil : slotErrors.values.sorted().joined(separator: "; ")
        emit(.modelChanged(nil))
    }

    func restoreActiveModels(requireInstalled: Bool) async {
        requireInstalledModels = requireInstalled
        for slot in ModelSlot.allCases {
            guard let id = try? await db.setting(Self.settingKey(slot)) else { continue }
            do { try await activateModel(id: id, requireInstalled: requireInstalled) }
            catch {
                slotErrors[slot] = "\(slot.rawValue): \(error)"
                Log.shared.event("model.restore_failed", ["model": .label(id), "error": .error(error)])
            }
        }
        activationError = slotErrors.isEmpty ? nil : slotErrors.values.sorted().joined(separator: "; ")
    }

    /// R8: another process (the CLI) may have changed the active models or written vectors.
    /// Called periodically by the app; cheap when nothing changed.
    public func syncWithStore() async {
        await loadThresholdOverrides()
        for slot in ModelSlot.allCases {
            let stored = try? await db.setting(Self.settingKey(slot))
            if stored != active[slot]?.id {
                if let id = stored { try? await activateModel(id: id, requireInstalled: requireInstalledModels) }
                else { try? await deactivateModel(slot: slot) }
                continue
            }
            guard let m = active[slot], let index = await engine(slot).activeIndex else { continue }
            let storedCount = (try? await db.semanticCoverage(modelID: m.id, kinds: Self.kinds(for: slot)).indexed) ?? 0
            if storedCount != (await index.count()), let loaded = try? await db.loadEmbeddings(modelID: m.id, dim: index.dimension) {
                await index.replaceAll(loaded.entries)
                Log.shared.event("model.index_reloaded", ["model": .label(m.id), "vectors": .int(Int64(loaded.entries.count))])
            }
        }
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
                            startWorker: Bool = true, requireInstalledModel: Bool = true, sweepTmp: Bool = true) async throws -> Runtime {
        Log.shared.configure(directory: home.logsURL)
        if sweepTmp { home.cleanTmp() }
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
