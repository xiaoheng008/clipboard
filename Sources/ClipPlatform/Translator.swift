import ClipCore
import Foundation
import Translation

/// zh → en with the system's on-device Translation (needs the language pack installed; E18/A8).
/// `installedSource` exists on macOS 26+; older systems fall back to no translation.
public struct AppleTranslator: QueryTranslator {
    public init() {}

    public func toEnglish(_ text: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        let source = Locale.Language(identifier: "zh-Hans")
        let target = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else { return nil }
        let session = TranslationSession(installedSource: source, target: target)
        return try? await session.translate(text).targetText
    }

    /// For diagnostics: "installed" / "supported" (pack not downloaded) / "unsupported" / "unavailable (<26)".
    public static func availability() async -> String {
        guard #available(macOS 26.0, *) else { return "unavailable (macOS < 26)" }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: "zh-Hans"), to: Locale.Language(identifier: "en"))
        switch status {
        case .installed: return "installed"
        case .supported: return "supported (language pack not installed)"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }
}
