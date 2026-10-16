import AppKit
import ClipCore
import ClipPlatform
import SwiftUI

@MainActor @Observable
final class SettingsModel {
    let rt: Runtime
    let installer: ModelInstaller
    var hotkeyText = "未设置"
    var hotkeyError: String?
    var recording = false
    var excluded: [String] = []
    var stats = ""
    var active: String?
    var coverage: SemanticCoverage?
    var vectorCounts: [String: Int] = [:]
    var installing: [String: Double] = [:]
    var modelError: String?
    var diagnostics = ""
    var diagnosing = false
    var purgeInfo: String?
    var newExcluded = ""
    var confirmClear = false
    var confirmPurge = false
    @ObservationIgnored var keyMonitor: Any?
    var onHotkeyChanged: ((HotKeyCombo?) -> Bool)?
    var probes: () async -> PlatformProbes = { .unavailable }

    init(rt: Runtime) {
        self.rt = rt
        installer = ModelInstaller(home: rt.home)
    }

    var catalog: [ModelManifest] { rt.service.catalog.models }
    var memoryGB: Int { HardwareProbe.memoryGB }
    var recommendedID: String? { rt.service.catalog.recommended(memoryGB: memoryGB)?.id }
    func installed(_ m: ModelManifest) -> Bool { ModelPaths.isInstalled(home: rt.home, model: m) }

    func reload() async {
        let stored = try? await rt.db.setting(SettingKey.hotkey)
        if let h = HotKeyCombo.resolve(setting: stored) { hotkeyText = h.display + (stored == nil ? "（默认）" : "") } else { hotkeyText = "未设置" }
        excluded = await rt.service.excludedApps()
        if let c = try? await rt.service.counts() {
            stats = "\(c.items) 条历史（图片 \(c.images)） · 图片占用 \(ByteCountFormatter.string(fromByteCount: rt.blobs.totalBytes(), countStyle: .file))"
        }
        active = await rt.service.activeModelManifest()?.id
        if let active { coverage = try? await rt.service.coverage(modelID: active) } else { coverage = nil }
        vectorCounts = (try? await rt.service.embeddingCounts()) ?? [:]
        modelError = await rt.service.activationError
    }

    // MARK: Hotkey (Q6: empty by default; user records their own)

    func record(_ event: NSEvent) {
        recording = false
        guard let combo = HotKeyCombo(event: event) else { hotkeyError = "需要包含 ⌘、⌥ 或 ⌃"; return }
        if onHotkeyChanged?(combo) == false { hotkeyError = "\(combo.display) 已被系统或其他 App 占用"; return }
        hotkeyError = nil
        Task { try? await rt.db.setSetting(SettingKey.hotkey, combo.setting); await reload() }
    }

    func clearHotkey() {
        _ = onHotkeyChanged?(nil)
        hotkeyError = nil
        Task { try? await rt.db.setSetting(SettingKey.hotkey, HotKeyCombo.clearedSetting); await reload() }
    }

    // MARK: Excluded apps

    func addExcluded(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !excluded.contains(id) else { return }
        Task { try? await rt.service.setExcludedApps(excluded + [id]); await reload() }
    }

    func removeExcluded(_ id: String) {
        Task { try? await rt.service.setExcludedApps(excluded.filter { $0 != id }); await reload() }
    }

    // MARK: Models

    func install(_ m: ModelManifest) {
        installing[m.id] = 0
        modelError = nil
        Task {
            do {
                try await installer.install(m) { p in
                    Task { @MainActor in self.installing[m.id] = Double(p.bytesDone) / Double(max(p.bytesTotal, 1)) }
                }
            } catch { modelError = "安装 \(m.displayName) 失败：\(error)" }
            installing[m.id] = nil
            await reload()
        }
    }

    func activate(_ m: ModelManifest) {
        Task {
            do { try await rt.service.activateModel(id: m.id) } catch { modelError = "启用失败：\(error)" }
            await reload()
        }
    }

    func deactivate() {
        Task { try? await rt.service.deactivateModel(); await reload() }
    }

    func remove(_ m: ModelManifest) {
        Task {
            if active == m.id { try? await rt.service.deactivateModel() }
            try? await installer.remove(m.id)
            await reload()
        }
    }

    func purgePreview() {
        Task {
            let r = try? await Maintenance.purgeInactive(rt, scope: .dryRun)
            let total = r?.byModel.values.reduce(0, +) ?? 0
            purgeInfo = total == 0 ? "没有未激活模型的向量" : "将删除 \(total) 条未激活模型的向量：" + (r?.byModel.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "，") ?? "")
        }
    }

    func purgeConfirm() {
        Task { _ = try? await Maintenance.purgeInactive(rt, scope: .all); purgeInfo = "已清理"; await reload() }
    }

    // MARK: Diagnostics / data

    func runDiagnostics() {
        diagnosing = true
        Task {
            let report = await Diagnostics.run(rt, probes: await probes())
            diagnostics = report.rendered
            diagnosing = false
        }
    }

    func exportLogs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let dest = dir.appendingPathComponent("ClipVault-logs-\(Int(Date().timeIntervalSince1970))")
        if let files = try? Log.shared.export(to: dest) {
            diagnostics += "\n\n已导出 \(files.count) 个日志文件到 \(dest.path)（日志不包含剪贴板内容）"
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
    }

    func clearAll() {
        Task { try? await rt.service.clearAll(); await reload() }
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
                    Button(model.recording ? "取消" : "录制") { toggleRecording() }
                    Button("清除") { model.clearHotkey() }.disabled(model.hotkeyText == "未设置")
                }
                if let e = model.hotkeyError { Text(e).foregroundStyle(.red).font(.caption) }
                Text("默认 ⌥空格；清除后可点击菜单栏图标打开面板。").font(.caption).foregroundStyle(.secondary)
            }
            Section("不记录这些 App 的复制（Bundle ID）") {
                ForEach(model.excluded, id: \.self) { id in
                    HStack { Text(id); Spacer(); Button("移除") { model.removeExcluded(id) } }
                }
                HStack {
                    TextField("例如 com.apple.keychainaccess", text: $model.newExcluded)
                    Menu("从运行中的 App 选择") {
                        ForEach(runningApps, id: \.0) { app in Button(app.1) { model.addExcluded(app.0) } }
                    }
                    Button("添加") { model.addExcluded(model.newExcluded); model.newExcluded = "" }
                }
                Text("密码管理器标记为「隐藏/临时」的内容始终不记录。").font(.caption).foregroundStyle(.secondary)
            }
            Section("历史数据") {
                Text(model.stats)
                Text("数据位置：\(model.rt.home.root.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("清空全部历史…", role: .destructive) { model.confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清空全部剪贴板历史？", isPresented: $model.confirmClear) {
            Button("全部清除（包括置顶）", role: .destructive) { model.clearAll() }
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
                if let rec = model.recommendedID { Text("推荐模型：\(rec)").foregroundStyle(.secondary) }
                if let a = model.active, let c = model.coverage {
                    Text("当前启用：\(a) · 已建语义索引 \(c.indexed)/\(c.images) 张图片" + (c.pending > 0 ? "（进行中 \(c.pending)）" : "") + (c.failed > 0 ? " · 失败 \(c.failed)" : ""))
                } else {
                    Text("语义搜图未启用（文字与图中文字搜索不受影响）").foregroundStyle(.secondary)
                }
                if let e = model.modelError { Text(e).foregroundStyle(.red).font(.caption) }
            }
            Section("可用模型（下载后完全离线运行）") {
                ForEach(model.catalog) { m in row(m) }
            }
            Section("向量数据") {
                HStack {
                    Button("清理未启用模型的向量…") { model.purgePreview(); model.confirmPurge = true }
                    Spacer()
                }
                Text("切换模型不会删除旧向量，切回时无需重算。自定义模型可写入 models/custom.json。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("清理未启用模型的向量", isPresented: $model.confirmPurge) {
            Button("清理", role: .destructive) { model.purgeConfirm() }
            Button("取消", role: .cancel) {}
        } message: { Text(model.purgeInfo ?? "正在统计…") }
    }

    @ViewBuilder private func row(_ m: ModelManifest) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.displayName)
                    if m.id == model.recommendedID { Text("推荐").font(.caption2).padding(.horizontal, 4).background(.tint.opacity(0.2), in: Capsule()) }
                    if m.id == model.active { Text("已启用").font(.caption2).padding(.horizontal, 4).background(.green.opacity(0.25), in: Capsule()) }
                }
                Text(subtitle(m)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = model.installing[m.id] {
                ProgressView(value: p).frame(width: 120)
            } else if !m.isSupportedFamily {
                Text("不支持").foregroundStyle(.secondary)
            } else if !model.installed(m) {
                Button("下载") { model.install(m) }
            } else if m.id == model.active {
                Button("停用") { model.deactivate() }
            } else {
                Button("启用") { model.activate(m) }
                if m.requiresInstall { Button("删除文件") { model.remove(m) } }
            }
        }
    }

    private func subtitle(_ m: ModelManifest) -> String {
        var parts: [String] = [m.id]
        parts.append(m.requiresInstall ? String(format: "%.0f MB", Double(m.downloadBytes) / 1_048_576) : "系统内置")
        parts.append(m.supportsTextQueries ? "以文搜图" : "仅以图搜图")
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
                Button("运行诊断") { model.runDiagnostics() }.disabled(model.diagnosing)
                Button("导出日志…") { model.exportLogs() }
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
        .onAppear { if model.diagnostics.isEmpty { model.runDiagnostics() } }
    }
}
