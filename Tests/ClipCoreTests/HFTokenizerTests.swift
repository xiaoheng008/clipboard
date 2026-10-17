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

/// Byte-level BPE (Granite, Qwen3) and Gemma-3 tokenizers for the text-model comparison.
/// Set CLIPVAULT_TEST_TOKENIZERS to a directory with granite.json, qwen.json, gemma.json.
let extraTokenizers = ProcessInfo.processInfo.environment["CLIPVAULT_TEST_TOKENIZERS"]

@Suite(.enabled(if: extraTokenizers != nil, "set CLIPVAULT_TEST_TOKENIZERS"))
struct ByteLevelTokenizerTests {
    static let cases = ["服务器返回500了", "The server returned HTTP 500!", "Hello, World!!  多 空格\n换行", "emoji 🌅 ok",
                        "it's naïve café — ½", "def f(x):\n    return x*2", "ABCdef Ünïcödé"]
    static let expected: [String: [[Int]]] = [
        "granite": [[179934, 97404, 32720, 3173, 4454, 179938], [179934, 931, 5918, 10322, 21441, 180, 3173, 0, 179938],
                    [179934, 12988, 11, 5826, 2561, 180, 50675, 145451, 13267, 177, 30281, 6441, 179938], [179934, 71368, 120326, 187, 4681, 179938],
                    [179934, 61195, 140448, 694, 29642, 2676, 180, 26441, 179938], [179934, 1265, 245, 3989, 1830, 231, 580, 1168, 9, 17, 179938],
                    [179934, 42658, 1265, 111467, 172710, 41867, 337, 179938]],
        "qwen": [[89047, 31526, 20, 15, 15, 34187, 151643], [785, 3538, 5927, 10130, 220, 20, 15, 15, 0, 151643],
                 [9707, 11, 4337, 2928, 220, 40666, 248, 10236, 102, 118, 33983, 198, 71134, 22243, 151643], [37523, 11162, 234, 227, 5394, 151643],
                 [275, 594, 94880, 586, 51950, 1959, 220, 26062, 151643], [750, 282, 2075, 982, 262, 470, 856, 9, 17, 151643],
                 [25411, 750, 30512, 77, 37572, 66, 2956, 128505, 151643]],
        "gemma": [[2, 38542, 29153, 236810, 236771, 236771, 237089, 1], [2, 818, 5941, 8323, 24644, 236743, 236810, 236771, 236771, 236888, 1],
                  [2, 9259, 236764, 4109, 4329, 138, 237309, 84853, 237829, 107, 238755, 237236, 1], [2, 67906, 236743, 246966, 7546, 1],
                  [2, 509, 236789, 236751, 120362, 33443, 2192, 47041, 1], [2, 2063, 517, 236769, 236781, 1473, 107, 140, 2060, 1123, 236829, 236778, 1],
                  [2, 31348, 2063, 15356, 236749, 238527, 236755, 55515, 236859, 1]],
    ]

    @Test(arguments: ["granite", "qwen", "gemma"])
    func matchesReference(name: String) throws {
        let tok = try HFTokenizer.shared(url: URL(fileURLWithPath: extraTokenizers!).appendingPathComponent("\(name).json"))
        for (text, ids) in zip(Self.cases, Self.expected[name]!) {
            #expect(tok.encode(text) == ids, "\(name): \(text)")
        }
    }

    @Test func leftPadding() throws {
        let tok = try HFTokenizer.shared(url: URL(fileURLWithPath: extraTokenizers!).appendingPathComponent("qwen.json"))
        let ids = tok.contextIDs("服务器返回500了", length: 10, padID: 151643, padLeft: true)
        #expect(ids == [151643, 151643, 151643, 89047, 31526, 20, 15, 15, 34187, 151643])
    }
}
