import AppKit
import ClipCore
import ClipPlatform
import SwiftUI

@MainActor @Observable
final class SettingsModel {
    let rt: Runtime
    let installer: ModelInstaller
    let tracker: ActionTracker
    var hotkeyText = "未设置"
    var hotkeyError: String?
    var recording = false
    var excluded: [String] = []
    var stats = ""
    var active: [ModelSlot: String] = [:]
    var slotStates: [ModelSlot: ModelSlotState] = [:]
    var coverage: [ModelSlot: SemanticCoverage] = [:]
    var vectorCounts: [String: Int] = [:]
    /// FR24: effective thresholds of the active models, and the values being dragged.
    var thresholds: [String: SemanticThresholds] = [:]
    var floorDraft: [String: Double] = [:]
    var marginDraft: [String: Double] = [:]
    var installing: [String: InstallProgress] = [:]
    var diagnostics = ""
    var purgeInfo: String?
    var launchAtLogin = LoginItem.state == .enabled
    var loginItemStatus = LoginItem.displayName
    var newExcluded = ""
    var confirmClear = false
    var confirmPurge = false
    @ObservationIgnored var keyMonitor: Any?
    var onHotkeyChanged: ((HotKeyCombo?) -> Bool)?
    var probes: () async -> PlatformProbes = { .unavailable }

    init(rt: Runtime, tracker: ActionTracker) {
        self.rt = rt
        self.tracker = tracker
        installer = ModelInstaller(home: rt.home)
    }

    var catalog: [ModelManifest] { rt.service.catalog.models }
    var memoryGB: Int { HardwareProbe.memoryGB }
    func recommendedID(_ slot: ModelSlot) -> String? { rt.service.catalog.recommended(memoryGB: memoryGB, slot: slot)?.id }
    func installed(_ m: ModelManifest) -> Bool { ModelPaths.isInstalled(home: rt.home, model: m) }
    func slotBusy(_ slot: ModelSlot) -> Bool { if case .activating = slotStates[slot] { true } else { false } }

    func reload() async {
        let stored = try? await rt.db.setting(SettingKey.hotkey)
        if let h = HotKeyCombo.resolve(setting: stored) { hotkeyText = h.display + (stored == nil ? "（默认）" : "") } else { hotkeyText = "未设置" }
        // R6: say so when the combination is taken (e.g. by an input method or launcher).
        if let f = HotKeyCenter.shared.failed {
            hotkeyError = "\(f.display) 已被系统或其他 App 占用，未生效" + (HotKeyCenter.shared.registered.map { "；当前仍是 \($0.display)" } ?? "；请录制其他组合")
        }
        excluded = await rt.service.excludedApps()
        if let c = try? await rt.service.counts() {
            stats = "\(c.items) 条历史（图片 \(c.images)） · 图片占用 \(ByteCountFormatter.string(fromByteCount: rt.blobs.totalBytes(), countStyle: .file))"
        }
        for slot in ModelSlot.allCases {
            active[slot] = await rt.service.activeModelManifest(slot: slot)?.id
            slotStates[slot] = await rt.service.slotState(slot)
            if let id = active[slot] { coverage[slot] = try? await rt.service.coverage(modelID: id) } else { coverage[slot] = nil }
        }
        vectorCounts = (try? await rt.service.embeddingCounts()) ?? [:]
        for id in active.values {
            let t = await rt.service.semanticThresholds(modelID: id)
            thresholds[id] = t
            floorDraft[id] = Double(t.floor)
            marginDraft[id] = Double(t.margin)
        }
    }

    func saveThresholds(_ id: String) async throws {
        try await rt.service.setSemanticThresholds(modelID: id, floor: floorDraft[id].map { Float($0) }, margin: marginDraft[id].map { Float($0) })
        await reload()
    }

    func resetThresholds(_ id: String) async throws {
        try await rt.service.setSemanticThresholds(modelID: id, floor: nil, margin: nil)
        await reload()
    }

    // MARK: Hotkey

    func record(_ event: NSEvent) {
        recording = false
        guard let combo = HotKeyCombo(event: event) else { hotkeyError = "需要包含 ⌘、⌥ 或 ⌃"; return }
        tracker.perform(key: "settings.hotkey.record", name: "settings.hotkey.record", detail: combo.setting) { [self] in
            if onHotkeyChanged?(combo) == false {
                hotkeyError = "\(combo.display) 已被系统或其他 App 占用" + (HotKeyCenter.shared.registered.map { "，仍使用 \($0.display)" } ?? "")
                return
            }
            hotkeyError = nil
            try await rt.db.setSetting(SettingKey.hotkey, combo.setting)
            await reload()
        }
    }

    func clearHotkey() async throws {
        _ = onHotkeyChanged?(nil)
        hotkeyError = nil
        try await rt.db.setSetting(SettingKey.hotkey, HotKeyCombo.clearedSetting)
        await reload()
    }

    func setLaunchAtLogin(_ on: Bool) {
        tracker.perform(key: "settings.login_item", name: "settings.login_item", detail: on ? "on" : "off") { [self] in
            defer { launchAtLogin = LoginItem.state == .enabled; loginItemStatus = LoginItem.displayName }
            try LoginItem.set(on)
        }
    }

    // MARK: Excluded apps

    func addExcluded(_ bundleID: String) async throws {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !excluded.contains(id) else { return }
        try await rt.service.setExcludedApps(excluded + [id])
        await reload()
    }

    func removeExcluded(_ id: String) async throws {
        try await rt.service.setExcludedApps(excluded.filter { $0 != id })
        await reload()
    }

    // MARK: Models

    static func installKey(_ m: ModelManifest) -> String { "settings.model.install.\(m.id)" }

    func install(_ m: ModelManifest) async throws {
        installing[m.id] = InstallProgress(modelID: m.id, bytesDone: 0, bytesTotal: m.downloadBytes, phase: .downloading)
        defer { installing[m.id] = nil; Task { await reload() } }
        try await installer.install(m) { p in
            Task { @MainActor in if self.installing[m.id] != nil { self.installing[m.id] = p } }
        }
    }

    func activate(_ m: ModelManifest) async throws {
        defer { Task { await reload() } }
        slotStates[m.slot] = .activating(target: m.id, previous: active[m.slot])
        try await rt.service.activateModel(id: m.id)
    }

    func deactivate(_ slot: ModelSlot) async throws {
        defer { Task { await reload() } }
        try await rt.service.deactivateModel(slot: slot)
    }

    func remove(_ m: ModelManifest) async throws {
        defer { Task { await reload() } }
        if active[m.slot] == m.id { try await rt.service.deactivateModel(slot: m.slot) }
        try await installer.remove(m.id)
    }

    func purgePreview() async throws {
        let r = try await Maintenance.purgeInactive(rt, scope: .dryRun)
        let total = r.byModel.values.reduce(0, +)
        purgeInfo = total == 0 ? "没有未启用模型的向量" : "将删除 \(total) 条未启用模型的向量：" + r.byModel.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "，")
        confirmPurge = true
    }

    func purgeConfirm() async throws {
        _ = try await Maintenance.purgeInactive(rt, scope: .all)
        purgeInfo = "已清理"
        await reload()
    }

    // MARK: Diagnostics / data

    func runDiagnostics() async {
        let report = await Diagnostics.run(rt, probes: await probes())
        diagnostics = report.rendered
    }

    func exportLogs() async throws {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let dest = dir.appendingPathComponent("ClipVault-logs-\(Int(Date().timeIntervalSince1970))")
        var files = try Log.shared.export(to: dest)
        if let report = try? await TelemetryStore(home: rt.home).report(limit: TelemetryStore.keep) {
            let u = dest.appendingPathComponent("slow-ops.txt")
            try report.write(to: u, atomically: true, encoding: .utf8)
            files.append(u)
        }
        diagnostics += "\n\n已导出 \(files.count) 个文件到 \(dest.path)（不包含剪贴板内容）"
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    func clearAll() async throws {
        defer { Task { await reload() } }
        try await rt.service.clearAll()     // R7: errors surface through the action state
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("通用", systemImage: "gearshape") }
            ModelsTab(model: model).tabItem { Label("模型", systemImage: "cpu") }
            DiagnosticsTab(model: model).tabItem { Label("诊断", systemImage: "stethoscope") }
        }
        .padding(16)
        .frame(width: 640, height: 520)
        .task { await model.reload() }
    }
}

struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("唤起面板的快捷键") {
                HStack {
                    Text(model.recording ? "请按下组合键…" : model.hotkeyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 140, alignment: .leading)
                    TrackedButton(model.recording ? "取消" : "录制", tracker: model.tracker, key: "settings.hotkey.toggle_recording",
                                  name: "settings.hotkey.toggle_recording") { toggleRecording() }
                    TrackedButton("清除", tracker: model.tracker, key: "settings.hotkey.clear", name: "settings.hotkey.clear") { try await model.clearHotkey() }
                        .disabled(model.hotkeyText == "未设置")
                }
                if let e = model.hotkeyError ?? model.tracker.message("settings.hotkey.record") { Text(e).foregroundStyle(.red).font(.caption) }
                Text("默认 ⌥空格；清除后可点击菜单栏图标打开面板。").font(.caption).foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("登录时启动 ClipVault", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text(model.tracker.message("settings.login_item") ?? model.loginItemStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("不记录这些 App 的复制（Bundle ID）") {
                ForEach(model.excluded, id: \.self) { id in
                    HStack {
                        Text(id); Spacer()
                        TrackedButton("移除", tracker: model.tracker, key: "settings.excluded.remove.\(id)", name: "settings.excluded.remove", detail: id) {
                            try await model.removeExcluded(id)
                        }
                    }
                }
                HStack {
                    TextField("例如 com.apple.keychainaccess", text: $model.newExcluded)
                    Menu("从运行中的 App 选择") {
                        ForEach(runningApps, id: \.0) { app in
                            TrackedButton(app.1, tracker: model.tracker, key: "settings.excluded.add", name: "settings.excluded.add_running", detail: app.0) {
                                try await model.addExcluded(app.0)
                            }
                        }
                    }
                    TrackedButton("添加", tracker: model.tracker, key: "settings.excluded.add", name: "settings.excluded.add") {
                        try await model.addExcluded(model.newExcluded); model.newExcluded = ""
                    }
                }
                if let e = model.tracker.message("settings.excluded.add") { Text(e).foregroundStyle(.red).font(.caption) }
                Text("密码管理器标记为「隐藏/临时」的内容始终不记录。").font(.caption).foregroundStyle(.secondary)
            }
            Section("历史数据") {
                Text(model.stats)
                Text("数据位置：\(model.rt.home.root.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TrackedButton("清空全部历史…", tracker: model.tracker, key: "settings.clear.ask", name: "settings.clear.ask", role: .destructive) {
                    model.confirmClear = true
                }
                if let e = model.tracker.message("settings.clear") { Text("清空没有完成，数据未改动。" + e).foregroundStyle(.red).font(.caption) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清空全部剪贴板历史？", isPresented: $model.confirmClear) {
            TrackedButton("全部清除（包括置顶）", tracker: model.tracker, key: "settings.clear", name: "settings.clear", role: .destructive) {
                try await model.clearAll()
            }
        } message: {
            Text("所有条目、图片、识别文字和向量都会被永久删除，包括置顶条目。此操作无法撤销。")
        }
        .onDisappear { stopRecording() }
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { ($0, "\(a.localizedName ?? $0) (\($0))") } }
            .sorted { $0.1 < $1.1 }
    }

    private func toggleRecording() {
        if model.recording { stopRecording(); model.recording = false; return }
        model.recording = true
        model.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {   // bare Esc cancels
                model.recording = false
            } else {
                model.record(e)
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = model.keyMonitor { NSEvent.removeMonitor(m) }
        model.keyMonitor = nil
    }
}

struct ModelsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("本机") {
                Text("\(HardwareProbe.cpuBrand) · \(model.memoryGB) GB 内存")
            }
            slotSection(.image, title: "图片搜索模型（用文字描述找图片）")
            slotSection(.text, title: "文本语义模型（按意思找历史文本，中英互通）")
            slotSection(.similar, title: "相似图片（图片详情下方的相似图片）")
            Section("向量数据") {
                HStack {
                    TrackedButton("清理未启用模型的向量…", tracker: model.tracker, key: "settings.purge.preview", name: "settings.purge.preview") {
                        try await model.purgePreview()
                    }
                    Spacer()
                }
                Text("切换模型不会删除旧向量，切回时无需重算。自定义模型可写入 models/custom.json。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("清理未启用模型的向量", isPresented: $model.confirmPurge) {
            TrackedButton("清理", tracker: model.tracker, key: "settings.purge", name: "settings.purge", role: .destructive) { try await model.purgeConfirm() }
            TrackedButton("取消", tracker: model.tracker, key: "settings.purge.cancel", name: "settings.purge.cancel", role: .cancel) {}
        } message: { Text(model.purgeInfo ?? "正在统计…") }
    }

    @ViewBuilder private func slotSection(_ slot: ModelSlot, title: String) -> some View {
        Section(title) {
            // 3.4 §2: show the slot state, intermediate states included.
            switch model.slotStates[slot] ?? .inactive {
            case .activating(let target, let previous):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在启用 \(target)…" + (previous.map { "（搜索暂时继续使用 \($0)）" } ?? ""))
                }
            case .failed(let target, let error, let previous):
                Text("启用 \(target) 失败：\(error)" + (previous.map { "；仍在使用 \($0)" } ?? "")).foregroundStyle(.red).font(.caption)
            default:
                if let a = model.active[slot], let c = model.coverage[slot] {
                    let noun = slot == .image ? "张图片" : "条文本"
                    Text("当前启用：\(a) · 已建索引 \(c.indexed)/\(c.images) \(noun)" + (c.pending > 0 ? "（进行中 \(c.pending)）" : "") + (c.failed > 0 ? " · 失败 \(c.failed)" : ""))
                } else if slot == .similar {
                    // FR26: no dedicated model → similar images use the image-search model's vectors.
                    Text(model.active[.image].map { "跟随图片搜索模型（当前：\($0)）" } ?? "跟随图片搜索模型（当前未启用，相似图片不可用）")
                        .foregroundStyle(.secondary)
                } else {
                    Text(slot == .image ? "未启用：图片只能按图中文字搜索" : "未启用：文本只能按关键词搜索").foregroundStyle(.secondary)
                }
            }
            if let e = model.tracker.message("settings.model.activate.\(slot.rawValue)") ?? model.tracker.message("settings.model.deactivate.\(slot.rawValue)") {
                Text(e).foregroundStyle(.red).font(.caption)
            }
            if ModelSlot.searchable.contains(slot), let id = model.active[slot], let m = model.catalog.first(where: { $0.id == id }) { thresholdEditor(m) }
            ForEach(model.catalog.filter { $0.slot == slot }) { m in row(m) }
        }
    }

    @ViewBuilder private func row(_ m: ModelManifest) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.displayName)
                    if m.id == model.recommendedID(m.slot) { Text("推荐").font(.caption2).padding(.horizontal, 4).background(.tint.opacity(0.2), in: Capsule()) }
                    if m.id == model.active[m.slot] { Text("已启用").font(.caption2).padding(.horizontal, 4).background(.green.opacity(0.25), in: Capsule()) }
                }
                Text(subtitle(m)).font(.caption).foregroundStyle(.secondary)
                if let e = model.tracker.message(SettingsModel.installKey(m)) ?? model.tracker.message("settings.model.remove.\(m.id)") {
                    Text(e).font(.caption).foregroundStyle(e == "已取消" ? Color.secondary : Color.red)
                }
            }
            Spacer()
            if let p = model.installing[m.id] {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: p.fraction).frame(width: 140)
                    Text(Self.progressText(p)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                TrackedButton("取消", tracker: model.tracker, key: "settings.model.cancel_install.\(m.id)", name: "settings.model.cancel_install", detail: m.id) {
                    model.tracker.cancel(SettingsModel.installKey(m))
                }
            } else if !m.isSupportedFamily {
                Text("不支持").foregroundStyle(.secondary)
            } else if !model.installed(m) {
                TrackedButton("下载", tracker: model.tracker, key: SettingsModel.installKey(m), name: "settings.model.install", detail: m.id, timeout: nil) {
                    try await model.install(m)
                }
            } else if m.id == model.active[m.slot] {
                TrackedButton("停用", tracker: model.tracker, key: "settings.model.deactivate.\(m.slot.rawValue)", name: "settings.model.deactivate",
                              detail: m.id, timeout: ActionTimeouts.model) { try await model.deactivate(m.slot) }
                    .disabled(model.slotBusy(m.slot))
            } else {
                TrackedButton("启用", tracker: model.tracker, key: "settings.model.activate.\(m.slot.rawValue)", name: "settings.model.activate",
                              detail: m.id, timeout: ActionTimeouts.model) { try await model.activate(m) }
                    .disabled(model.slotBusy(m.slot))
                if m.requiresInstall {
                    TrackedButton("删除文件", tracker: model.tracker, key: "settings.model.remove.\(m.id)", name: "settings.model.remove", detail: m.id) {
                        try await model.remove(m)
                    }
                    .disabled(model.slotBusy(m.slot))
                }
            }
        }
    }

    /// FR24: how strict semantic matches are for the active model (H5 relative filter).
    @ViewBuilder private func thresholdEditor(_ m: ModelManifest) -> some View {
        let id = m.id
        // Full valid ranges (cosine similarity); exact values can be typed in the fields.
        let floorRange = -1.0...1.0
        let marginRange = 0.0...1.0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("相似度下限").frame(width: 120, alignment: .leading)
                Slider(value: Binding(get: { model.floorDraft[id] ?? Double(m.floor) }, set: { model.floorDraft[id] = $0 }),
                       in: floorRange, step: 0.005) { editing in if !editing { save(id) } }
                numberField(Binding(get: { model.floorDraft[id] ?? Double(m.floor) }, set: { model.floorDraft[id] = min(1, max(-1, $0)) })) { save(id) }
            }
            HStack {
                Text("与最佳结果最大差距").frame(width: 120, alignment: .leading)
                Slider(value: Binding(get: { model.marginDraft[id] ?? Double(m.margin) }, set: { model.marginDraft[id] = $0 }),
                       in: marginRange, step: 0.002) { editing in if !editing { save(id) } }
                numberField(Binding(get: { model.marginDraft[id] ?? Double(m.margin) }, set: { model.marginDraft[id] = min(1, max(0, $0)) })) { save(id) }
            }
            HStack {
                Text("默认 下限 \(String(format: "%.3f", m.floor)) · 差距 \(String(format: "%.3f", m.margin))。下限越低、差距越大，返回的语义结果越多（也越可能不相关）。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.thresholds[id]?.isDefault == false {
                    TrackedButton("恢复默认", tracker: model.tracker, key: "settings.model.thresholds.reset.\(id)", name: "settings.model.thresholds.reset", detail: id) {
                        try await model.resetThresholds(id)
                    }
                }
            }
            if let e = model.tracker.message("settings.model.thresholds.\(id)") { Text(e).foregroundStyle(.red).font(.caption) }
        }
    }

    private func numberField(_ value: Binding<Double>, onCommit: @escaping () -> Void) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(3)))
            .monospacedDigit().multilineTextAlignment(.trailing).frame(width: 64)
            .onSubmit(onCommit)
    }

    private func save(_ id: String) {
        model.tracker.perform(key: "settings.model.thresholds.\(id)", name: "settings.model.thresholds", detail: id) { try await model.saveThresholds(id) }
    }

    static func progressText(_ p: InstallProgress) -> String {
        let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_048_576) }
        switch p.phase {
        case .downloading: return String(format: "下载中 %.0f%% · ", p.fraction * 100) + "\(mb(p.bytesDone)) / \(mb(p.bytesTotal)) MB"
        case .verifying: return "校验中…"
        case .compiling: return "编译模型中…"
        case .done: return "完成"
        }
    }

    private func subtitle(_ m: ModelManifest) -> String {
        var parts: [String] = [m.id]
        parts.append(m.requiresInstall ? String(format: "%.0f MB", Double(m.downloadBytes) / 1_048_576) : "系统内置")
        if m.slot == .image { parts.append(m.supportsTextQueries ? (m.isMultilingual ? "中英文搜图" : "英文搜图") : "仅以图搜图") }
        else { parts.append(m.isMultilingual ? "中英文" : "单语言") }
        if m.minMemoryGB > 0 { parts.append("建议 ≥\(m.minMemoryGB) GB") }
        if let n = model.vectorCounts[m.id] { parts.append("已有向量 \(n)") }
        return parts.joined(separator: " · ")
    }
}

struct DiagnosticsTab: View {
    @Bindable var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TrackedButton("运行诊断", tracker: model.tracker, key: "settings.diagnose", name: "settings.diagnose") { await model.runDiagnostics() }
                TrackedButton("导出日志…", tracker: model.tracker, key: "settings.export_logs", name: "settings.export_logs", timeout: nil) {
                    try await model.exportLogs()
                }
                Spacer()
                Text("命令行：ClipVault --diagnose").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(model.diagnostics.isEmpty ? "点击「运行诊断」。诊断只读，不修改任何数据。" : model.diagnostics)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
        .onAppear {
            if model.diagnostics.isEmpty {
                model.tracker.perform(key: "settings.diagnose", name: "settings.diagnose.auto") { await model.runDiagnostics() }
            }
        }
    }
}
