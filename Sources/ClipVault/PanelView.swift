import AppKit
import ClipCore
import ClipPlatform
import SwiftUI

/// Bounded thumbnail cache (memory only; decoding is downsampled, E7).
/// Views read `version`, so they re-render when a thumbnail finishes loading.
/// (No @State: on SDK 27 it is a macro whose plugin ships only with Xcode — lessons L2.)
@MainActor @Observable
final class Thumbnails {
    static let shared = Thumbnails()
    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var inFlight: Set<String> = []
    private(set) var version = 0
    init() { cache.countLimit = 400 }

    func image(hash: String, url: URL, maxPixel: Int) -> NSImage? {
        _ = version
        let key = "\(hash)@\(maxPixel)"
        if let img = cache.object(forKey: key as NSString) { return img }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        Task {
            let cg = await Task.detached(priority: .userInitiated) { ImageInfo.cgImage(at: url, maxPixel: maxPixel) }.value
            inFlight.remove(key)
            if let cg { cache.setObject(NSImage(cgImage: cg, size: .zero), forKey: key as NSString); version += 1 }
        }
        return nil
    }
}

struct ThumbnailView: View {
    let hash: String
    let url: URL
    let maxPixel: Int
    var body: some View {
        if let img = Thumbnails.shared.image(hash: hash, url: url, maxPixel: maxPixel) {
            // A thin border so light / borderless images keep a visible edge.
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}

struct PanelView: View {
    @Bindable var model: PanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(minWidth: 340, idealWidth: 380)
                Divider()
                PreviewPane(model: model).frame(minWidth: 300, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 440)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { _, _ in
            // Next runloop turn: the panel has just become key.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            model.pasteSelected(commandHeld: press.modifiers.contains(.command)); return .handled
        }
        .onKeyPress(.escape) { model.onClose?(); return .handled }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文字、图片中的文字，或描述图片内容（如：海边、代码截图）", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                    .onSubmit { model.copySelected(via: "enter") }
                if model.phase == .searching { ProgressView().controlSize(.small) }
                TrackedButton(tracker: model.tracker, key: "panel.open_settings", name: "panel.open_settings", action: { model.onOpenSettings?() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                    .help("设置（快捷键、模型、排除的 App）")
            }
            HStack {
                Picker("", selection: $model.kind) {
                    Text("全部").tag(KindFilter.all)
                    Text("文本").tag(KindFilter.text)
                    Text("图片").tag(KindFilter.image)
                    Text("文件").tag(KindFilter.file)
                    Text("链接").tag(KindFilter.url)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
                if let ms = model.lastElapsedMs, model.phase == .results {
                    Text("\(model.rows.count) 条 · \(String(format: "%.0f", ms)) ms").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note = model.semanticNote {
                Text(note).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.newContentWhileSearching {
                TrackedButton("有新内容，点击刷新", tracker: model.tracker, key: "panel.refresh", name: "panel.refresh") { model.refresh() }
                    .buttonStyle(.link).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(model.rows) { row in
                    RowView(row: row, service: model.service)
                        .overlay {
                            if model.revealed == row.id {
                                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(-3)
                            }
                        }
                        .animation(.easeOut(duration: 0.25), value: model.revealed)
                        .tag(row.id)
                        .onAppear { model.loadMoreIfNeeded(current: row) }
                        .contextMenu {
                            TrackedButton("复制", tracker: model.tracker, key: "panel.menu.copy", name: "panel.menu.copy") {
                                model.selection = row.id; model.copySelected(via: "menu")
                            }
                            TrackedButton(row.item.pinned ? "取消置顶" : "置顶", tracker: model.tracker, key: "panel.menu.pin", name: "panel.menu.pin") {
                                model.selection = row.id; model.togglePinSelected(via: "menu")
                            }
                            Divider()
                            TrackedButton("删除", tracker: model.tracker, key: "panel.menu.delete", name: "panel.menu.delete", role: .destructive) {
                                model.selection = row.id; model.deleteSelected(via: "menu")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.rows.isEmpty { emptyState }
            }
            .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
            .onChange(of: model.scrollRequest?.token) { _, _ in
                if let id = model.scrollRequest?.id { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onTapGesture(count: 2) { model.copySelected(via: "double_click") }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.phase {
        case .failed(let e): Text("出错：\(e)").foregroundStyle(.red).padding()
        case .searching: EmptyView()
        case .results: Text("没有匹配的内容").foregroundStyle(.secondary)
        case .browsing: Text("还没有剪贴板历史。复制点什么试试。").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(model.pasteReady ? "↩ 粘贴 · ⌘↩ 只复制" : "↩ 复制").foregroundStyle(.secondary)
                .help(model.pasteReady ? "粘贴到打开面板前的光标处" : "开启「辅助功能」权限后，回车可直接粘贴到原光标处")
            Text("⌘⌫ 删除").foregroundStyle(.secondary)
            Text("⌘P 置顶").foregroundStyle(.secondary)
            Text("esc 关闭").foregroundStyle(.secondary)
            Spacer()
            if let n = model.notice { Text(n).foregroundStyle(.red).lineLimit(1) }
            if let hk = model.hotkeyDisplay {
                Text("唤起：\(hk)").foregroundStyle(.secondary)
            } else {
                TrackedButton("设置快捷键…", tracker: model.tracker, key: "panel.set_hotkey", name: "panel.set_hotkey") { model.onOpenSettings?() }
                    .buttonStyle(.link)
            }
            TrackedButton("删除", tracker: model.tracker, key: "panel.key.delete", name: "panel.key.delete") { model.deleteSelected(via: "shortcut") }
                .keyboardShortcut(.delete, modifiers: .command).hidden()
            TrackedButton("置顶", tracker: model.tracker, key: "panel.key.pin", name: "panel.key.pin") { model.togglePinSelected(via: "shortcut") }
                .keyboardShortcut("p", modifiers: .command).hidden()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct RowView: View {
    let row: PanelModel.Row
    let service: ClipService

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2).font(.system(size: 13))
                HStack(spacing: 6) {
                    if row.item.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                    Text(meta).foregroundStyle(.secondary)
                    ForEach(row.sources.sorted { $0.rawValue < $1.rawValue }, id: \.self) { s in
                        Text(badge(s)).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch row.item.kind {
        case .image:
            if let h = row.item.blobHash { ThumbnailView(hash: h, url: service.blobURL(h), maxPixel: 96) }
        case .file: Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
        case .url: Image(systemName: "link").font(.title2).foregroundStyle(.secondary)
        case .rich: Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)
        case .text: Image(systemName: "text.alignleft").font(.title2).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if row.item.kind == .image {
            if let o = row.item.ocrPreview, !DisplayText.singleLine(o).isEmpty { return DisplayText.singleLine(o) }
            return "图片 \(row.item.width ?? 0)×\(row.item.height ?? 0)"
        }
        return DisplayText.singleLine(row.item.preview ?? "")
    }

    private var meta: String {
        let date = Date(timeIntervalSince1970: Double(row.item.lastUsedAt) / 1000)
        var parts = [date.formatted(.relative(presentation: .named))]
        if let s = row.item.sourceName { parts.append(s) }
        if row.item.useCount > 1 { parts.append("×\(row.item.useCount)") }
        return parts.joined(separator: " · ")
    }

    private func badge(_ s: MatchSource) -> String {
        switch s {
        case .text: "文字"
        case .ocr: "图中文字"
        case .semantic: row.similarity.map { String(format: "语义 %.2f", $0) } ?? "语义"
        }
    }
}

struct PreviewPane: View {
    let model: PanelModel
    private var detail: ItemDetail? { model.detail?.id == model.selectedRow?.id ? model.detail : nil }

    var body: some View {
        ScrollView {
            if let row = model.selectedRow {
                VStack(alignment: .leading, spacing: 10) {
                    if row.item.kind == .image, let h = row.item.blobHash {
                        ThumbnailView(hash: h, url: model.service.blobURL(h), maxPixel: 900)
                            .frame(maxWidth: .infinity, maxHeight: 320)
                        SimilarStrip(model: model)
                    } else {
                        // Bounded: very large texts show a prefix (full text is still copied).
                        let body = String((detail?.text ?? row.item.preview ?? "").prefix(20_000))
                        // Plain text normally; while ⌘ is held, links / existing file paths become blue and clickable.
                        Text(model.commandDown ? (row.item.kind == .file ? Self.fileLinked(body) : Self.linkified(body)) : AttributedString(body))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if row.item.kind == .file {
                            let files = FileItemPaths.resolve(text: body)
                            if !files.missing.isEmpty {
                                Text(files.existing.isEmpty ? "文件已不存在（可能已被移动或删除）" : "\(files.missing.count) 个文件已不存在")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let ocr = detail?.ocrText, !ocr.isEmpty {
                        Divider()
                        Text("图中文字").font(.caption).foregroundStyle(.secondary)
                        Text(ocr).font(.system(size: 12)).textSelection(.enabled)
                    }
                    if let labels = detail?.labels, !labels.isEmpty {
                        Text("识别标签：\(labels)").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(info(row.item)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .task(id: row.id) { await model.loadDetail(id: row.id) }
                // FR21: clicked links open in the default browser and the panel gets out of the way.
                // FR21 / FR22: only ⌘-click opens; a plain click just places the text cursor / selection.
                .environment(\.openURL, OpenURLAction { url in
                    guard NSEvent.modifierFlags.contains(.command) else { return .handled }
                    if url.isFileURL {
                        guard FileManager.default.fileExists(atPath: url.path) else { return .handled }
                        model.revealInFinder([url])
                    } else {
                        guard LinkDetector.safeURL(url.absoluteString) != nil else { return .discarded }
                        model.openLink(url)
                    }
                    return .handled
                })
            }
        }
    }

    /// Web / mail links in the text become clickable (LinkDetector decides which schemes are allowed).
    static func linkified(_ text: String) -> AttributedString {
        let links = LinkDetector.links(in: text)
        guard !links.isEmpty else { return AttributedString(text) }
        let ns = NSMutableAttributedString(string: text)
        for l in links { ns.addAttribute(.link, value: l.url, range: NSRange(l.range, in: text)) }
        return AttributedString(ns)
    }

    /// File items: each existing path becomes a file:// link (⌘-click reveals it in Finder).
    static func fileLinked(_ text: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: text)
        var location = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let path = line.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                ns.addAttribute(.link, value: URL(fileURLWithPath: path), range: NSRange(location: location, length: length))
            }
            location += length + 1
        }
        return AttributedString(ns)
    }

    private func info(_ s: ItemSummary) -> String {
        let created = Date(timeIntervalSince1970: Double(s.createdAt) / 1000).formatted(date: .abbreviated, time: .standard)
        let size = ByteCountFormatter.string(fromByteCount: Int64(s.byteSize), countStyle: .file)
        return "首次复制 \(created) · 使用 \(s.useCount) 次 · \(size)" + (s.sourceName.map { " · 来自 \($0)" } ?? "")
    }
}

/// Similar images under the detail image. Clicking reveals the row in the list without selecting it.
struct SimilarStrip: View {
    let model: PanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.similar.isEmpty {
                Text("相似图片（点击定位到列表）").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.similar) { row in
                            if let h = row.item.blobHash {
                                ThumbnailView(hash: h, url: model.service.blobURL(h), maxPixel: 160)
                                    .frame(width: 72, height: 72)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.tracker.perform(key: "panel.similar.reveal", name: "panel.similar.reveal", detail: String(row.id)) { model.reveal(row.id) }
                                    }
                                    .help(row.similarity.map { String(format: "相似度 %.2f", $0) } ?? "")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack(spacing: 8) {
                if let note = model.revealNote ?? model.similarNote {
                    if model.indexStatus == .queued || model.indexStatus == .running { ProgressView().controlSize(.mini) }
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if case .failed = model.indexStatus {
                    TrackedButton("重试", tracker: model.tracker, key: "panel.index.retry", name: "panel.index.retry.button") { model.retryIndex() }
                        .font(.caption)
                }
            }
        }
    }
}
