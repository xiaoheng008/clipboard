import Foundation

/// A subset of HuggingFace `tokenizer.json`, enough for the multilingual models we ship:
/// Gemma (SigLIP2: BPE + byte fallback) and XLM-R (multilingual-e5: Unigram + Metaspace).
/// Parity with the Python `tokenizers` library is pinned by HFTokenizerTests.
public final class HFTokenizer: @unchecked Sendable {
    public enum LoadError: Error, CustomStringConvertible {
        case unsupported(String)
        case malformed(String)
        public var description: String {
            switch self {
            case .unsupported(let s): "unsupported tokenizer.json component: \(s)"
            case .malformed(let s): "malformed tokenizer.json: \(s)"
            }
        }
    }

    enum Normalizer {
        case replace(String, String)
        case replaceRegex(NSRegularExpression, String)
        case nfkcWhitespace                  // approximation of SentencePiece "Precompiled" (nmt_nfkc)
        case nfkc
        case lowercase
        case prepend(String)
    }

    enum PreTokenizer {
        case splitMergedWithPrevious(String)
        case metaspace(String, prefix: Bool)
        case whitespaceSplit
    }

    enum Model {
        case bpe(vocab: [String: Int], ranks: [String: Int], byteFallback: Bool, unk: Int?)
        case unigram(pieces: [String: (id: Int, score: Double)], maxLength: Int, unk: Int, unkScore: Double)
    }

    private let normalizers: [Normalizer]
    private let preTokenizers: [PreTokenizer]
    private let model: Model
    private let prefixIDs: [Int]
    private let suffixIDs: [Int]
    private var cache: [String: [Int]] = [:]
    private let lock = NSLock()

    nonisolated(unsafe) private static var shared: [URL: HFTokenizer] = [:]
    private static let sharedLock = NSLock()

    /// Loading a 34 MB tokenizer.json takes ~1 s; share instances per file.
    public static func shared(url: URL) throws -> HFTokenizer {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let t = shared[url] { return t }
        let t = try HFTokenizer(url: url)
        shared[url] = t
        return t
    }

    public init(url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw LoadError.malformed("root")
        }
        normalizers = try Self.parseNormalizers(root["normalizer"])
        preTokenizers = try Self.parsePreTokenizers(root["pre_tokenizer"])
        guard let m = root["model"] as? [String: Any], let type = m["type"] as? String else { throw LoadError.malformed("model") }
        switch type {
        case "BPE":
            guard let vocab = m["vocab"] as? [String: Int], let merges = m["merges"] as? [Any] else { throw LoadError.malformed("BPE") }
            var ranks: [String: Int] = [:]
            ranks.reserveCapacity(merges.count)
            for (i, item) in merges.enumerated() {
                if let pair = item as? [String], pair.count == 2 { ranks[pair[0] + " " + pair[1]] = i }
                else if let s = item as? String { ranks[s] = i }
            }
            let unk = (m["unk_token"] as? String).flatMap { vocab[$0] }
            model = .bpe(vocab: vocab, ranks: ranks, byteFallback: m["byte_fallback"] as? Bool ?? false, unk: unk)
        case "Unigram":
            guard let vocab = m["vocab"] as? [[Any]] else { throw LoadError.malformed("Unigram") }
            var pieces: [String: (Int, Double)] = [:]
            pieces.reserveCapacity(vocab.count)
            var maxLen = 1
            var minScore = Double.infinity
            for (i, entry) in vocab.enumerated() {
                guard let piece = entry.first as? String, let score = (entry.last as? NSNumber)?.doubleValue else { continue }
                pieces[piece] = (i, score)
                maxLen = max(maxLen, piece.count)
                minScore = min(minScore, score)
            }
            model = .unigram(pieces: pieces, maxLength: maxLen, unk: m["unk_id"] as? Int ?? 0, unkScore: minScore - 10)
        default:
            throw LoadError.unsupported("model \(type)")
        }
        (prefixIDs, suffixIDs) = try Self.parsePost(root["post_processor"], root["added_tokens"])
    }

    // MARK: Parsing

    private static func parseNormalizers(_ any: Any?) throws -> [Normalizer] {
        guard let n = any as? [String: Any], let type = n["type"] as? String else { return [] }
        switch type {
        case "Sequence": return try (n["normalizers"] as? [Any] ?? []).flatMap { try parseNormalizers($0) }
        case "Replace":
            let pattern = n["pattern"] as? [String: Any]
            guard let content = n["content"] as? String else { throw LoadError.malformed("Replace") }
            if let literal = pattern?["String"] as? String { return [.replace(literal, content)] }
            if let regex = pattern?["Regex"] as? String { return [.replaceRegex(try NSRegularExpression(pattern: regex), content)] }
            throw LoadError.malformed("Replace pattern")
        case "Precompiled": return [.nfkcWhitespace]
        case "NFKC": return [.nfkc]
        case "Lowercase": return [.lowercase]
        case "Prepend": return [.prepend(n["prepend"] as? String ?? "")]
        default: throw LoadError.unsupported("normalizer \(type)")
        }
    }

    private static func parsePreTokenizers(_ any: Any?) throws -> [PreTokenizer] {
        guard let p = any as? [String: Any], let type = p["type"] as? String else { return [] }
        switch type {
        case "Sequence": return try (p["pretokenizers"] as? [Any] ?? []).flatMap { try parsePreTokenizers($0) }
        case "Split":
            guard let pattern = (p["pattern"] as? [String: Any])?["String"] as? String, p["behavior"] as? String == "MergedWithPrevious" else {
                throw LoadError.unsupported("Split variant")
            }
            return [.splitMergedWithPrevious(pattern)]
        case "Metaspace":
            let scheme = p["prepend_scheme"] as? String
            let prefix = scheme.map { $0 != "never" } ?? (p["add_prefix_space"] as? Bool ?? true)
            return [.metaspace(p["replacement"] as? String ?? "▁", prefix: prefix)]
        case "WhitespaceSplit": return [.whitespaceSplit]
        default: throw LoadError.unsupported("pre_tokenizer \(type)")
        }
    }

    private static func parsePost(_ any: Any?, _ added: Any?) throws -> ([Int], [Int]) {
        guard let p = any as? [String: Any] else { return ([], []) }
        guard p["type"] as? String == "TemplateProcessing", let single = p["single"] as? [[String: Any]] else {
            throw LoadError.unsupported("post_processor \(p["type"] ?? "?")")
        }
        var ids: [String: Int] = [:]
        for t in added as? [[String: Any]] ?? [] { if let c = t["content"] as? String, let id = t["id"] as? Int { ids[c] = id } }
        if let special = p["special_tokens"] as? [String: Any] {
            for (k, v) in special { if let d = v as? [String: Any], let i = (d["ids"] as? [Int])?.first { ids[k] = i } }
        }
        var pre: [Int] = [], post: [Int] = []
        var seenSequence = false
        for item in single {
            if item["Sequence"] != nil { seenSequence = true; continue }
            guard let name = (item["SpecialToken"] as? [String: Any])?["id"] as? String, let id = ids[name] else { continue }
            if seenSequence { post.append(id) } else { pre.append(id) }
        }
        return (pre, post)
    }

    // MARK: Encoding

    /// Token ids including the template's special tokens (e.g. `<s> … </s>` or `… <eos>`).
    public func encode(_ text: String) -> [Int] {
        prefixIDs + encodeBody(text) + suffixIDs
    }

    /// `encode` truncated to `length` (keeping the suffix specials) and right-padded with `padID`.
    public func contextIDs(_ text: String, length: Int, padID: Int) -> [Int] {
        var body = encodeBody(text)
        let room = length - prefixIDs.count - suffixIDs.count
        if body.count > room { body = Array(body.prefix(max(room, 0))) }
        var ids = prefixIDs + body + suffixIDs
        if ids.count < length { ids += [Int](repeating: padID, count: length - ids.count) }
        return ids
    }

    /// Number of real tokens `encode` would produce (for attention masks).
    public func tokenCount(_ text: String, limit: Int) -> Int {
        min(prefixIDs.count + encodeBody(text).count + suffixIDs.count, limit)
    }

    private func encodeBody(_ text: String) -> [Int] {
        var s = text
        for n in normalizers { s = apply(n, s) }
        var words = [s]
        for p in preTokenizers { words = words.flatMap { split(p, $0) } }
        var ids: [Int] = []
        for w in words where !w.isEmpty { ids += cachedModel(w) }
        return ids
    }

    private func apply(_ n: Normalizer, _ s: String) -> String {
        switch n {
        case let .replace(a, b): return s.replacingOccurrences(of: a, with: b)
        case let .replaceRegex(re, b):
            return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: b))
        case .nfkc: return s.precomposedStringWithCompatibilityMapping
        case .lowercase: return s.lowercased()
        case .prepend(let p): return s.isEmpty ? s : p + s
        case .nfkcWhitespace:
            // nmt_nfkc: NFKC, and every whitespace / control character becomes a plain space.
            var out = ""
            for ch in s.precomposedStringWithCompatibilityMapping {
                if ch.isWhitespace || ch.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { out.append(" ") }
                else { out.append(ch) }
            }
            return out
        }
    }

    private func split(_ p: PreTokenizer, _ s: String) -> [String] {
        switch p {
        case .splitMergedWithPrevious(let sep):
            var out: [String] = []
            var cur = ""
            for ch in s {
                cur.append(ch)
                if String(ch) == sep { out.append(cur); cur = "" }
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        case let .metaspace(rep, prefix):
            var t = s.replacingOccurrences(of: " ", with: rep)
            if prefix && !t.hasPrefix(rep) { t = rep + t }
            // Split before each replacement char (MergedWithNext).
            var out: [String] = []
            var cur = ""
            for ch in t {
                if String(ch) == rep && !cur.isEmpty { out.append(cur); cur = "" }
                cur.append(ch)
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        case .whitespaceSplit:
            return s.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }

    private func cachedModel(_ word: String) -> [Int] {
        lock.lock()
        if let hit = cache[word] { lock.unlock(); return hit }
        lock.unlock()
        let ids: [Int]
        switch model {
        case let .bpe(vocab, ranks, byteFallback, unk): ids = bpe(word, vocab, ranks, byteFallback, unk)
        case let .unigram(pieces, maxLength, unk, unkScore): ids = viterbi(word, pieces, maxLength, unk, unkScore)
        }
        lock.lock(); if cache.count > 8192 { cache.removeAll() }; cache[word] = ids; lock.unlock()
        return ids
    }

    private func bpe(_ word: String, _ vocab: [String: Int], _ ranks: [String: Int], _ byteFallback: Bool, _ unk: Int?) -> [Int] {
        var symbols = word.map(String.init)
        while symbols.count > 1 {
            var best: (rank: Int, i: Int)?
            for i in 0..<(symbols.count - 1) {
                if let r = ranks[symbols[i] + " " + symbols[i + 1]], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let b = best else { break }
            let a = symbols[b.i], c = symbols[b.i + 1]
            var merged: [String] = []
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1 && symbols[i] == a && symbols[i + 1] == c { merged.append(a + c); i += 2 }
                else { merged.append(symbols[i]); i += 1 }
            }
            symbols = merged
        }
        var ids: [Int] = []
        for sym in symbols {
            if let id = vocab[sym] { ids.append(id); continue }
            if byteFallback {
                let bytes = sym.utf8.compactMap { vocab[String(format: "<0x%02X>", $0)] }
                if bytes.count == sym.utf8.count { ids += bytes; continue }
            }
            if let unk { ids.append(unk) }
        }
        return ids
    }

    /// Best-scoring segmentation; characters no piece covers become (fused) unk.
    private func viterbi(_ word: String, _ pieces: [String: (id: Int, score: Double)], _ maxLength: Int, _ unk: Int, _ unkScore: Double) -> [Int] {
        let chars = Array(word)
        let n = chars.count
        var best = [Double](repeating: -.infinity, count: n + 1)
        var back = [(start: Int, id: Int)](repeating: (0, unk), count: n + 1)
        best[0] = 0
        for start in 0..<n where best[start] > -.infinity {
            var coveredSingle = false
            var piece = ""
            for end in (start + 1)...min(n, start + maxLength) {
                piece.append(chars[end - 1])
                guard let p = pieces[piece] else { continue }
                if end == start + 1 { coveredSingle = true }
                let s = best[start] + p.score
                if s > best[end] { best[end] = s; back[end] = (start, p.id) }
            }
            if !coveredSingle {
                let s = best[start] + unkScore
                if s > best[start + 1] { best[start + 1] = s; back[start + 1] = (start, unk) }
            }
        }
        var ids: [Int] = []
        var pos = n
        while pos > 0 { ids.append(back[pos].id); pos = back[pos].start }
        ids.reverse()
        // Fuse consecutive unknowns, as SentencePiece does.
        var fused: [Int] = []
        for id in ids where !(id == unk && fused.last == unk) { fused.append(id) }
        return fused
    }
}
