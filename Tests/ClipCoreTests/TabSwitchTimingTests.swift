import Testing
@testable import ClipCore

/// Settings tab switch timing (user report: tabs feel stuck after a click). Times are system uptime seconds.
@Suite struct TabSwitchTimingTests {
    @Test func measuresClickToSelectionToAppearToSettled() {
        var t = TabSwitchTiming()
        t.begin(to: "models", clickUptime: 10.000, now: 10.300)          // main thread busy 300 ms before the change ran
        let other = t.appeared("general", now: 10.31)                    // another tab's onAppear is not ours
        let mine = t.appeared("models", now: 10.350)
        let r = t.settled(now: 10.420)
        let again = t.settled(now: 11)                                   // reported once
        #expect(!other && mine)
        #expect(r == TabSwitchTiming.Report(tab: "models", clickToChangeMs: 300, changeToAppearMs: 50, appearToSettledMs: 70, totalMs: 420))
        #expect(again == nil)
    }

    @Test func noClickEventStillMeasuresFromTheChange() {
        var t = TabSwitchTiming()
        t.begin(to: "diagnostics", clickUptime: nil, now: 5)
        _ = t.appeared("diagnostics", now: 5.02)
        let r = t.settled(now: 5.03)
        #expect(r == TabSwitchTiming.Report(tab: "diagnostics", clickToChangeMs: nil, changeToAppearMs: 20, appearToSettledMs: 10, totalMs: 30))
    }

    @Test func aNewerSwitchReplacesAnUnfinishedOne() {
        var t = TabSwitchTiming()
        t.begin(to: "models", clickUptime: nil, now: 1)
        t.begin(to: "general", clickUptime: nil, now: 1.1)
        let stale = t.appeared("models", now: 1.2)
        let current = t.appeared("general", now: 1.2)
        let r = t.settled(now: 1.25)
        #expect(!stale && current)
        #expect(r?.tab == "general")
    }
}
