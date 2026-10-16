import Foundation
import Testing
@testable import ClipCore

/// Directory with downloaded HF repos (tokenizer.json files are too large to vendor as fixtures).
/// Expected ids come from the Python `tokenizers` library (tokenizers 0.22.2), see scripts/hf_tokenizer_reference.py.
let hfModels = ProcessInfo.processInfo.environment["CLIPVAULT_TEST_MODELS2"]

@Suite(.enabled(if: hfModels != nil, "set CLIPVAULT_TEST_MODELS2"))
struct GemmaTokenizerTests {
    static var url: URL { URL(fileURLWithPath: hfModels!).appendingPathComponent("FluidInference/siglip2-base-patch16-256-coreml/tokenizer.json") }

    @Test(arguments: [
        ("a photo of a cat", [235250, 2686, 576, 476, 4401, 1]),
        ("一只橘猫在睡觉", [88015, 239812, 236985, 235473, 101703, 1]),
        ("发票号码 2026", [235740, 237232, 100218, 235248, 235284, 235276, 235284, 235318, 1]),
        ("Hello, World!!", [17534, 235269, 2134, 2024, 1]),
        ("  多 空格  ", [139, 235626, 39174, 235991, 139, 1]),
        ("海边的日落 sunset 🌅", [235878, 70617, 235504, 236362, 22097, 235248, 245519, 1]),
        ("Ünïcödé — naïve café", [5268, 181773, 235397, 12823, 2062, 155245, 18688, 1]),
    ])
    func matchesReference(text: String, ids: [Int]) throws {
        let tok = try HFTokenizer.shared(url: Self.url)
        #expect(tok.encode(text.lowercased()) == ids)
    }

    @Test func padsToContext() throws {
        let tok = try HFTokenizer.shared(url: Self.url)
        let ids = tok.contextIDs("a photo of a cat", length: 64, padID: 0)
        #expect(ids.count == 64 && Array(ids.prefix(6)) == [235250, 2686, 576, 476, 4401, 1] && ids[6...].allSatisfy { $0 == 0 })
        let long = tok.contextIDs(String(repeating: "cat ", count: 100), length: 64, padID: 0)
        #expect(long.count == 64 && long.last == 1)
    }
}

@Suite(.enabled(if: hfModels != nil, "set CLIPVAULT_TEST_MODELS2"))
struct XLMRTokenizerTests {
    static var url: URL { URL(fileURLWithPath: hfModels!).appendingPathComponent("wolfram-pro/multilingual-e5-small-coreml/tokenizer.json") }

    @Test(arguments: [
        ("query: 会议时间", [0, 41, 1294, 12, 6, 15108, 5477, 2]),
        ("passage: Meeting moved to 3pm tomorrow", [0, 46692, 12, 163459, 109133, 47, 138, 26822, 127773, 2]),
        ("一只橘猫在睡觉", [0, 6, 79608, 145825, 35076, 213, 134753, 2]),
        ("Hello, World!!", [0, 35378, 4, 6661, 1146, 2]),
        ("  多 空格  ", [0, 6, 1288, 6, 5841, 6347, 6, 2]),
        ("ＡＢＣ１２３ 全角", [0, 47457, 48636, 6, 2476, 12514, 2]),
        ("繁體中文測試", [0, 6, 207449, 64770, 2]),
        ("emoji 🌅 ok", [0, 28, 121505, 6, 248588, 3664, 2]),
        ("naïve café — ½", [0, 24, 9392, 272, 26216, 292, 78660, 2]),
        ("a\tb\nc", nil as [Int]?),
    ] as [(String, [Int]?)])
    func matchesReference(text: String, ids: [Int]?) throws {
        let tok = try HFTokenizer.shared(url: Self.url)
        if let ids { #expect(tok.encode(text) == ids) }
        else { #expect(tok.encode(text) == tok.encode("a b c")) }
    }
}
