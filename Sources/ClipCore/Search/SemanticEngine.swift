import Foundation

/// Why semantic search did or did not contribute (C10: one "no results" display, many causes).
public enum SemanticStatus: Sendable, Equatable {
    case notEnabled                       // no model activated
    case textQueriesUnsupported           // active provider is image-only (e.g. Vision feature print)
    case ready(translated: String?)       // translated = the English query actually embedded, if any
    case failed(String)
    case unavailable(String)              // a model is configured but could not be loaded (E17)
    case notApplicable                    // models are enabled, but none covers the current kind filter
}

public struct SemanticResult: Sendable, Equatable {
    public var status: SemanticStatus
    public var hits: [SemanticScore]
    /// CJK query but no translator available: embedded as-is, quality likely poor (E18).
    public var untranslatedCJK = false
}

public struct SemanticScore: Sendable, Equatable {
    public let id: Int64
    public let score: Float
}

/// Text → vector → nearest images, using whichever backend is active.
public actor SemanticEngine {
    private var provider: EmbeddingProvider?
    private var index: VectorIndex?
    private let translator: QueryTranslator
    private var queryCache: [String: [Float]] = [:]
    private var translationCache: [String: String] = [:]
    /// False for multilingual models: they take the query as typed (R5).
    private var translates = true

    public init(translator: QueryTranslator) { self.translator = translator }

    public func activate(provider: EmbeddingProvider?, index: VectorIndex?, translate: Bool = true) {
        self.provider = provider
        self.index = index
        translates = translate
        queryCache.removeAll()
    }

    /// Swap in a freshly loaded index (vectors written by another process, R8).
    public func replaceIndex(_ index: VectorIndex) { self.index = index }

    public var activeModelID: String? { provider?.modelID }
    public var activeIndex: VectorIndex? { index }

    /// Image → similar images (any image model; vectors live in the same space as the index).
    public func similar(to vector: [Float], k: Int) async -> SemanticResult {
        guard let index else { return SemanticResult(status: .notEnabled, hits: []) }
        let hits = await index.search(VectorCodec.normalized(vector), k: k).map { SemanticScore(id: $0.id, score: $0.score) }
        return SemanticResult(status: .ready(translated: nil), hits: hits)
    }

    public func search(_ query: String, k: Int) async -> SemanticResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider, let index else { return SemanticResult(status: .notEnabled, hits: []) }
        guard provider.capabilities.text else { return SemanticResult(status: .textQueriesUnsupported, hits: []) }
        guard !q.isEmpty else { return SemanticResult(status: .ready(translated: nil), hits: []) }

        var text = q
        var translated: String?
        var untranslated = false
        if translates && QueryPlanner.containsCJK(q) {
            if let cached = translationCache[q] { translated = cached }
            else if let en = await translator.toEnglish(q), !en.isEmpty { translated = en; translationCache[q] = en }
            if let translated { text = translated } else { untranslated = true }
        }
        do {
            let vec: [Float]
            if let cached = queryCache[text] { vec = cached }
            else {
                vec = VectorCodec.normalized(try await provider.embed(text: text))
                if queryCache.count > 128 { queryCache.removeAll() }
                queryCache[text] = vec
            }
            let hits = await index.search(vec, k: k).map { SemanticScore(id: $0.id, score: $0.score) }
            return SemanticResult(status: .ready(translated: translated), hits: hits, untranslatedCJK: untranslated)
        } catch {
            return SemanticResult(status: .failed(String(describing: error)), hits: [])
        }
    }
}
