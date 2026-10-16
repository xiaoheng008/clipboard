import Foundation

/// Runs button actions through the ActionMachine: one run per key, an optional deadline, cancellation,
/// telemetry for every terminal outcome, and a log line for results that arrive after a timeout.
public actor ActionCenter {
    private var states: [String: ActionState] = [:]
    private var tasks: [String: Task<Void, Error>] = [:]
    private let telemetry: TelemetryStore?
    private let now: @Sendable () -> Int64
    private var observer: (@Sendable (String, ActionState) -> Void)?

    public init(telemetry: TelemetryStore?, clock: @escaping @Sendable () -> Int64 = Database.systemClock) {
        self.telemetry = telemetry
        self.now = clock
    }

    public func setObserver(_ o: (@Sendable (String, ActionState) -> Void)?) { observer = o }
    public func state(_ key: String) -> ActionState { states[key] ?? .idle }

    private func apply(_ key: String, _ e: ActionEvent) -> ActionTransition {
        let (next, t) = ActionMachine.reduce(states[key] ?? .idle, e)
        states[key] = next
        if t != .ignored && t != .ignoredDuplicate { observer?(key, next) }
        return t
    }

    /// Returns nil when ignored because the same key is already running (no double execution).
    @discardableResult
    public func perform(key: String, name: String, detail: String?, timeout: Duration?,
                        _ op: @escaping @Sendable () async throws -> Void) async -> ActionOutcome? {
        let startedAt = now()
        guard apply(key, .start(at: startedAt)) == .started else { return nil }
        let task = Task { try await op() }
        tasks[key] = task

        enum Race: Sendable { case done(Error?), deadline }
        let first: Race = await withCheckedContinuation { cont in
            let once = Once()
            Task {
                let r: Error?
                do { try await task.value; r = nil } catch { r = error }
                if once.claim() { cont.resume(returning: .done(r)) }
            }
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    if once.claim() { cont.resume(returning: .deadline) }
                }
            }
        }

        let transition: ActionTransition
        switch first {
        case .done(nil):
            transition = apply(key, .completed(at: now()))
        case .done(let error?):
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                transition = apply(key, .cancel(at: now()))
            } else {
                transition = apply(key, .threw(Self.message(error), at: now()))
            }
        case .deadline:
            let limit = Int64(timeout.map { $0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000 } ?? 0)
            transition = apply(key, .deadline(limitMs: limit))
            // The operation keeps running; its eventual result is only logged (3.4 §1, late result).
            Task { [weak self] in
                let r: Error?
                do { try await task.value; r = nil } catch { r = error }
                await self?.late(key: key, name: name, failed: r != nil)
            }
        }
        tasks[key] = nil
        guard case .finished(let outcome, let ms) = transition else { return nil }
        await record(name: name, detail: detail, startedAt: startedAt, ms: ms, outcome: outcome)
        return outcome
    }

    public func cancel(key: String) { tasks[key]?.cancel() }

    private func late(key: String, name: String, failed: Bool) {
        if case .lateResult(let ms) = apply(key, failed ? .threw("", at: now()) : .completed(at: now())) {
            Log.shared.event("action.late_result", ["name": .label(name), "ms": .int(ms), "failed": .bool(failed)])
        }
    }

    private func record(name: String, detail: String?, startedAt: Int64, ms: Int64, outcome: ActionOutcome) async {
        Log.shared.event("action.done", ["name": .label(name), "detail": .label(detail ?? ""), "ms": .int(ms), "outcome": .label(outcome.rawValue)])
        try? await telemetry?.record(name: name, detail: detail, startedAt: startedAt, durationMs: ms, outcome: outcome)
    }

    /// User-facing reason; descriptions are ids / error texts, never clipboard content.
    static func message(_ e: Error) -> String { String(String(describing: e).prefix(200)) }
}


/// Resolves a continuation exactly once across racing tasks.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
