import AppKit
@testable import ClipPlatform
import Testing

/// A menu-bar app only receives ⌘-shortcuts that exist in NSApp.mainMenu (key equivalents route through it).
@MainActor @Suite struct AppMenuTests {
    func item(_ menu: NSMenu, key: String, mods: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        menu.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods }
    }

    @Test func commandWClosesTheKeyWindow() {
        let w = item(AppMenu.build(), key: "w")
        #expect(w?.action == #selector(NSWindow.performClose(_:)))
        #expect(w?.target == nil)            // first responder chain → the key window (panel or settings)
    }

    @Test func editingAndQuitShortcutsStay() {
        let m = AppMenu.build()
        for k in ["z", "x", "c", "v", "a", "q"] { #expect(item(m, key: k) != nil, "⌘\(k)") }
        #expect(item(m, key: "z", mods: [.command, .shift]) != nil)
    }
}
