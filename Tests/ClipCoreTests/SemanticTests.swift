import Foundation
import Testing
@testable import ClipCore

@Suite struct FlatVectorIndexTests {
    func randomUnit(_ dim: Int, _ rng: inout SystemRandomNumberGenerator) -> [Float] {
        VectorCodec.normalized((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })
    }

    // AC8.3 — top-K matches a naive implementation over fp16-rounded vectors.
    @Test func topKMatchesNaive() async {
        var rng = SystemRandomNumberGenerator()
        let dim = 64
        let index = FlatVectorIndex(modelID: "m@1", dimension: dim)
        var stored: [Int64: [Float]] = [:]
        var entries: [(id: Int64, vector: [Float16])] = []
        for id in 1...10_000 {
            let v = randomUnit(dim, &rng)
            let h = v.map { Float16($0) }
            entries.append((Int64(id), h))
            stored[Int64(id)] = h.map(Float.init)
        }
        await index.replaceAll(entries)
        #expect(await index.count() == 10_000)
        for _ in 0..<5 {
            let q = randomUnit(dim, &rng)
            let got = await index.search(q, k: 10)
            let naive = stored.map { (id: $0.key, score: zip($0.value, q).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
                .sorted { $0.score > $1.score }.prefix(10)
            #expect(got.map(\.id) == naive.map(\.id))
            for (a, b) in zip(got, naive) { #expect(abs(a.score - b.score) < 1e-3) }
        }
    }

    @Test func upsertReplacesAndRemoveDeletes() async {
        let index = FlatVectorIndex(modelID: "m@1", dimension: 2)
        await index.upsert(id: 1, vector: [1, 0])
        await index.upsert(id: 2, vector: [0, 1])
        await index.upsert(id: 1, vector: [0, 1])   // replace, not duplicate
        #expect(await index.count() == 2)
        await index.remove(ids: [2])
        let r = await index.search([0, 1], k: 5)
        #expect(r.map(\.id) == [1])
        #expect(abs(r[0].score - 1) < 1e-3)
        await index.remove(ids: [1, 99])
        #expect(await index.count() == 0)
        #expect(await index.search([0, 1], k: 5).isEmpty)
    }

    @Test func wrongDimensionIsIgnored() async {
        let index = FlatVectorIndex(modelID: "m@1", dimension: 3)
        await index.upsert(id: 1, vector: [1, 0])
        #expect(await index.count() == 0)
        #expect(await index.search([1, 0], k: 1).isEmpty)
    }
}

@Suite struct CLIPTokenizerTests {
    static let fixtures = repoRoot.appendingPathComponent("Tests/ClipCoreTests/Fixtures/clip-bpe")

    // Expected ids produced by scripts/clip_tokenizer_reference.py (independent Python implementation).
    @Test(arguments: [
        ("a photo of a cat", [320, 1125, 539, 320, 2368]),
        ("clipboard", [39712, 1972]),
        ("猫", [163, 234, 360]),
        ("Hello, World!!", [3306, 267, 1002, 748]),
        ("screenshot of VS Code   editor", [12646, 539, 1547, 3217, 7661]),
        ("it's 2026", [585, 568, 273, 271, 273, 277]),
        ("一只橘猫在睡觉", [19759, 222, 34517, 103, 162, 102, 246, 163, 234, 104, 37746, 101, 163, 251, 94, 164, 100, 487]),
    ])
    func matchesReference(text: String, ids: [Int]) throws {
        let tok = try CLIPTokenizer(vocabURL: Self.fixtures.appendingPathComponent("vocab.json"),
                                    mergesURL: Self.fixtures.appendingPathComponent("merges.txt"))
        #expect(tok.encode(text) == ids)
    }

    @Test func contextIsPaddedAndTruncated() throws {
        let tok = try CLIPTokenizer(vocabURL: Self.fixtures.appendingPathComponent("vocab.json"),
                                    mergesURL: Self.fixtures.appendingPathComponent("merges.txt"))
        let short = tok.contextTokens("a cat", length: 77)
        #expect(short.count == 77)
        #expect(Array(short.prefix(4)) == [49406, 320, 2368, 49407])
        #expect(short[4...].allSatisfy { $0 == 0 })
        let long = tok.contextTokens(String(repeating: "cat ", count: 200), length: 77)
        #expect(long.count == 77 && long.first == 49406 && long.last == 49407)
    }
}

@Suite struct ModelManifestTests {
    @Test func builtinCatalogDecodesAndIsComplete() throws {
        let catalog = try ModelCatalog.builtin()
        #expect(catalog.models.map(\.id) == ["mobileclip-s0@1", "mobileclip-s2@1", "mobileclip-blt@1", "siglip2-base@1", "multilingual-e5-small@1", "vision-featureprint@1"])
        #expect(catalog.model(id: "siglip2-base@1")?.files.count == 7)
        #expect(catalog.model(id: "multilingual-e5-small@1")?.slot == .text)
        for m in catalog.models where m.family == "coreml-clip" {
            #expect(m.files.count == 8, "\(m.id)")   // 2 packages × 3 files + vocab + merges
            #expect(m.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 && $0.url.hasPrefix("https://huggingface.co/") })
        }
    }

    // AC9.1 / H8
    // H8 (revised with Q9): SigLIP2 (bilingual) wherever it fits; MobileCLIP S0 below 8 GB.
    @Test(arguments: [(4, "mobileclip-s0@1"), (8, "siglip2-base@1"), (16, "siglip2-base@1"), (32, "siglip2-base@1"), (64, "siglip2-base@1")])
    func recommendation(memoryGB: Int, expected: String) throws {
        #expect(try ModelCatalog.builtin().recommended(memoryGB: memoryGB)?.id == expected)
    }

    @Test func customManifestsMergeAndOverride() throws {
        let custom = """
        {"models":[{"id":"my-clip@1","family":"coreml-clip","displayName":"Mine","tier":9,"dim":768,"imageSize":224,
          "contextLength":77,"minMemoryGB":64,"imageInput":"image","textInput":"text","output":"emb","tokenizer":"clip-bpe","files":[]},
          {"id":"weird@1","family":"unknown-family","displayName":"?","tier":0,"dim":1,"minMemoryGB":0,"files":[]}]}
        """
        let merged = try ModelCatalog.builtin().merging(customJSON: Data(custom.utf8))
        #expect(merged.model(id: "my-clip@1")?.dim == 768)
        #expect(merged.model(id: "weird@1")?.isSupportedFamily == false)
        #expect(merged.models.count == 8)
    }
}

@Suite struct SemanticEngineTests {
    struct UpperTranslator: QueryTranslator {
        let seen = Counter()
        func toEnglish(_ text: String) async -> String? { _ = seen.increment(); return "cat" }
    }

    @Test func statusWhenNoModel() async {
        let engine = SemanticEngine(translator: NoTranslator())
        let r = await engine.search("cat", k: 10)
        #expect(r.status == .notEnabled && r.hits.isEmpty)
    }

    @Test func searchesActiveIndexAndTranslatesCJK() async {
        let t = UpperTranslator()
        let engine = SemanticEngine(translator: t)
        let index = FlatVectorIndex(modelID: "fake@1", dimension: 4)
        await index.upsert(id: 7, vector: VectorCodec.normalized([1, 2, 3, 4]))
        await engine.activate(provider: FakeEmbedder(), index: index)
        let r = await engine.search("猫", k: 5)
        #expect(r.status == .ready(translated: "cat"))
        #expect(r.hits.map(\.id) == [7])
        #expect(t.seen.value == 1)
        // English query: no translation.
        _ = await engine.search("cat", k: 5)
        #expect(t.seen.value == 1)
    }

    @Test func imageOnlyProviderReportsUnsupported() async {
        struct ImageOnly: EmbeddingProvider {
            let modelID = "fp@1"; let dimension = 4
            let capabilities = EmbeddingCapabilities(image: true, text: false)
            func embed(imageAt url: URL) async throws -> [Float] { [1, 0, 0, 0] }
            func embed(text: String) async throws -> [Float] { throw ProviderError.unsupported("text") }
        }
        let engine = SemanticEngine(translator: NoTranslator())
        await engine.activate(provider: ImageOnly(), index: FlatVectorIndex(modelID: "fp@1", dimension: 4))
        #expect(await engine.search("cat", k: 5).status == .textQueriesUnsupported)
    }
}

@Suite struct SemanticFilterTests {
    func s(_ id: Int64, _ v: Float) -> SemanticScore { SemanticScore(id: id, score: v) }

    // AC19.5
    @Test func keepsHitsNearBestAboveFloor() {
        let hits = [s(3, 0.148), s(11, 0.130), s(12, 0.077), s(1, 0.048)]
        #expect(SemanticFilter.apply(hits, floor: 0.10, margin: 0.05).map(\.id) == [3, 11])
        #expect(SemanticFilter.apply(hits, floor: 0.20, margin: 0.05).isEmpty)        // nothing relevant enough
        #expect(SemanticFilter.apply([], floor: 0, margin: 1).isEmpty)
    }
}

@Suite struct Int8VectorIndexTests {
    // AC19.6 — top-K overlap with exact fp32 search ≥ 0.95.
    @Test func topKOverlapWithExact() async {
        var rng = SystemRandomNumberGenerator()
        let dim = 384
        let index = Int8VectorIndex(modelID: "t@1", dimension: dim)
        var exact: [Int64: [Float]] = [:]
        for id in 1...10_000 {
            let v = VectorCodec.normalized((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })
            exact[Int64(id)] = v
            await index.upsert(id: Int64(id), vector: v)
        }
        var overlap = 0.0
        for _ in 0..<10 {
            let q = VectorCodec.normalized((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })
            let got = Set(await index.search(q, k: 20).map(\.id))
            let truth = Set(exact.map { ($0.key, zip($0.value, q).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }.sorted { $0.1 > $1.1 }.prefix(20).map(\.0))
            overlap += Double(got.intersection(truth).count) / 20
        }
        #expect(overlap / 10 >= 0.95)
        await index.remove(ids: [1, 2])
        #expect(await index.count() == 9_998)
    }
}
