import Foundation
import Testing
@testable import ClipCore

@Suite struct QueryPlannerTests {
    // AC6.1 / AC6.2 — ≥3 chars → FTS phrase, shorter → LIKE.
    @Test func splitsLongAndShortTerms() {
        let p = QueryPlanner.plan("剪切 clipboard 板")
        #expect(p.ftsExpression == "\"clipboard\"")
        #expect(p.likePatterns == ["%剪切%", "%板%"])
        #expect(!p.isEmpty)
    }

    @Test func emptyQuery() {
        #expect(QueryPlanner.plan("   ").isEmpty)
    }

    // AC6.3 / E19 — FTS syntax characters are neutralised.
    @Test func quotesAreEscaped() {
        let p = QueryPlanner.plan("say \"hi\"* (x) :")
        #expect(p.ftsExpression == "\"say\" \"\"\"hi\"\"*\" \"(x)\"")
        #expect(p.likePatterns == ["%:%"])
    }

    // E20 — LIKE wildcards in user input are literal.
    @Test func likeWildcardsEscaped() {
        #expect(QueryPlanner.plan("5%").likePatterns == ["%5\\%%"])
        #expect(QueryPlanner.plan("a_").likePatterns == ["%a\\_%"])
    }

    @Test func detectsCJK() {
        #expect(QueryPlanner.containsCJK("猫 cat"))
        #expect(!QueryPlanner.containsCJK("cat dog"))
    }
}

@Suite struct ReadStoreSearchTests {
    func setup(_ texts: [String]) async throws -> (Database, ReadStore, [Int64]) {
        let clock = TestClock()
        let home = try makeTempHome()
        let db = try Database(home: home, clock: clock.fn)
        var ids: [Int64] = []
        for t in texts {
            ids.append(try await db.ingest(CaptureDecision.classify(textSnapshot(t)).draft!, blobHash: nil, source: nil, jobs: []).id)
            clock.advance(ms: 10)
        }
        return (db, try ReadStore(home: home), ids)
    }

    @Test func ftsFindsChineseAndEnglishSubstrings() async throws {
        let (_, rs, ids) = try await setup(["剪切板历史记录", "The Clipboard manager", "unrelated"])
        #expect(try await rs.search(QueryPlanner.plan("板历史"), kind: .all, limit: 10).map(\.item.id) == [ids[0]])
        // Trigram is case-insensitive; matches inside words.
        #expect(try await rs.search(QueryPlanner.plan("CLIPBOARD"), kind: .all, limit: 10).map(\.item.id) == [ids[1]])
        #expect(try await rs.search(QueryPlanner.plan("board"), kind: .all, limit: 10).map(\.item.id) == [ids[1]])
    }

    @Test func shortTermsUseLike() async throws {
        let (_, rs, ids) = try await setup(["剪切板", "复制粘贴", "100% sure"])
        #expect(try await rs.search(QueryPlanner.plan("切"), kind: .all, limit: 10).map(\.item.id) == [ids[0]])
        #expect(try await rs.search(QueryPlanner.plan("0%"), kind: .all, limit: 10).map(\.item.id) == [ids[2]])
        #expect(try await rs.search(QueryPlanner.plan("%"), kind: .all, limit: 10).map(\.item.id) == [ids[2]])
    }

    @Test func mixedTermsAreAnded() async throws {
        let (_, rs, ids) = try await setup(["剪切板 manager", "剪切板 other", "manager only"])
        #expect(try await rs.search(QueryPlanner.plan("切 manager"), kind: .all, limit: 10).map(\.item.id) == [ids[0]])
    }

    @Test func resultsAreRecentFirstAndKindFiltered() async throws {
        let (_, rs, ids) = try await setup(["note alpha", "https://alpha.example.com", "alpha again"])
        #expect(try await rs.search(QueryPlanner.plan("alpha"), kind: .all, limit: 10).map(\.item.id) == [ids[2], ids[1], ids[0]])
        #expect(try await rs.search(QueryPlanner.plan("alpha"), kind: .url, limit: 10).map(\.item.id) == [ids[1]])
    }

    @Test func ocrTextIsSearchableAndMarked() async throws {
        let (db, rs, ids) = try await setup(["plain"])
        try await db.applyOCRResult(itemID: ids[0], ocr: "发票号码 12345", labels: "document")
        let hits = try await rs.search(QueryPlanner.plan("发票号码"), kind: .all, limit: 10)
        #expect(hits.map(\.item.id) == [ids[0]])
        #expect(hits.first?.sources == [.ocr])
        let label = try await rs.search(QueryPlanner.plan("document"), kind: .all, limit: 10)
        #expect(label.first?.sources == [.ocr])
    }
}

@Suite struct RankFusionTests {
    func s(_ id: Int64, used: Int64 = 0) -> ItemSummary {
        ItemSummary(id: id, seq: id, kind: .image, preview: nil, blobHash: nil, byteSize: 0, width: nil, height: nil, sourceName: nil,
                    createdAt: 0, lastUsedAt: used, useCount: 1, pinned: false, ocrPreview: nil)
    }

    @Test func mergesSourcesAndRanks() {
        let text = [TextHit(item: s(1), sources: [.text]), TextHit(item: s(2), sources: [.ocr])]
        let sem = [SemanticHit(item: s(2), score: 0.30), SemanticHit(item: s(3), score: 0.25), SemanticHit(item: s(4), score: 0.05)]
        let out = RankFusion.fuse(text: text, semantic: sem, threshold: 0.18, limit: 10)
        // Item 2 appears in both lists → highest; item 4 is below threshold.
        #expect(out.map(\.item.id) == [2, 1, 3])
        #expect(out.first?.sources == [.ocr, .semantic])
    }

    @Test func limitApplies() {
        let text = (1...10).map { TextHit(item: s(Int64($0)), sources: [.text]) }
        #expect(RankFusion.fuse(text: text, semantic: [], threshold: 0.18, limit: 3).map(\.item.id) == [1, 2, 3])
    }
}

@Suite struct LatestOnlyTests {
    // AC6.4 — a response for an older request is discarded.
    @Test func staleResponsesAreDropped() {
        var gate = LatestOnly()
        let a = gate.next()
        let b = gate.next()
        #expect(!gate.accepts(a))
        #expect(gate.accepts(b))
        gate.invalidate()
        #expect(!gate.accepts(b))
    }
}

@Suite struct RecencyOrderingTests {
    // Touching an old item (copy again / copy back) moves it to the front of search results too.
    @Test func touchedItemLeadsSearchResults() async throws {
        let (db, rs, ids) = try await ReadStoreSearchTests().setup(["alpha one", "alpha two", "alpha three"])
        try await db.touch(id: ids[0])
        #expect(try await rs.search(QueryPlanner.plan("alpha"), kind: .all, limit: 10).map(\.item.id) == [ids[0], ids[2], ids[1]])
        #expect(try await rs.search(QueryPlanner.plan("一"), kind: .all, limit: 10).isEmpty)
        #expect(try await rs.page(after: nil, kind: .all, limit: 10).map(\.id) == [ids[0], ids[2], ids[1]])
    }

    @Test func pinnedMatchesComeFirst() async throws {
        let (db, rs, ids) = try await ReadStoreSearchTests().setup(["beta 1", "beta 2", "beta 3"])
        try await db.setPinned(id: ids[0], true)
        #expect(try await rs.search(QueryPlanner.plan("beta"), kind: .all, limit: 10).map(\.item.id) == [ids[0], ids[2], ids[1]])
        #expect(try await rs.search(QueryPlanner.plan("be"), kind: .all, limit: 2).map(\.item.id) == [ids[0], ids[2]])
    }

    // Short (1–2 char) queries use the n-gram index, which covers the first H9 characters of each item.
    @Test func shortQueriesUseNgramIndexWithinPrefix() async throws {
        let long = String(repeating: "x", count: 3000) + " 尾巴"
        let (_, rs, ids) = try await ReadStoreSearchTests().setup(["头部 发票", long, "a_b 100%"])
        #expect(try await rs.search(QueryPlanner.plan("发票"), kind: .all, limit: 10).map(\.item.id) == [ids[0]])
        #expect(try await rs.search(QueryPlanner.plan("尾巴"), kind: .all, limit: 10).isEmpty)        // beyond the prefix (documented H9)
        #expect(try await rs.search(QueryPlanner.plan("尾巴 xxx"), kind: .all, limit: 10).map(\.item.id) == [ids[1]])  // a long term drives FTS; short verified by LIKE
        #expect(try await rs.search(QueryPlanner.plan("A_"), kind: .all, limit: 10).map(\.item.id) == [ids[2]])
    }
}

@Suite struct LinkDetectorTests {
    // FR21 — links in item text are found; only safe schemes are clickable.
    @Test func findsWebAndMailLinks() {
        let text = "文档在 https://github.com/xiaoheng008/clipboard ，有问题发 me@example.com 或看 http://例子.中国/路径?q=1"
        let links = LinkDetector.links(in: text)
        #expect(links.map(\.url.absoluteString).contains("https://github.com/xiaoheng008/clipboard"))
        #expect(links.contains { $0.url.scheme == "mailto" })
        #expect(links.contains { $0.url.scheme == "http" })
        for l in links { #expect(String(text[l.range]).isEmpty == false) }
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "vscode://open?x", "ssh://host", "x-apple.systempreferences:com.apple"])
    func rejectsUnsafeSchemes(raw: String) {
        #expect(LinkDetector.safeURL(raw) == nil)
        #expect(LinkDetector.links(in: "go \(raw) now").isEmpty)
    }

    @Test func urlItemIsOpenable() {
        #expect(LinkDetector.safeURL(" https://example.com/a?b=1 ")?.absoluteString == "https://example.com/a?b=1")
        #expect(LinkDetector.safeURL("not a url") == nil)
    }
}

@Suite struct FileItemPathsTests {
    // FR22 — file items reveal their files in Finder; missing files are reported, not opened.
    @Test func splitsPathsAndChecksExistence() throws {
        let home = try makeTempHome()
        let present = home.tmpURL.appendingPathComponent("报告 final.pdf")
        try Data("x".utf8).write(to: present)
        let missing = home.tmpURL.appendingPathComponent("gone.txt").path
        let r = FileItemPaths.resolve(text: present.path + "\n" + missing + "\n\n")
        #expect(r.existing.map(\.path) == [present.path])
        #expect(r.missing == [missing])
    }

    @Test func ignoresNonAbsoluteLines() {
        let r = FileItemPaths.resolve(text: "relative/path\n~/notexpanded")
        #expect(r.existing.isEmpty && r.missing.isEmpty)
    }
}
