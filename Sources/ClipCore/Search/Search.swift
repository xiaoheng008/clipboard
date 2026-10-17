import Foundation

public enum MatchSource: String, Sendable, Hashable, CaseIterable {
    case text      // the item's own text
    case ocr       // OCR text or image labels
    case semantic  // vector similarity
}

public struct TextHit: Sendable, Equatable {
    public let item: ItemSummary
    public let sources: Set<MatchSource>
}

public struct SemanticHit: Sendable, Equatable {
    public let item: ItemSummary
    public let score: Float
}

public struct Hit: Sendable, Equatable, Identifiable {
    public let item: ItemSummary
    public let sources: Set<MatchSource>
    public let score: Double
    public let similarity: Float?
    public var id: Int64 { item.id }
}

/// Pure: query string → FTS expression + LIKE patterns.
public struct QueryPlan: Sendable, Equatable {
    public var ftsExpression: String?
    public var likePatterns: [String]
    /// N-gram index expression for the short terms (all ANDed).
    public var ngramExpression: String?
    /// Raw terms, used to attribute where a hit matched.
    public var terms: [String]
    public var isEmpty: Bool { ftsExpression == nil && likePatterns.isEmpty }
}

public enum QueryPlanner {
    /// The trigram tokenizer cannot match terms shorter than three characters.
    static let trigramMinimum = 3

    public static func plan(_ query: String) -> QueryPlan {
        let terms = KindMarker.strip(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var fts: [String] = []
        var like: [String] = []
        for t in terms {
            if t.count >= trigramMinimum {
                fts.append("\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            } else {
                like.append("%" + escapeLike(t) + "%")
            }
        }
        let shortTerms = terms.filter { $0.count < trigramMinimum }
        return QueryPlan(ftsExpression: fts.isEmpty ? nil : fts.joined(separator: " "), likePatterns: like,
                         ngramExpression: shortTerms.isEmpty ? nil : shortTerms.map { ngramToken($0.lowercased()) }.joined(separator: " "),
                         terms: terms)
    }

    static func escapeLike(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    public static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { v in
            (0x4E00...0x9FFF).contains(v.value) || (0x3400...0x4DBF).contains(v.value) ||
            (0x3040...0x30FF).contains(v.value) || (0xAC00...0xD7AF).contains(v.value)
        }
    }
}

/// Pure: reciprocal-rank fusion of text and semantic hits (3.2-api-design.md).
public enum RankFusion {
    public static let k = 60.0

    public static func fuse(text: [TextHit], semantic: [SemanticHit], threshold: Float, limit: Int) -> [Hit] {
        struct Acc { var item: ItemSummary; var sources: Set<MatchSource>; var score: Double; var sim: Float? }
        var acc: [Int64: Acc] = [:]
        var order: [Int64] = []
        for (rank, h) in text.enumerated() {
            if acc[h.item.id] == nil { order.append(h.item.id); acc[h.item.id] = Acc(item: h.item, sources: [], score: 0, sim: nil) }
            acc[h.item.id]!.sources.formUnion(h.sources)
            acc[h.item.id]!.score += 1 / (k + Double(rank + 1))
        }
        for (rank, h) in semantic.filter({ $0.score >= threshold }).enumerated() {
            if acc[h.item.id] == nil { order.append(h.item.id); acc[h.item.id] = Acc(item: h.item, sources: [], score: 0, sim: nil) }
            acc[h.item.id]!.sources.insert(.semantic)
            acc[h.item.id]!.score += 1 / (k + Double(rank + 1))
            acc[h.item.id]!.sim = h.score
        }
        let firstSeen = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.compactMap { acc[$0] }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.item.lastUsedAt != b.item.lastUsedAt { return a.item.lastUsedAt > b.item.lastUsedAt }
                return firstSeen[a.item.id]! < firstSeen[b.item.id]!
            }
            .prefix(limit)
            .map { Hit(item: $0.item, sources: $0.sources, score: $0.score, similarity: $0.sim) }
    }
}

/// Monotonic request ids; only the newest response is applied (stale-response rule, state-model 4.3).
public struct LatestOnly: Sendable {
    private var current: UInt64 = 0
    public init() {}
    public mutating func next() -> UInt64 { current &+= 1; return current }
    public func accepts(_ id: UInt64) -> Bool { id == current }
    /// e.g. panel closed: every in-flight response is now stale.
    public mutating func invalidate() { current &+= 1 }
}

/// H5 (revised): relative semantic judgement. Scores drift per query, so a fixed cut-off drops correct
/// answers; keep hits close to the best one, above a per-model floor. Pure for tests and calibration.
public enum SemanticFilter {
    public static func apply(_ hits: [SemanticScore], floor: Float, margin: Float) -> [SemanticScore] {
        guard let best = hits.map(\.score).max(), best >= floor else { return [] }
        return hits.filter { $0.score >= floor && $0.score >= best - margin }
    }
}
