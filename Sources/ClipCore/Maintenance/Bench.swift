import Foundation

/// Synthetic load test for the Phase 1 budgets (A3/A4/A5). Always runs in its own home directory.
public enum Bench {
    public struct Result: Sendable {
        public var lines: [String] = []
        public var budgetsMet = true
    }

    static let english = ["clipboard", "history", "search", "invoice", "meeting", "project", "deploy", "server", "error", "report",
                          "password", "design", "budget", "release", "customer", "schedule", "database", "network", "swift", "python",
                          "function", "return", "config", "token", "upload", "picture", "screenshot", "address", "contract", "summary"]
    static let chinese = Array("剪切板历史记录搜索发票会议项目部署服务器错误报告设计预算发布客户日程数据库网络函数配置上传图片截图地址合同摘要你好世界今天明天北京上海文档")

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }

    static func sentence(_ rng: inout RNG, serial: Int) -> String {
        var parts: [String] = []
        for _ in 0..<Int.random(in: 4...30, using: &rng) {
            if Bool.random(using: &rng) { parts.append(english.randomElement(using: &rng)!) }
            else { parts.append(String((0..<Int.random(in: 2...6, using: &rng)).map { _ in chinese.randomElement(using: &rng)! })) }
        }
        parts.append("#\(serial)")   // makes every item unique
        return parts.joined(separator: " ")
    }

    static func time(_ runs: Int, _ body: () async throws -> Void) async rethrows -> (p50: Double, p95: Double) {
        var ms: [Double] = []
        for _ in 0..<runs {
            let t = Date()
            try await body()
            ms.append(Date().timeIntervalSince(t) * 1000)
        }
        ms.sort()
        return (ms[ms.count / 2], ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))])
    }

    public static func run(home: AppHome, items: Int, images: Int, dim: Int, log: (String) -> Void) async throws -> Result {
        var r = Result()
        func out(_ s: String) { r.lines.append(s); log(s) }
        var rng = RNG(state: 42)
        let db = try Database(home: home)
        let started = Date()
        let batch = 10_000
        var inserted = 0
        while inserted < items {
            let n = min(batch, items - inserted)
            let drafts = (0..<n).compactMap { i in CaptureDecision.classify(PasteboardSnapshot(changeCount: 0, types: ["public.utf8-plain-text"], string: sentence(&rng, serial: inserted + i))).draft }
            _ = try await db.ingestBatch(drafts, source: SourceApp(bundleID: "bench", name: "bench"))
            inserted += n
            if inserted % 100_000 == 0 || inserted == items { log("  inserted \(inserted)/\(items) (\(Int(Date().timeIntervalSince(started)))s)") }
        }
        out(String(format: "insert: %d items in %.1fs (%.0f items/s)", items, Date().timeIntervalSince(started), Double(items) / Date().timeIntervalSince(started)))
        let dbBytes = (try? FileManager.default.attributesOfItem(atPath: home.databaseURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        out(String(format: "database size: %.1f MB", Double(dbBytes) / 1_048_576))

        let reads = try ReadStore(home: home)
        func check(_ name: String, _ budget: Double, _ t: (p50: Double, p95: Double), _ extra: String = "") {
            let ok = t.p95 <= budget
            if !ok { r.budgetsMet = false }
            out(String(format: "%@ p50=%.1fms p95=%.1fms budget=%.0fms %@ %@", name, t.p50, t.p95, budget, ok ? "PASS" : "FAIL", extra))
        }
        var hits = 0
        out("plan 'clipboard': " + ((try? await reads.explain(QueryPlanner.plan("clipboard"))) ?? "?"))
        check("page.first", 50, try await time(30) { hits = try await reads.page(after: nil, kind: .all, limit: 60).count }, "rows=\(hits)")
        for q in ["clipboard", "invoice report", "数据库", "剪切板历史", "#987654", "nonexistentterm"] {
            check("search.fts '\(q)'", 50, try await time(20) { hits = try await reads.search(QueryPlanner.plan(q), kind: .all, limit: 200).count }, "hits=\(hits)")
        }
        for q in ["发票", "图", "zz"] {
            check("search.like '\(q)'", 150, try await time(10) { hits = try await reads.search(QueryPlanner.plan(q), kind: .all, limit: 200).count }, "hits=\(hits)")
        }

        if images > 0 {
            let index = FlatVectorIndex(modelID: "bench@1", dimension: dim)
            var entries: [(id: Int64, vector: [Float16])] = []
            entries.reserveCapacity(images)
            for i in 0..<images {
                let v = VectorCodec.normalized((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })
                entries.append((Int64(i), v.map { Float16($0) }))
            }
            let t0 = Date()
            await index.replaceAll(entries)
            out(String(format: "vector.load: %d × %d in %.0fms (≈%.0f MB fp16)", images, dim, Date().timeIntervalSince(t0) * 1000, Double(images * dim * 2) / 1_048_576))
            let q = VectorCodec.normalized((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })
            check("vector.search k=100", 30, await time(30) { _ = await index.search(q, k: 100) })
        }
        return r
    }
}
