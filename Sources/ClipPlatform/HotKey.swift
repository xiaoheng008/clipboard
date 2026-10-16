import AppKit
import Carbon.HIToolbox
import ClipCore

/// A key combination stored as "keyCode:carbonModifiers" (settings key `hotkey`, Q6: empty by default).
public struct HotKeyCombo: Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) { self.keyCode = keyCode; self.carbonModifiers = carbonModifiers }

    public init?(setting: String?) {
        guard let s = setting else { return nil }
        let parts = s.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], carbonModifiers: parts[1])
    }

    public var setting: String { "\(keyCode):\(carbonModifiers)" }

    /// Q6 (revised 2026-10-17 by the user): ⌥Space unless the user has set or cleared it.
    public static let defaultCombo = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    /// Stored when the user explicitly clears the hotkey, so the default does not come back.
    public static let clearedSetting = "none"

    /// Setting value → combo: absent = default; `clearedSetting` / unparsable = none.
    public static func resolve(setting: String?) -> HotKeyCombo? {
        guard let setting else { return defaultCombo }
        return HotKeyCombo(setting: setting)
    }

    /// From an NSEvent captured by the recorder. Requires at least one of ⌘ ⌥ ⌃ (a bare key would hijack typing).
    public init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: m)
    }

    public var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
                                         UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫"]
        if let s = special[code] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let rc = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return rc == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }
}

/// Registers at most one global hotkey with Carbon (no Accessibility permission needed).
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    fileprivate var action: (() -> Void)?
    public private(set) var registered: HotKeyCombo?
    public private(set) var lastError: OSStatus = noErr
    /// The combination that could not be registered last time (shown in Settings, R6).
    public private(set) var failed: HotKeyCombo?
    private var nextID: UInt32 = 1

    /// Registers the new combination *before* releasing the old one, so a failure keeps the old hotkey
    /// working (E26 / R6). Returns false if the combination is taken by the system or another app.
    @discardableResult
    public func register(_ combo: HotKeyCombo?, action: @escaping () -> Void) -> Bool {
        self.action = action
        guard let combo else { unregister(); failed = nil; return true }
        if combo == registered { failed = nil; return true }
        installHandler()
        var hotKeyRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x434C5056), id: nextID)   // 'CLPV'
        nextID += 1
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        lastError = status
        guard status == noErr, let hotKeyRef else { failed = combo; return false }
        if let ref { UnregisterEventHotKey(ref) }
        ref = hotKeyRef
        registered = combo
        failed = nil
        return true
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
