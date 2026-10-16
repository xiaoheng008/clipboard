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
        if selectedRow?.id == id { detail = d }
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

    init(service: ClipService, home: AppHome) {
        self.service = service
        self.home = home
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
            let known = Set(rows.map(\.id))
            rows += page.filter { !known.contains($0.id) }.map { Row(item: $0, sources: [], similarity: nil) }
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
        guard gate.accepts(r.requestID) else { return }     // stale response (AC6.4)
        rows = r.hits.map { Row(item: $0.item, sources: $0.sources, similarity: $0.similarity) }
        lastElapsedMs = r.elapsedMs
        newContentWhileSearching = false
        if let e = r.error { phase = .failed(e) } else { phase = .results }
        semanticNote = await describe(r)
        fixSelection()
    }

    private func describe(_ r: SearchResponse) async -> String? {
        switch r.semantic {
        case .notEnabled: return "语义搜图未启用 · 在设置 › 模型中下载并启用"
        case .textQueriesUnsupported: return "当前模型只支持以图搜图"
        case .failed(let e): return "语义搜索出错：\(e)"
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

    func copySelected() {
        guard let row = selectedRow else { return }
        Task {
            do {
                try await service.copyBack(id: row.id)
                onCopied?(row.item.kind == .image ? "已复制图片" : "已复制")
                onClose?()
            } catch { phase = .failed("复制失败：\(error)") }
        }
    }

    func deleteSelected() {
        guard let row = selectedRow else { return }
        let idx = rows.firstIndex { $0.id == row.id } ?? 0
        Task {
            try? await service.delete(id: row.id)
            rows.removeAll { $0.id == row.id }
            selection = rows.isEmpty ? nil : rows[min(idx, rows.count - 1)].id
        }
    }

    func togglePinSelected() {
        guard let row = selectedRow else { return }
        Task {
            try? await service.setPinned(id: row.id, !row.item.pinned)
            refresh()
        }
    }

    /// From ClipService change events.
    func storeChanged() {
        switch phase {
        case .browsing: loadFirstPage()
        case .results, .searching: newContentWhileSearching = true   // don't reshuffle results (E24)
        case .failed: refresh()
        }
    }

    func panelWillClose() {
        gate.invalidate()            // responses arriving after close are dropped
        debounce?.cancel()
    }

    func panelDidOpen() {
        query = ""
        kind = .all
        selection = nil
        loadFirstPage()
    }
}

