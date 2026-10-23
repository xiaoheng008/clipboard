import AppKit
import ClipCore
import ClipPlatform
import SwiftUI

/// `ClipVault --snapshot <dir>`: renders the real panel and settings views offscreen into PNGs (light and dark),
/// as evidence for the manual acceptance cases (AC5.1 / AC5.4 / AC21.2). Fills a demo library first.
///
/// Privacy: refuses to run unless CLIPVAULT_HOME points at a directory other than the real library, so a
/// screenshot can never contain the user's clipboard history. Runs inside NSApplication so SwiftUI gets a
/// real run loop; no window is ever shown on screen.
@MainActor
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    let outDir: URL
    private(set) var exitCode: Int32 = 0

    init(outDir: URL) { self.outDir = outDir }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { print("snapshot failed: \(error)"); exitCode = 1 }
            exit(exitCode)
        }
    }

    private func run() async throws {
        guard let custom = ProcessInfo.processInfo.environment["CLIPVAULT_HOME"], !custom.isEmpty else {
            throw CLIError.usage("--snapshot needs CLIPVAULT_HOME set to a demo directory (never the real library)")
        }
        let home = try AppHome.resolve()
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClipVault")
        guard home.root.standardizedFileURL.path != real.standardizedFileURL.path else {
            throw CLIError.usage("--snapshot refuses to render the real library")
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let rt = try await Runtime.open(home: home, services: .system(home: home), startWorker: false, sweepTmp: false)
        if try await rt.service.counts().items == 0 { try await SnapshotDemo.seed(rt) }
        _ = await rt.worker.drain()   // OCR for the demo images

        let tracker = ActionTracker(center: ActionCenter(telemetry: nil))
        let panel = PanelModel(service: rt.service, home: home, tracker: tracker)
        panel.hotkeyDisplay = HotKeyCombo.defaultCombo.display
        let settings = SettingsModel(rt: rt, tracker: tracker)

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let look = NSAppearance(named: appearance)
            // Panel: same size and content view as the real HistoryPanel (AppDelegate.showPanel).
            let win = Self.offscreenWindow(size: NSSize(width: 820, height: 520), appearance: look)
            win.contentView = NSHostingView(rootView: PanelView(model: panel))
            panel.panelDidOpen()
            try await settle(win, 1.5)
            try save(win, "AC5.1-panel-first-row-\(suffix)")
            panel.moveSelection(2)                       // what ↓↓ does (PanelView key handler → moveSelection)
            try await settle(win, 0.8)
            try save(win, "AC5.1-panel-arrow-down-2-\(suffix)")

            if let link = panel.rows.first(where: { $0.item.kind == .url }) {
                panel.selection = link.id
                panel.overrideCommandKey(false)
                try await settle(win, 0.8)
                try save(win, "AC21.2-link-without-cmd-\(suffix)")
                panel.overrideCommandKey(true)           // what the flagsChanged monitor sets while ⌘ is held
                try await settle(win, 0.5)
                try save(win, "AC21.2-link-with-cmd-\(suffix)")
                panel.overrideCommandKey(false)
            }
            if let file = panel.rows.first(where: { $0.item.kind == .file }) {
                panel.selection = file.id
                panel.overrideCommandKey(true)
                try await settle(win, 0.8)
                try save(win, "AC21.2-file-with-cmd-\(suffix)")
                panel.overrideCommandKey(false)
            }
            if let image = panel.rows.first(where: { $0.item.kind == .image }) {
                panel.selection = image.id
                try await settle(win, 1.2)
                try save(win, "panel-image-detail-\(suffix)")
            }
            panel.query = "发票"
            try await settle(win, 1.5)
            try save(win, "panel-search-zh-\(suffix)")
            panel.panelWillClose()
            win.contentView = nil

            // Settings tabs, rendered one by one at the real window size.
            await settings.reload()
            for (name, view) in [("general", AnyView(GeneralTab(model: settings))), ("models", AnyView(ModelsTab(model: settings))),
                                 ("diagnostics", AnyView(DiagnosticsTab(model: settings)))] {
                let sw = Self.offscreenWindow(size: NSSize(width: 640, height: 520), appearance: look)
                sw.contentView = NSHostingView(rootView: view.padding(16).frame(width: 640, height: 520).background(Color(nsColor: .windowBackgroundColor)))
                try await settle(sw, 1.0)
                try save(sw, "AC5.2-settings-\(name)-\(suffix)")
                sw.contentView = nil
            }
        }
        try await tabSwitches(settings)
        print("snapshots written to \(outDir.path)")
    }

    /// The real SettingsView (TabView included) in a key, titled window, switched tab by tab the way clicks do.
    /// Selectable text in a grouped Form froze 模型 → 通用 only in a key window (0.2.2), which borderless,
    /// non-key snapshots never reach. A main thread silent for 5 s exits 2: the hang fails the run instead of
    /// freezing it. Takes keyboard focus for a few seconds (the window itself is fully transparent).
    private func tabSwitches(_ settings: SettingsModel) async throws {
        let beat = Heartbeat()
        let watchdog = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                if beat.staleSeconds > 5 { print("tab switch hang: main thread unresponsive since \(beat.label)"); exit(2) }
            }
        }
        watchdog.start()
        NSApp.setActivationPolicy(.accessory)
        let sw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sw.isReleasedWhenClosed = false
        sw.alphaValue = 0
        sw.contentView = NSHostingView(rootView: SettingsView(model: settings))
        NSApp.activate()
        sw.makeKeyAndOrderFront(nil)
        for tab in ["models", "general", "diagnostics", "models", "general"] {
            beat.mark("→ \(tab)")
            settings.tab = tab
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)); beat.mark("→ \(tab)") }
            sw.contentView?.layoutSubtreeIfNeeded()
            sw.displayIfNeeded()
            print("  tab switch → \(tab) ok  key=\(sw.isKeyWindow)")
        }
        sw.orderOut(nil)
        sw.contentView = nil
    }

    private static func offscreenWindow(size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = appearance
        w.isReleasedWhenClosed = false
        w.backgroundColor = .windowBackgroundColor
        return w
    }

    /// Lets async loads (pages, thumbnails, debounced search) land and SwiftUI commit, on the real run loop.
    private func settle(_ win: NSWindow, _ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
        win.contentView?.layoutSubtreeIfNeeded()
        win.displayIfNeeded()
    }

    private func save(_ win: NSWindow, _ name: String) throws {
        guard let view = win.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        print("  \(name).png")
    }
}

/// Last time the main thread checked in, read from the watchdog thread.
final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var what = "start"
    func mark(_ label: String) { lock.lock(); last = Date(); what = label; lock.unlock() }
    var staleSeconds: Double { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    var label: String { lock.lock(); defer { lock.unlock() }; return what }
}

/// Demo library content (made up; no user data).
enum SnapshotDemo {
    static func seed(_ rt: Runtime) async throws {
        func ctx(_ id: String, _ name: String) -> CaptureContext {
            CaptureContext(frontmostBundleID: id, frontmostName: name, excludedBundleIDs: [], lastSelfWriteChangeCount: nil)
        }
        let notes = ctx("com.apple.Notes", "备忘录"), safari = ctx("com.apple.Safari", "Safari"),
            finder = ctx("com.apple.finder", "访达"), xcode = ctx("com.apple.dt.Xcode", "Xcode"), preview = ctx("com.apple.Preview", "预览")
        let items: [(PasteboardSnapshot, CaptureContext)] = [
            (text("发票抬头：示例科技有限公司\n税号：91110000DEMO00001X\n开户行：示例银行北京分行"), notes),
            (text("Quarterly review moved to Friday 10:00, room Orion. Bring the Q3 numbers."), notes),
            (text("https://www.apple.com/macos/"), safari),
            (PasteboardSnapshot(changeCount: -1, types: ["public.file-url"], fileURLs: ["file:///Users/Shared/Demo/项目计划.pdf"]), finder),
            (text("func search(_ query: String) async throws -> [Item] {\n    try await store.search(QueryPlanner.plan(query))\n}"), xcode),
            (image(title: "发票 INVOICE", lines: ["No. 2026-0042", "金额 ¥1,280.00", "Due 2026-11-15"], color: .systemBlue), preview),
            (text("明天下午三点在三楼会议室开项目周会，记得带上季度报告"), notes),
            (image(title: "Server Error 500", lines: ["GET /api/orders", "upstream timeout", "trace id 7f3a"], color: .systemRed), preview),
            (text("下班记得去超市买牛奶、鸡蛋和面包"), notes),
            (text("mailto:team@example.com"), safari),
        ]
        for (snap, c) in items {
            _ = await rt.service.ingest(snap, context: c)
            try await Task.sleep(for: .milliseconds(20))   // distinct timestamps, stable order
        }
    }

    static func text(_ s: String) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: -1, types: ["public.utf8-plain-text"], string: s)
    }

    /// A screenshot-like PNG drawn with CoreGraphics (so OCR has real text to read).
    static func image(title: String, lines: [String], color: NSColor) -> PasteboardSnapshot {
        let size = NSSize(width: 800, height: 500)
        let img = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            color.setFill(); NSRect(x: 0, y: 0, width: rect.width, height: 110).fill()
            (title as NSString).draw(at: NSPoint(x: 40, y: 28), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white])
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(at: NSPoint(x: 40, y: 150 + CGFloat(i) * 80), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
            }
            return true
        }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let png = rep.representation(using: .png, properties: [:])!
        return PasteboardSnapshot(changeCount: -1, types: ["public.png"],
                                  image: CapturedImage(data: png, uti: "public.png", width: rep.pixelsWide, height: rep.pixelsHigh))
    }
}
