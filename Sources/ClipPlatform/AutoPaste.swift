import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// FR28: the platform facts PasteDecision needs, and the synthetic ⌘V. Posting keys into another app requires
/// Accessibility (System Settings › Privacy & Security › Accessibility); without it the system drops the event
/// silently, so callers check `isTrusted` first and fall back to copy only (3.4 §5).
@MainActor
public enum AutoPaste {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds ClipVault to the Accessibility list (the user still has to switch it on).
    @discardableResult
    public static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A password field (or any app) holding secure event input makes the system drop synthetic key events.
    public static var secureInputOn: Bool { IsSecureEventInputEnabled() }

    public static var frontmostPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// ⌘V to whatever app is frontmost (the panel is non-activating, so that is still the original app).
    public static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
