import Foundation

// FR23 — the button-action state machine (docs/scv/3.4-action-state-model.md §1). Pure.

public enum ActionOutcome: String, Sendable, Codable, CaseIterable {
    case succeeded, failed, timedOut, cancelled
}

public enum ActionState: Sendable, Equatable {
    case idle
    case running(startedAt: Int64)
    case succeeded(ms: Int64)
    case failed(String)
    case timedOut(limitMs: Int64, startedAt: Int64)
    case cancelled

    public var isRunning: Bool { if case .running = self { true } else { false } }
    public var isTerminal: Bool {
        switch self { case .succeeded, .failed, .timedOut, .cancelled: true; default: false }
    }
}

public enum ActionEvent: Sendable, Equatable {
    case start(at: Int64)
    case completed(at: Int64)
    case threw(String, at: Int64)
    case deadline(limitMs: Int64)
    case cancel(at: Int64)
}

/// What a transition means for the caller (telemetry / logging).
public enum ActionTransition: Sendable, Equatable {
    case started
    case ignoredDuplicate                         // start while running: do not run twice
    case finished(ActionOutcome, ms: Int64)       // reached a terminal state: record it
    case lateResult(ms: Int64)                    // result arrived after the timeout: log only
    case ignored                                  // event not applicable in this state
}

public enum ActionMachine {
    public static func reduce(_ s: ActionState, _ e: ActionEvent) -> (ActionState, ActionTransition) {
        switch (s, e) {
        case (.running, .start):
            return (s, .ignoredDuplicate)
        case (_, .start(let at)):
            return (.running(startedAt: at), .started)
        case (.running(let t0), .completed(let at)):
            return (.succeeded(ms: at - t0), .finished(.succeeded, ms: at - t0))
        case (.running(let t0), .threw(let msg, let at)):
            return (.failed(msg), .finished(.failed, ms: at - t0))
        case (.running, .deadline(let limit)):
            guard case .running(let t0) = s else { return (s, .ignored) }
            return (.timedOut(limitMs: limit, startedAt: t0), .finished(.timedOut, ms: limit))
        case (.running(let t0), .cancel(let at)):
            return (.cancelled, .finished(.cancelled, ms: at - t0))
        case (.timedOut(_, let t0), .completed(let at)), (.timedOut(_, let t0), .threw(_, let at)):
            return (s, .lateResult(ms: at - t0))
        default:
            return (s, .ignored)
        }
    }
}
