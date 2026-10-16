import AppKit
import ClipCore
import ClipPlatform
import Observation

/// UI state for the history panel (state-model 4.3). Reads only committed data via ClipService.
@MainActor @Observable
final class PanelModel {
    enum Phase: Equatable { case browsing, searching, results, failed(String) }

    struct Row: Identifiable, Equatable {
        let item: ItemSummary
        let sources: Set<MatchSource>
        let similarity: Float?
        var id: Int64 { item.id }
    }

    let service: ClipService
    let home: AppHome
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    var kind: KindFilter = .all { didSet { if kind != oldValue { refresh() } } }
    private(set) var rows: [Row] = []
    private(set) var phase: Phase = .browsing
    var selection: Int64?
    private(set) var semanticNote: String?
    private(set) var newContentWhileSearching = false
    private(set) var lastElapsedMs: Double?
    private(set) var reachedEnd = false
    private(set) var detail: ItemDetail?

    func loadDetail(id: Int64) async {
        let d = try? await service.detail(id: id)
        guard selectedRow?.id == id else { return }
        detail = d
        similar = []
        similarNote = nil
        revealNote = nil
        indexStatus = nil
        guard d?.summary.kind == .image else { return }
        // FR25: say exactly where this image is in the index state machine (3.4 §3).
        let status = await service.imageIndexStatus(itemID: id)
        guard selectedRow?.id == id else { return }         // selection moved on: drop the stale result
        indexStatus = status
        switch status {
        case .indexed:
            let r = await service.similarImages(to: id, limit: 8)
            guard selectedRow?.id == id else { return }
            similar = r.hits.map { Row(item: $0.item, sources: $0.sources, similarity: $0.similarity) }
            similarNote = similar.isEmpty ? "没有相似图片" : nil
        case .noModel: similarNote = "启用图片搜索模型后可显示相似图片"
        case .slotBusy(let target): similarNote = "正在启用 \(target)…"
        case .queued: similarNote = "正在排队建立索引…"
        case .running: similarNote = "正在建立索引…"
        case .failed(let e): similarNote = "建立索引失败：\(e)"
        case .missing: similarNote = "尚未建立索引，已加入队列"
        }
    }

    /// Index status of the selected image (FR25), nil for non-images.
    private(set) var indexStatus: ImageIndexStatus?

    func retryIndex() {
        guard let row = selectedRow else { return }
        tracker.perform(key: "panel.index.retry", name: "panel.index.retry", detail: String(row.id)) { [self] in
            try await service.retryImageIndex(itemID: row.id)
            await loadDetail(id: row.id)
        }
    }

    // MARK: Similar images → reveal in list (scroll + highlight, without selecting)

    private(set) var similar: [Row] = []
    private(set) var similarNote: String?
    /// Row briefly highlighted after a similar-image thumbnail is clicked. Not the selection.
    private(set) var revealed: Int64?
    /// Bumped on every reveal so the list scrolls even when revealing the same row twice.
    private(set) var scrollRequest: (id: Int64, token: Int)?
    private(set) var revealNote: String?
    private var revealToken = 0

    func reveal(_ id: Int64) {
        revealNote = nil
        Task {
            if !rows.contains(where: { $0.id == id }) { await loadPages(until: id) }
            guard rows.contains(where: { $0.id == id }) else {
                revealNote = phase == .browsing ? "这张图片太早了，不在已加载的列表中（最多 \(Self.maxRowsInMemory) 条）" : "这张图片不在当前搜索结果中"
                return
            }
            revealToken += 1
            let token = revealToken
            scrollRequest = (id, token)
            revealed = id
            try? await Task.sleep(for: .seconds(1.6))
            if revealToken == token { revealed = nil }
        }
    }

    /// Browsing only: keep paging (bounded by H6) until `id` is loaded.
    private func loadPages(until id: Int64) async {
        while phase == .browsing, !reachedEnd, rows.count < Self.maxRowsInMemory, !rows.contains(where: { $0.id == id }), let last = rows.last {
            let gateID = gate.next()
            let page = (try? await service.page(after: PageCursor(last.item), kind: kind, limit: Self.pageSize)) ?? []
            guard gate.accepts(gateID) else { return }
            rows = RowWindow.append(page.map { Row(item: $0, sources: [], similarity: nil) }, to: rows, cap: Self.maxRowsInMemory)
            reachedEnd = page.count < Self.pageSize || rows.count >= Self.maxRowsInMemory
        }
    }

    static let pageSize = 60          // H6
    static let maxRowsInMemory = 600  // H6 / C36

    private var gate = LatestOnly()
    private var debounce: Task<Void, Never>?
    var onClose: (() -> Void)?
    var onCopied: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Display string of the registered hotkey; nil = none set (Q6 default).
    var hotkeyDisplay: String?

    let tracker: ActionTracker

    init(service: ClipService, home: AppHome, tracker: ActionTracker) {
        self.service = service
        self.home = home
        self.tracker = tracker
    }

    /// Failure / timeout text of the panel's own actions (FR23), shown in the footer.
    var notice: String? {
        ["panel.copy", "panel.delete", "panel.pin"].lazy.compactMap { self.tracker.message($0) }.first
    }

    var selectedRow: Row? { rows.first { $0.id == selection } ?? rows.first }

    func refresh() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { loadFirstPage() } else { scheduleSearch(immediate: true) }
    }

    func loadFirstPage() {
        let id = gate.next()
        newContentWhileSearching = false
        Task {
            do {
                let page = try await service.page(after: nil, kind: kind, limit: Self.pageSize)
                guard gate.accepts(id) else { return }
                rows = page.map { Row(item: $0, sources: [], similarity: nil) }
                reachedEnd = page.count < Self.pageSize
                phase = .browsing
                semanticNote = nil
                fixSelection()
            } catch {
                guard gate.accepts(id) else { return }
                phase = .failed(String(describing: error))
            }
        }
    }

    func loadMoreIfNeeded(current: Row) {
        guard phase == .browsing, !reachedEnd, rows.count < Self.maxRowsInMemory, current.id == rows.last?.id, let last = rows.last else { return }
        let id = gate.next()
        Task {
            let page = (try? await service.page(after: PageCursor(last.item), kind: kind, limit: Self.pageSize)) ?? []
            guard gate.accepts(id) else { return }
            rows = RowWindow.append(page.map { Row(item: $0, sources: [], similarity: nil) }, to: rows, cap: Self.maxRowsInMemory)
            reachedEnd = page.count < Self.pageSize || rows.count >= Self.maxRowsInMemory
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        debounce?.cancel()
        let text = query
        if text.trimmingCharacters(in: .whitespaces).isEmpty { loadFirstPage(); return }
        debounce = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            await runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        let id = gate.next()
        phase = .searching
        let r = await service.search(SearchRequest(requestID: id, text: text, kind: kind, semantic: true, limit: 200))
        let note = await describe(r)                         // R10: finish all awaits before the stale check
        guard gate.accepts(r.requestID) else { return }     // stale response (AC6.4)
        rows = r.hits.map { Row(item: $0.item, sources: $0.sources, similarity: $0.similarity) }
        lastElapsedMs = r.elapsedMs
        newContentWhileSearching = false
        if let e = r.error { phase = .failed(e) } else { phase = .results }
        semanticNote = note
        fixSelection()
    }

    private func describe(_ r: SearchResponse) async -> String? {
        switch r.semantic {
        case .notEnabled: return "语义搜图未启用 · 在设置 › 模型中下载并启用"
        case .textQueriesUnsupported: return "当前模型只支持以图搜图"
        case .failed(let e): return "语义搜索出错：\(e)"
        case .unavailable(let e): return "语义搜索不可用（模型加载失败）：\(e) · 可在设置 › 模型中重新下载"
        case .notApplicable: return nil
        case .ready(let translated):
            var parts: [String] = []
            if let m = await service.activeModelManifest(), let cov = try? await service.coverage(modelID: m.id), cov.images > cov.indexed {
                parts.append("语义索引 \(cov.indexed)/\(cov.images)")
            }
            if let translated { parts.append("按「\(translated)」语义搜图") }
            if r.untranslatedCJK { parts.append("未安装中→英翻译，中文语义搜图效果有限") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private func fixSelection() {
        if let s = selection, rows.contains(where: { $0.id == s }) { return }
        selection = rows.first?.id
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == selection } ?? 0
        let j = max(0, min(rows.count - 1, i + delta))
        selection = rows[j].id
        if delta > 0 { loadMoreIfNeeded(current: rows[j]) }
    }

    // MARK: Actions

    /// FR21/22: links and file paths are plain text; while ⌘ is held they turn into blue, clickable links.
    private(set) var commandDown = false
    @ObservationIgnored private var flagsMonitor: Any?

    private func startWatchingCommandKey() {
        stopWatchingCommandKey()
        commandDown = NSEvent.modifierFlags.contains(.command)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let down = e.modifierFlags.contains(.command)
            if self?.commandDown != down { self?.commandDown = down }
            return e
        }
    }

    private func stopWatchingCommandKey() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
        commandDown = false
    }

    /// FR22: open Finder at the files' folder with the files selected, then close the panel.
    func revealInFinder(_ urls: [URL]) {
        tracker.perform(key: "panel.reveal_file", name: "panel.reveal_file") { [self] in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            onClose?()
        }
    }

    /// FR21: open a link from the detail pane in the default browser, then close the panel.
    func openLink(_ url: URL) {
        tracker.perform(key: "panel.open_link", name: "panel.open_link", detail: url.scheme) { [self] in
            NSWorkspace.shared.open(url)
            onClose?()
        }
    }

    // All panel actions (button, menu, keyboard, double-click) go through the action state machine (FR23).

    func copySelected(via source: String = "button") {
        guard let row = selectedRow else { return }
        tracker.perform(key: "panel.copy", name: "panel.copy.\(source)", detail: String(row.id)) { [self] in
            try await service.copyBack(id: row.id)
            onCopied?(row.item.kind == .image ? "已复制图片" : "已复制")
            onClose?()
        }
    }

    func deleteSelected(via source: String = "button") {
        guard let row = selectedRow else { return }
        let idx = rows.firstIndex { $0.id == row.id } ?? 0
        tracker.perform(key: "panel.delete", name: "panel.delete.\(source)", detail: String(row.id)) { [self] in
            try await service.delete(id: row.id)       // R7: on failure the row stays and the reason is shown
            rows.removeAll { $0.id == row.id }
            selection = rows.isEmpty ? nil : rows[min(idx, rows.count - 1)].id
        }
    }

    func togglePinSelected(via source: String = "button") {
        guard let row = selectedRow else { return }
        tracker.perform(key: "panel.pin", name: "panel.pin.\(source)", detail: String(row.id)) { [self] in
            try await service.setPinned(id: row.id, !row.item.pinned)
            if phase == .browsing { await mergeFirstPage() } else { refresh() }
        }
    }

    /// From ClipService change events (R9): only new captures and clear-all change the list from outside;
    /// the panel's own delete / pin update it locally.
    func storeChanged(_ event: ClipEvent) {
        switch event {
        case .captured:
            switch phase {
            case .browsing: Task { await mergeFirstPage() }
            case .results, .searching: newContentWhileSearching = true   // don't reshuffle results (E24)
            case .failed: refresh()
            }
        case .cleared: refresh()
        case .indexProgress, .modelChanged:
            // FR25: re-derive the selected image's status until it is indexed (and after a model change).
            if let row = selectedRow, row.item.kind == .image {
                if case .modelChanged = event { Task { await loadDetail(id: row.id) } }
                else if indexStatus != .indexed { Task { await loadDetail(id: row.id) } }
            }
        default: break
        }
    }

    /// Browsing: put the newest page on top and keep the rows already loaded below it (E24, R9),
    /// so the scroll position and selection survive.
    private func mergeFirstPage() async {
        let id = gate.next()
        guard let page = try? await service.page(after: nil, kind: kind, limit: Self.pageSize), gate.accepts(id) else { return }
        rows = RowWindow.mergeTop(page.map { Row(item: $0, sources: [], similarity: nil) }, onto: rows, cap: Self.maxRowsInMemory)
        fixSelection()
    }

    func panelWillClose() {
        stopWatchingCommandKey()
        gate.invalidate()            // responses arriving after close are dropped
        debounce?.cancel()
    }

    func panelDidOpen() {
        startWatchingCommandKey()
        query = ""
        kind = .all
        selection = nil
        loadFirstPage()
    }
}

