import Foundation
import Testing
@testable import ClipCore

@Suite struct ActionMachineTests {
    // AC23.2 — every row of the transition table in 3.4 §1.
    @Test func startFromIdleRuns() {
        let (s, t) = ActionMachine.reduce(.idle, .start(at: 100))
        #expect(s == .running(startedAt: 100) && t == .started)
    }

    @Test func duplicateStartIsIgnored() {
        let (s, t) = ActionMachine.reduce(.running(startedAt: 100), .start(at: 150))
        #expect(s == .running(startedAt: 100) && t == .ignoredDuplicate)
    }

    @Test(arguments: [ActionState.succeeded(ms: 5), .failed("x"), .timedOut(limitMs: 10, startedAt: 0), .cancelled])
    func startAgainFromAnyTerminal(state: ActionState) {
        #expect(ActionMachine.reduce(state, .start(at: 7)).0 == .running(startedAt: 7))
    }

    @Test func completionAndFailureWithinDeadline() {
        #expect(ActionMachine.reduce(.running(startedAt: 100), .completed(at: 130)) == (.succeeded(ms: 30), .finished(.succeeded, ms: 30)))
        #expect(ActionMachine.reduce(.running(startedAt: 100), .threw("磁盘已满", at: 140)) == (.failed("磁盘已满"), .finished(.failed, ms: 40)))
    }

    @Test func deadlineTimesOut() {
        #expect(ActionMachine.reduce(.running(startedAt: 100), .deadline(limitMs: 60_000)) ==
                (.timedOut(limitMs: 60_000, startedAt: 100), .finished(.timedOut, ms: 60_000)))
    }

    // A late result after a timeout does not flip the state; it is reported with its real duration.
    @Test func lateResultKeepsTimedOut() {
        let timedOut = ActionState.timedOut(limitMs: 10_000, startedAt: 100)
        #expect(ActionMachine.reduce(timedOut, .completed(at: 15_100)) == (timedOut, .lateResult(ms: 15_000)))
        #expect(ActionMachine.reduce(timedOut, .threw("x", at: 12_100)) == (timedOut, .lateResult(ms: 12_000)))
    }

    @Test func cancelOnlyWhileRunning() {
        #expect(ActionMachine.reduce(.running(startedAt: 100), .cancel(at: 400)) == (.cancelled, .finished(.cancelled, ms: 300)))
        #expect(ActionMachine.reduce(.idle, .cancel(at: 1)) == (.idle, .ignored))
    }

    @Test func strayEventsAreIgnored() {
        #expect(ActionMachine.reduce(.idle, .completed(at: 5)).1 == .ignored)
        #expect(ActionMachine.reduce(.succeeded(ms: 1), .deadline(limitMs: 5)).1 == .ignored)
    }
}

@Suite struct ActionCenterTests {
    func center() throws -> (ActionCenter, TelemetryStore) {
        let home = try makeTempHome()
        let t = try TelemetryStore(home: home)
        return (ActionCenter(telemetry: t), t)
    }

    @Test func succeedsAndRecords() async throws {
        let (c, t) = try center()
        let outcome = await c.perform(key: "k", name: "test.ok", detail: "m@1", timeout: .seconds(5)) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(outcome == .succeeded)
        #expect(await c.state("k").isTerminal)
        let rows = try await t.slowest(limit: 10)
        #expect(rows.count == 1 && rows[0].name == "test.ok" && rows[0].detail == "m@1" && rows[0].outcome == .succeeded && rows[0].durationMs >= 15)
    }

    @Test func timesOutThenRecordsLateResult() async throws {
        let (c, t) = try center()
        let outcome = await c.perform(key: "k", name: "test.slow", detail: nil, timeout: .milliseconds(50)) { try await Task.sleep(for: .milliseconds(300)) }
        #expect(outcome == .timedOut)
        guard case .timedOut = await c.state("k") else { Issue.record("state"); return }
        try await Task.sleep(for: .milliseconds(400))
        guard case .timedOut = await c.state("k") else { Issue.record("late result flipped the state"); return }
        #expect(try await t.slowest(limit: 10).first?.outcome == .timedOut)
    }

    @Test func failureCarriesReason() async throws {
        let (c, _) = try center()
        let outcome = await c.perform(key: "k", name: "test.fail", detail: nil, timeout: .seconds(5)) { throw ServiceError.notFound(7) }
        #expect(outcome == .failed)
        guard case .failed(let msg) = await c.state("k") else { Issue.record("state"); return }
        #expect(msg.contains("7"))
    }

    @Test func duplicateWhileRunningIsIgnored() async throws {
        let (c, t) = try center()
        let runs = Counter()
        async let first = c.perform(key: "k", name: "test.dup", detail: nil, timeout: .seconds(5)) { _ = runs.increment(); try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(20))
        let second = await c.perform(key: "k", name: "test.dup", detail: nil, timeout: .seconds(5)) { _ = runs.increment() }
        #expect(second == nil)
        #expect(await first == .succeeded)
        #expect(runs.value == 1)
        #expect(try await t.slowest(limit: 10).count == 1)
    }

    @Test func cancelStopsTheOperation() async throws {
        let (c, _) = try center()
        async let outcome = c.perform(key: "dl", name: "test.download", detail: nil, timeout: nil) { try await Task.sleep(for: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
        await c.cancel(key: "dl")
        #expect(await outcome == .cancelled)
        #expect(await c.state("dl") == .cancelled)
    }
}

@Suite struct TelemetryStoreTests {
    // AC23.3 — only the 1000 slowest actions are kept.
    @Test func keepsTheSlowest1000() async throws {
        let t = try TelemetryStore(home: try makeTempHome())
        for i in 0..<1500 { try await t.record(name: "op", detail: nil, startedAt: Int64(i), durationMs: Int64((i * 7919) % 1500), outcome: .succeeded) }
        let rows = try await t.slowest(limit: 2000)
        #expect(rows.count == 1000)
        #expect(rows.map(\.durationMs).min() == 500)
        #expect(rows.map(\.durationMs) == rows.map(\.durationMs).sorted(by: >))
        #expect(try await t.report(limit: 3).contains("op"))
    }
}

@Suite struct ModelSlotStateTests {
    var ctx: CaptureContext { CaptureContext(frontmostBundleID: nil, frontmostName: nil, excludedBundleIDs: [], lastSelfWriteChangeCount: nil) }

    // AC23.4 — activating rejects a second activation; a failed load keeps the previous model.
    @Test func activatingIsExclusiveAndFailureKeepsPrevious() async throws {
        let gate = Counter()
        let services = PlatformServices(ocr: nil, translator: NoTranslator(), pasteboard: FakeWriter(), makeProvider: { m in
            if m.id == "mobileclip-s0@1" { try await Task.sleep(for: .milliseconds(200)) }
            if m.id == "mobileclip-s2@1" { _ = gate.increment(); throw ProviderError.modelUnavailable("corrupt") }
            var e = FakeEmbedder(); e.modelID = m.id; e.dimension = m.dim; return e
        }, memoryGB: { 16 })
        let rt = try await Runtime.open(home: try makeTempHome(), services: services, startWorker: false, requireInstalledModel: false)
        try await rt.service.activateModel(id: "siglip2-base@1", requireInstalled: false)

        async let slow: Void = rt.service.activateModel(id: "mobileclip-s0@1", requireInstalled: false)
        try await Task.sleep(for: .milliseconds(50))
        guard case .activating(let target, let previous) = await rt.service.slotState(.image) else { Issue.record("not activating"); return }
        #expect(target == "mobileclip-s0@1" && previous == "siglip2-base@1")
        await #expect(throws: ServiceError.self) { try await rt.service.activateModel(id: "siglip2-base@1", requireInstalled: false) }
        #expect(await rt.service.activeModelManifest(slot: .image)?.id == "siglip2-base@1")   // previous still serves search
        try await slow
        #expect(await rt.service.slotState(.image) == .active("mobileclip-s0@1"))

        await #expect(throws: (any Error).self) { try await rt.service.activateModel(id: "mobileclip-s2@1", requireInstalled: false) }
        guard case .failed(let t2, _, let prev2) = await rt.service.slotState(.image) else { Issue.record("not failed"); return }
        #expect(t2 == "mobileclip-s2@1" && prev2 == "mobileclip-s0@1")
        #expect(await rt.service.activeModelManifest(slot: .image)?.id == "mobileclip-s0@1")
        #expect(try await rt.db.setting(SettingKey.activeModel) == "mobileclip-s0@1")
    }
}
