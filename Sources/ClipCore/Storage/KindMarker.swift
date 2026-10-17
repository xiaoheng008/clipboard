import Foundation

/// FR27: every index row carries a marker that only its kind has, so a kind tab is an index AND
/// instead of a walk over all matches (docs/scv/2.2 「分类标记」).
/// Contract: the marker spellings are stored data — changing them needs a schema version and a rebuild.
public enum KindMarker {
    static let settingKey = "index.kind_markers"

    private static func code(_ k: ItemKind) -> UInt32 {
        switch k { case .text: 1; case .rich: 2; case .url: 3; case .file: 4; case .image: 5 }
    }

    /// Three Supplementary Private Use Area-B characters = exactly one trigram.
    public static func fts(_ k: ItemKind) -> String {
        var s = String.UnicodeScalarView()
        for v in [0x10FFF0, 0x10FFF0, 0x10FFF0 + code(k)] { s.append(Unicode.Scalar(v)!) }
        return String(s)
    }

    /// N-gram content tokens all start with "x"; markers start with "k".
    public static func ngram(_ k: ItemKind) -> String { "k" + k.rawValue }

    /// Removes Private Use Area-B characters (U+100000–U+10FFFF) so user content and queries cannot
    /// contain or forge a marker.
    static func strip(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value >= 0x100000 }) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where u.value < 0x100000 { out.append(u) }
        return String(out)
    }
}

/// `settings.index.kind_markers` (3.1 §4.5). Absent = done (libraries created at v2 never lacked markers).
public enum KindMarkerState: Equatable, Sendable {
    case done
    case rebuilding(cursor: Int64)   // rows with seq < cursor still lack markers

    init(setting: String?) {
        if let s = setting, s.hasPrefix("rebuilding:"), let c = Int64(s.dropFirst("rebuilding:".count)) { self = .rebuilding(cursor: c) } else { self = .done }
    }

    var settingValue: String {
        switch self { case .done: "done"; case .rebuilding(let c): "rebuilding:\(c)" }
    }
}
