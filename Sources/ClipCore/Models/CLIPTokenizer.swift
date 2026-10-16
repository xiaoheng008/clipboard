import Foundation

/// OpenAI CLIP byte-level BPE tokenizer (also used by MobileCLIP). Verified against
/// scripts/clip_tokenizer_reference.py (CLIPTokenizerTests).
public final class CLIPTokenizer: @unchecked Sendable {
    public static let startOfText = 49406
    public static let endOfText = 49407

    private let encoder: [String: Int]
    private let ranks: [String: Int]          // "a b" → merge rank
    private let byteToUnicode: [UInt8: Character]
    private let pattern: NSRegularExpression
    private var cache: [String: [Int]] = [:]
    private let lock = NSLock()

    public init(vocabURL: URL, mergesURL: URL) throws {
        let vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabURL))
        encoder = vocab
        let lines = try String(contentsOf: mergesURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        var r: [String: Int] = [:]
        var rank = 0
        for line in lines.dropFirst() {   // first line is "#version"
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            r["\(parts[0]) \(parts[1])"] = rank
            rank += 1
        }
        ranks = r
        byteToUnicode = Self.makeByteToUnicode()
        pattern = try NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive])
    }

    static func makeByteToUnicode() -> [UInt8: Character] {
        var bs: [Int] = Array(Int(UInt8(ascii: "!"))...Int(UInt8(ascii: "~"))) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        var out: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) { out[UInt8(b)] = Character(Unicode.Scalar(c)!) }
        return out
    }

    /// Token ids without start/end markers.
    public func encode(_ text: String) -> [Int] {
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let ns = cleaned as NSString
        var ids: [Int] = []
        for m in pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: m.range)
            let mapped = String(piece.utf8.map { byteToUnicode[$0]! })
            ids += bpeIDs(mapped)
        }
        return ids
    }

    /// `[SOT] + tokens + [EOT]`, truncated to `length` (EOT kept last) and zero-padded.
    public func contextTokens(_ text: String, length: Int) -> [Int32] {
        var ids = [Self.startOfText] + encode(text).prefix(length - 2) + [Self.endOfText]
        if ids.count < length { ids += [Int](repeating: 0, count: length - ids.count) }
        return ids.map(Int32.init)
    }

    private func bpeIDs(_ token: String) -> [Int] {
        lock.lock()
        if let hit = cache[token] { lock.unlock(); return hit }
        lock.unlock()
        var word = token.map(String.init)
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, i: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[word[i] + " " + word[i + 1]], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let b = best else { break }
            let a = word[b.i], c = word[b.i + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == a && word[i + 1] == c { merged.append(a + c); i += 2 }
                else { merged.append(word[i]); i += 1 }
            }
            word = merged
        }
        let ids = word.compactMap { encoder[$0] }
        lock.lock(); if cache.count > 4096 { cache.removeAll() }; cache[token] = ids; lock.unlock()
        return ids
    }
}
