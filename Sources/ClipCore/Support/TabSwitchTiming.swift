/// Times one settings tab switch in three phases (all on the main thread; times are system uptime seconds):
/// click → selection change (main thread busy before the change could run), change → new tab's onAppear
/// (building the tab), onAppear → next main-queue turn (layout and drawing committed).
public struct TabSwitchTiming: Sendable {
    public struct Report: Equatable, Sendable {
        public let tab: String
        public let clickToChangeMs: Int?
        public let changeToAppearMs: Int
        public let appearToSettledMs: Int
        public let totalMs: Int
    }

    private var tab: String?
    private var click: Double?
    private var change: Double = 0
    private var appear: Double?

    public init() {}

    /// A newer switch replaces an unfinished one.
    public mutating func begin(to tab: String, clickUptime: Double?, now: Double) {
        self.tab = tab; click = clickUptime; change = now; appear = nil
    }

    /// True when this is the onAppear of the tab being switched to.
    public mutating func appeared(_ tab: String, now: Double) -> Bool {
        guard tab == self.tab, appear == nil else { return false }
        appear = now
        return true
    }

    /// The report, once per switch.
    public mutating func settled(now: Double) -> Report? {
        guard let tab, let appear else { return nil }
        defer { self.tab = nil; self.appear = nil }
        func ms(_ s: Double) -> Int { Int((s * 1000).rounded()) }
        let start = click ?? change
        return Report(tab: tab, clickToChangeMs: click.map { ms(change - $0) }, changeToAppearMs: ms(appear - change),
                      appearToSettledMs: ms(now - appear), totalMs: ms(now - start))
    }
}
