import Foundation

/// FR21: links inside item text, for click-to-open in the detail pane.
/// Only web and mail links are clickable — clipboard text may contain file:// or app-specific schemes
/// that would open local files or launch other apps.
public enum LinkDetector {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public struct Link: Sendable, Equatable {
        public let range: Range<String.Index>
        public let url: URL
    }

    /// The URL for a link item (whole text), if it is safe to open.
    public static func safeURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.contains(where: \.isWhitespace), let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        return scheme == "mailto" || url.host != nil ? url : nil
    }

    /// Links found in `text` (bounded by the caller), restricted to `allowedSchemes`.
    public static func links(in text: String) -> [Link] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: ns).compactMap { m in
            guard let url = m.url, let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme),
                  let r = Range(m.range, in: text) else { return nil }
            return Link(range: r, url: url)
        }
    }
}

/// FR22: the files of a file item (absolute paths, one per line), split by whether they still exist.
public enum FileItemPaths {
    public static func resolve(text: String) -> (existing: [URL], missing: [String]) {
        var existing: [URL] = []
        var missing: [String] = []
        for line in text.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where line.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: line) { existing.append(URL(fileURLWithPath: line)) } else { missing.append(line) }
        }
        return (existing, missing)
    }
}
