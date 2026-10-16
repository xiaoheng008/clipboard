import AppKit
import ClipCore
import ClipPlatform
import SwiftUI

/// Floating panel that can take keyboard focus without activating the app.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var rt: Runtime?
    private var watcher: ClipboardWatcher?
    private var statusItem: NSStatusItem?
    private var panel: HistoryPanel?
    private var panelModel: PanelModel?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var accessDenied = false
    private var toast: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupStatusItem()
        Task { await start() }
    }

    private func start() async {
        do {
            let home = try AppHome.resolve()
            ModelInstaller(home: home).cleanIncomplete()
            let rt = try await Runtime.open(home: home, services: .system(home: home))
            self.rt = rt
            let model = PanelModel(service: rt.service, home: home)
            model.onClose = { [weak self] in self?.hidePanel() }
            model.onCopied = { [weak self] msg in self?.showToast(msg) }
            model.onOpenSettings = { [weak self] in self?.hidePanel(); self?.openSettings() }
            panelModel = model
            await rt.service.setChangeHandler { [weak self] event in
                Task { @MainActor in
                    if event == .itemsChanged { self?.panelModel?.storeChanged() }
                    if case .modelChanged = event { Task { await self?.settingsModel?.reload() } }
                }
            }
            let w = ClipboardWatcher(service: rt.service)
            w.onAccessDenied = { [weak self] in self?.setAccessDenied(true) }
            w.start()
            watcher = w
            // Startup assertion (iron law 14): denied access is visible, not silent.
            setAccessDenied(PasteboardAccess.current() == .denied)
            if let combo = HotKeyCombo.resolve(setting: try? await rt.db.setting(SettingKey.hotkey)) {
                if !HotKeyCenter.shared.register(combo, action: { [weak self] in self?.togglePanel() }) {
                    Log.shared.event("hotkey.register_failed", ["status": .int(Int64(HotKeyCenter.shared.lastError))])
                }
            }
            rebuildMenu()
        } catch {
            let alert = NSAlert()
            alert.messageText = "ClipVault 无法启动"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// A menu-bar-only app has no main menu, and without an Edit menu text fields never receive
    /// ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z (key equivalents are routed through NSApp.mainMenu). Not shown on screen.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "退出 ClipVault", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "ClipVault")
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func setAccessDenied(_ denied: Bool) {
        accessDenied = denied
        statusItem?.button?.image = NSImage(systemSymbolName: denied ? "exclamationmark.triangle" : "list.clipboard", accessibilityDescription: "ClipVault")
        rebuildMenu()
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            rebuildMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    private var menu = NSMenu()

    private func rebuildMenu() {
        let m = NSMenu()
        if accessDenied {
            let warn = NSMenuItem(title: "⚠︎ 无法读取剪贴板：请在系统设置中允许", action: #selector(openPrivacySettings), keyEquivalent: "")
            warn.target = self
            m.addItem(warn)
            m.addItem(.separator())
        }
        let hk = HotKeyCenter.shared.registered.map { "（\($0.display)）" } ?? ""
        m.addItem(withTitle: "打开历史面板\(hk)", action: #selector(togglePanel), keyEquivalent: "").target = self
        m.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "退出 ClipVault", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu = m
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    // MARK: Panel

    @objc func togglePanel() {
        if let panel, panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let model = panelModel else { return }
        if panel == nil {
            let p = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                                 styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView, .closable],
                                 backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.delegate = self
            p.contentView = NSHostingView(rootView: PanelView(model: model))
            panel = p
        }
        guard let panel else { return }
        model.hotkeyDisplay = HotKeyCenter.shared.registered?.display
        model.panelDidOpen()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.midY - panel.frame.height / 2 + vf.height * 0.1))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        panelModel?.panelWillClose()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { hidePanel() }
    }

    // MARK: Settings

    @objc func openSettings() {
        guard let rt else { return }
        if settingsWindow == nil {
            let m = SettingsModel(rt: rt)
            m.onHotkeyChanged = { [weak self] combo in
                let ok = HotKeyCenter.shared.register(combo, action: { self?.togglePanel() })
                self?.rebuildMenu()
                return ok
            }
            m.probes = { [weak self] in await self?.probes() ?? .unavailable }
            settingsModel = m
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ClipVault 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: m))
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func probes() async -> PlatformProbes {
        let hk: String
        if let r = HotKeyCenter.shared.registered { hk = "\(r.display) registered" }
        else if let rt, HotKeyCombo.resolve(setting: try? await rt.db.setting(SettingKey.hotkey)) != nil { hk = "failed to register (status \(HotKeyCenter.shared.lastError))" }
        else { hk = "unset (menu bar icon opens the panel)" }
        return PlatformProbes(pasteboardAccess: PasteboardAccess.current().rawValue,
                              translation: await AppleTranslator.availability(),
                              hotkey: hk,
                              watcherHeartbeatAgeSeconds: watcher?.lastPoll.map { Date().timeIntervalSince($0) },
                              loginItem: LoginItem.state.rawValue,
                              hardware: "\(HardwareProbe.cpuBrand), \(HardwareProbe.memoryGB) GB, \(HardwareProbe.osVersion)")
    }

    // MARK: Toast

    private func showToast(_ text: String) {
        toast?.orderOut(nil)
        let label = NSHostingView(rootView: Text(text).font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()))
        let size = label.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.contentView = label
        if let vf = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 80))
        }
        p.orderFrontRegardless()
        toast = p
        Task { try? await Task.sleep(for: .seconds(1.2)); if self.toast === p { p.orderOut(nil) } }
    }
}
