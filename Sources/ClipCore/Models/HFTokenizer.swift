import Foundation

/// A subset of HuggingFace `tokenizer.json`, enough for the multilingual models we ship:
/// Gemma (SigLIP2 / EmbeddingGemma: BPE + byte fallback), XLM-R (multilingual-e5: Unigram + Metaspace)
/// and byte-level BPE (Granite, Qwen3: regex split + ByteLevel).
/// Parity with the Python `tokenizers` library is pinned by HFTokenizerTests.
/// Dictionary key compared byte-for-byte. Swift String equality uses Unicode canonical equivalence,
/// so e.g. U+884C 行 and the compatibility ideograph U+FA08 行 would collide — but they are different
/// tokens with different ids in real vocabularies (Gemma 3). Tokenizers must compare exact UTF-8.
struct ExactKey: Hashable {
    let s: String
    init(_ s: String) { self.s = s }
    static func == (a: ExactKey, b: ExactKey) -> Bool { a.s.utf8.elementsEqual(b.s.utf8) }
    func hash(into h: inout Hasher) { for b in s.utf8 { h.combine(b) } }
}

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
        case nfc
        case lowercase
        case prepend(String)
    }

    enum PreTokenizer {
        case splitMergedWithPrevious(String)
        case splitIsolated(NSRegularExpression)        // matches and the gaps between them become pieces
        case byteLevel(addPrefixSpace: Bool, useRegex: Bool)
        case metaspace(String, prefix: Bool)
        case whitespaceSplit
    }

    enum Model {
        case bpe(vocab: [ExactKey: Int], ranks: [ExactKey: Int], byteFallback: Bool, unk: Int?, ignoreMerges: Bool)
        case unigram(pieces: [ExactKey: (id: Int, score: Double)], maxLength: Int, unk: Int, unkScore: Double)
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
            // NSDictionary keys from JSONSerialization are compared literally (NSString), so no entry is lost here.
            guard let rawVocab = m["vocab"] as? NSDictionary, let merges = m["merges"] as? [Any] else { throw LoadError.malformed("BPE") }
            var vocab: [ExactKey: Int] = [:]
            vocab.reserveCapacity(rawVocab.count)
            for (k, v) in rawVocab { if let k = k as? String, let v = v as? Int { vocab[ExactKey(k)] = v } }
            var ranks: [ExactKey: Int] = [:]
            ranks.reserveCapacity(merges.count)
            for (i, item) in merges.enumerated() {
                if let pair = item as? [String], pair.count == 2 { ranks[ExactKey(pair[0] + " " + pair[1])] = i }
                else if let s = item as? String { ranks[ExactKey(s)] = i }
            }
            let unk = (m["unk_token"] as? String).flatMap { vocab[ExactKey($0)] }
            model = .bpe(vocab: vocab, ranks: ranks, byteFallback: m["byte_fallback"] as? Bool ?? false, unk: unk,
                         ignoreMerges: m["ignore_merges"] as? Bool ?? false)
        case "Unigram":
            guard let vocab = m["vocab"] as? [[Any]] else { throw LoadError.malformed("Unigram") }
            var pieces: [ExactKey: (Int, Double)] = [:]
            pieces.reserveCapacity(vocab.count)
            var maxLen = 1
            var minScore = Double.infinity
            for (i, entry) in vocab.enumerated() {
                guard let piece = entry.first as? String, let score = (entry.last as? NSNumber)?.doubleValue else { continue }
                pieces[ExactKey(piece)] = (i, score)
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
        case "NFC": return [.nfc]
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
            let pattern = p["pattern"] as? [String: Any]
            let behavior = p["behavior"] as? String
            if let literal = pattern?["String"] as? String, behavior == "MergedWithPrevious" { return [.splitMergedWithPrevious(literal)] }
            if let regex = pattern?["Regex"] as? String, behavior == "Isolated", p["invert"] as? Bool != true {
                return [.splitIsolated(try NSRegularExpression(pattern: regex))]
            }
            throw LoadError.unsupported("Split \(behavior ?? "?")")
        case "ByteLevel":
            return [.byteLevel(addPrefixSpace: p["add_prefix_space"] as? Bool ?? false, useRegex: p["use_regex"] as? Bool ?? true)]
        case "Metaspace":
            let scheme = p["prepend_scheme"] as? String
            let prefix = scheme.map { $0 != "never" } ?? (p["add_prefix_space"] as? Bool ?? true)
            return [.metaspace(p["replacement"] as? String ?? "▁", prefix: prefix)]
        case "WhitespaceSplit": return [.whitespaceSplit]
        default: throw LoadError.unsupported("pre_tokenizer \(type)")
        }
    }

    private static func parsePost(_ any: Any?, _ added: Any?) throws -> ([Int], [Int]) {
        guard var p = any as? [String: Any] else { return ([], []) }
        // Sequence(ByteLevel, TemplateProcessing): ByteLevel only adjusts offsets; use the template.
        if p["type"] as? String == "Sequence" {
            let parts = p["processors"] as? [[String: Any]] ?? []
            guard let template = parts.first(where: { $0["type"] as? String == "TemplateProcessing" }) else {
                if parts.allSatisfy({ $0["type"] as? String == "ByteLevel" }) { return ([], []) }
                throw LoadError.unsupported("post Sequence")
            }
            p = template
        }
        if p["type"] as? String == "ByteLevel" { return ([], []) }
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
    public func contextIDs(_ text: String, length: Int, padID: Int, padLeft: Bool = false) -> [Int] {
        var body = encodeBody(text)
        let room = length - prefixIDs.count - suffixIDs.count
        if body.count > room { body = Array(body.prefix(max(room, 0))) }
        let ids = prefixIDs + body + suffixIDs
        guard ids.count < length else { return ids }
        let pad = [Int](repeating: padID, count: length - ids.count)
        return padLeft ? pad + ids : ids + pad          // Qwen3 (last-token pooling) expects left padding
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
        case .nfc: return s.precomposedStringWithCanonicalMapping
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
        case .splitIsolated(let re):
            return Self.isolate(s, re)
        case let .byteLevel(addPrefixSpace, useRegex):
            var t = s
            if addPrefixSpace && !t.hasPrefix(" ") { t = " " + t }
            let pieces = useRegex ? Self.isolate(t, Self.gpt2Pattern) : [t]
            return pieces.map { piece in String(piece.utf8.map { Self.byteToUnicode[$0]! }) }
        }
    }

    static let byteToUnicode = CLIPTokenizer.makeByteToUnicode()
    static let gpt2Pattern = try! NSRegularExpression(pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#)

    /// Regex matches and the text between them, in order (HF "Isolated").
    static func isolate(_ s: String, _ re: NSRegularExpression) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var cursor = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
            if m.range.location > cursor { out.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))) }
            out.append(ns.substring(with: m.range))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out.append(ns.substring(from: cursor)) }
        return out
    }

    private func cachedModel(_ word: String) -> [Int] {
        lock.lock()
        if let hit = cache[word] { lock.unlock(); return hit }
        lock.unlock()
        let ids: [Int]
        switch model {
        case let .bpe(vocab, ranks, byteFallback, unk, ignoreMerges):
            if ignoreMerges, let id = vocab[ExactKey(word)] { ids = [id] } else { ids = bpe(word, vocab, ranks, byteFallback, unk) }
        case let .unigram(pieces, maxLength, unk, unkScore): ids = viterbi(word, pieces, maxLength, unk, unkScore)
        }
        lock.lock(); if cache.count > 8192 { cache.removeAll() }; cache[word] = ids; lock.unlock()
        return ids
    }

    private func bpe(_ word: String, _ vocab: [ExactKey: Int], _ ranks: [ExactKey: Int], _ byteFallback: Bool, _ unk: Int?) -> [Int] {
        // Symbols are unicode scalars (not grapheme clusters / canonical-equivalent Characters).
        var symbols = word.unicodeScalars.map { String($0) }
        while symbols.count > 1 {
            var best: (rank: Int, i: Int)?
            for i in 0..<(symbols.count - 1) {
                if let r = ranks[ExactKey(symbols[i] + " " + symbols[i + 1])], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let b = best else { break }
            let a = ExactKey(symbols[b.i]), c = ExactKey(symbols[b.i + 1])
            var merged: [String] = []
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1 && ExactKey(symbols[i]) == a && ExactKey(symbols[i + 1]) == c { merged.append(symbols[i] + symbols[i + 1]); i += 2 }
                else { merged.append(symbols[i]); i += 1 }
            }
            symbols = merged
        }
        var ids: [Int] = []
        for sym in symbols {
            if let id = vocab[ExactKey(sym)] { ids.append(id); continue }
            if byteFallback {
                let bytes = sym.utf8.compactMap { vocab[ExactKey(String(format: "<0x%02X>", $0))] }
                if bytes.count == sym.utf8.count { ids += bytes; continue }
            }
            if let unk { ids.append(unk) }
        }
        return ids
    }

    /// Best-scoring segmentation; characters no piece covers become (fused) unk.
    private func viterbi(_ word: String, _ pieces: [ExactKey: (id: Int, score: Double)], _ maxLength: Int, _ unk: Int, _ unkScore: Double) -> [Int] {
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
                guard let p = pieces[ExactKey(piece)] else { continue }
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
