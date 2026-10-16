import ClipCore
import SwiftUI

/// Deadlines per action type (Q14, docs/scv/3.4 §1).
enum ActionTimeouts {
    static let model: Duration = .seconds(60)       // activate / switch / deactivate a model
    static let standard: Duration = .seconds(10)    // copy, delete, pin, clear, diagnostics, export …
}

/// Mirrors ActionCenter states on the main actor for the UI (FR23).
@MainActor @Observable
final class ActionTracker {
    @ObservationIgnored let center: ActionCenter
    private(set) var states: [String: ActionState] = [:]
    /// Keys running for more than 0.3 s (no spinner flash for fast actions).
    private(set) var spinners: Set<String> = []

    init(center: ActionCenter) {
        self.center = center
        Task { await center.setObserver { key, state in Task { @MainActor [weak self] in self?.update(key, state) } } }
    }

    private func update(_ key: String, _ state: ActionState) {
        states[key] = state
        if state.isRunning {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                if self?.states[key]?.isRunning == true { self?.spinners.insert(key) }
            }
        } else {
            spinners.remove(key)
        }
    }

    func isRunning(_ key: String) -> Bool { states[key]?.isRunning == true }
    func showsSpinner(_ key: String) -> Bool { spinners.contains(key) }

    /// User-facing text for a terminal state that needs attention; nil when nothing to say.
    func message(_ key: String) -> String? {
        switch states[key] {
        case .failed(let m)?: "失败：\(m)"
        case .timedOut(let limit, _)?: "操作超时（\(limit / 1000) 秒），已记录日志"
        case .cancelled?: "已取消"
        default: nil
        }
    }

    /// Fire-and-forget from UI events; the state machine drives spinner / disabled / message.
    func perform(key: String, name: String, detail: String? = nil, timeout: Duration? = ActionTimeouts.standard,
                 _ op: @escaping @MainActor @Sendable () async throws -> Void) {
        Task { await center.perform(key: key, name: name, detail: detail, timeout: timeout) { try await op() } }
    }

    func cancel(_ key: String) { Task { await center.cancel(key: key) } }
}

/// The only Button allowed in the app UI (AC23.5): every tap runs through the action state machine,
/// shows a spinner while running, cannot be double-triggered, and is recorded in telemetry.
struct TrackedButton<L: View>: View {
    let tracker: ActionTracker
    let key: String
    let name: String
    var detail: String? = nil
    var timeout: Duration? = ActionTimeouts.standard
    var role: ButtonRole? = nil
    let action: @MainActor @Sendable () async throws -> Void
    @ViewBuilder let label: () -> L

    var body: some View {
        Button(role: role) {
            tracker.perform(key: key, name: name, detail: detail, timeout: timeout, action)
        } label: {
            HStack(spacing: 4) {
                if tracker.showsSpinner(key) { ProgressView().controlSize(.small) }
                label()
            }
        }
        .disabled(tracker.isRunning(key))
    }
}

extension TrackedButton where L == Text {
    init(_ title: String, tracker: ActionTracker, key: String, name: String, detail: String? = nil,
         timeout: Duration? = ActionTimeouts.standard, role: ButtonRole? = nil,
         action: @escaping @MainActor @Sendable () async throws -> Void) {
        self.init(tracker: tracker, key: key, name: name, detail: detail, timeout: timeout, role: role, action: action) { Text(title) }
    }
}
