import Foundation

/// Offline retrieval evaluation for text models (scripts/eval/*.json). Runs in its own data
/// directory: imports the docs, activates the model, indexes, then ranks every doc for every query.
public enum TextEval {
    public struct Dataset: Codable, Sendable {
        public struct Doc: Codable, Sendable { public let id: String; public let text: String }
        public struct Query: Codable, Sendable { public let query: String; public let relevant: [String]; public let type: String }
        public let name: String
        public let docs: [Doc]
        public let queries: [Query]
    }

    public struct Result: Sendable {
        public var lines: [String] = []
        public var top1 = 0.0, top3 = 0.0, mrr = 0.0
    }

    public static func run(_ rt: Runtime, dataset: Dataset, modelID: String, log: (String) -> Void) async throws -> Result {
        let ctx = CaptureContext(frontmostBundleID: "eval", frontmostName: "eval", excludedBundleIDs: [], lastSelfWriteChangeCount: nil)
        var itemToDoc: [Int64: String] = [:]
        for d in dataset.docs {
            if case .stored(let id, _) = await rt.service.ingest(PasteboardSnapshot(changeCount: -1, types: ["public.utf8-plain-text"], string: d.text), context: ctx) {
                itemToDoc[id] = d.id
            }
        }
        let t0 = Date()
        try await rt.service.activateModel(id: modelID)
        let loadMs = Date().timeIntervalSince(t0) * 1000
        let t1 = Date()
        _ = await rt.worker.drain()
        let indexMs = Date().timeIntervalSince(t1) * 1000
        log(String(format: "model %@: load %.0f ms, index %d docs %.0f ms", modelID, loadMs, dataset.docs.count, indexMs))

        var r = Result()
        var perType: [String: (n: Int, top1: Int, top3: Int, rr: Double)] = [:]
        var latencies: [Double] = []
        var gaps: [Float] = []
        for q in dataset.queries {
            let tq = Date()
            let res = await rt.service.engine(.text).search(q.query, k: dataset.docs.count)
            latencies.append(Date().timeIntervalSince(tq) * 1000)
            let ranked = res.hits.compactMap { h in itemToDoc[h.id].map { ($0, h.score) } }
            let rank = (ranked.firstIndex { q.relevant.contains($0.0) } ?? ranked.count) + 1
            if let best = ranked.first(where: { q.relevant.contains($0.0) })?.1, let wrong = ranked.first(where: { !q.relevant.contains($0.0) })?.1 {
                gaps.append(best - wrong)
            }
            var p = perType[q.type, default: (0, 0, 0, 0)]
            p.n += 1; if rank == 1 { p.top1 += 1 }; if rank <= 3 { p.top3 += 1 }; p.rr += 1 / Double(rank)
            perType[q.type] = p
            if rank > 1 { r.lines.append("  miss [\(q.type)] \(q.query) → rank \(rank), top: \(ranked.first?.0 ?? "-")") }
        }
        let n = Double(dataset.queries.count)
        let all = perType.values.reduce((0, 0, 0.0)) { ($0.0 + $1.top1, $0.1 + $1.top3, $0.2 + $1.rr) }
        r.top1 = Double(all.0) / n; r.top3 = Double(all.1) / n; r.mrr = all.2 / n
        latencies.sort()
        r.lines.insert(String(format: "%@  top1 %.0f%%  top3 %.0f%%  MRR %.3f  | query p50 %.1f ms p95 %.1f ms | correct−best-wrong gap mean %.3f",
                              modelID, r.top1 * 100, r.top3 * 100, r.mrr, latencies[latencies.count / 2],
                              latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))],
                              gaps.isEmpty ? 0 : gaps.reduce(0, +) / Float(gaps.count)), at: 0)
        for (t, p) in perType.sorted(by: { $0.key < $1.key }) {
            r.lines.insert(String(format: "  %@: top1 %d/%d  top3 %d/%d  MRR %.3f", t, p.top1, p.n, p.top3, p.n, p.rr / Double(p.n)), at: 1)
        }
        return r
    }
}
