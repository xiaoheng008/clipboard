import Foundation

// Extension boundary (3-api-design.md). Contract: signature changes must update every implementation
// and ProviderRegistry in ClipPlatform.

public struct EmbeddingCapabilities: Sendable, Equatable {
    public let image: Bool
    public let text: Bool
    public init(image: Bool, text: Bool) { self.image = image; self.text = text }
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case unreadableImage
    case modelUnavailable(String)
    case failed(String)
    public var description: String {
        switch self {
        case .unsupported(let s): "unsupported: \(s)"
        case .unreadableImage: "unreadable image"
        case .modelUnavailable(let s): "model unavailable: \(s)"
        case .failed(let s): s
        }
    }
}

/// Turns images (and optionally text) into L2-normalised vectors in a shared space.
public protocol EmbeddingProvider: Sendable {
    /// Includes a version, e.g. "mobileclip-s2@1". Different weights ⇒ different id.
    var modelID: String { get }
    var dimension: Int { get }
    var capabilities: EmbeddingCapabilities { get }
    func embed(imageAt url: URL) async throws -> [Float]
    func embed(text: String) async throws -> [Float]
}

public struct OCRResult: Sendable, Equatable {
    public var text: String
    public var labels: [String]
    public init(text: String, labels: [String]) { self.text = text; self.labels = labels }
}

/// OCR + coarse image labels.
public protocol OCRProvider: Sendable {
    func recognize(imageAt url: URL) async throws -> OCRResult
}

/// Translates a query into English for English-only embedding models. nil = unavailable (caller degrades).
public protocol QueryTranslator: Sendable {
    func toEnglish(_ text: String) async -> String?
}

public struct NoTranslator: QueryTranslator {
    public init() {}
    public func toEnglish(_ text: String) async -> String? { nil }
}

/// In-memory nearest-neighbour index for one model's vectors. A rebuildable cache of `embeddings`.
public protocol VectorIndex: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    func count() async -> Int
    func replaceAll(_ entries: [(id: Int64, vector: [Float16])]) async
    func upsert(id: Int64, vector: [Float]) async
    func remove(ids: [Int64]) async
    func search(_ query: [Float], k: Int) async -> [(id: Int64, score: Float)]
}
