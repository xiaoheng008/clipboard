/// FR28 / Q19: after Enter has put the item back on the pasteboard, paste it at the original cursor or only copy.
/// Pure: the platform facts (Accessibility, secure input, frontmost app) are gathered by the caller (3.4 §5).
public enum PasteDecision: Equatable, Sendable {
    case paste
    case copyOnly(Reason)

    public enum Reason: String, Equatable, Sendable {
        case commandHeld      // ⌘Enter: the user asked for copy only
        case notTrusted       // no Accessibility permission: synthetic ⌘V would be dropped
        case secureInput      // a password field has secure input on: the system drops synthetic keys
        case targetChanged    // the app the panel was opened over is no longer frontmost (or unknown)
    }

    /// Table order is priority.
    public static func decide(commandHeld: Bool, trusted: Bool, secureInput: Bool,
                              frontmostPID: Int32?, targetPID: Int32?) -> PasteDecision {
        if commandHeld { return .copyOnly(.commandHeld) }
        if !trusted { return .copyOnly(.notTrusted) }
        if secureInput { return .copyOnly(.secureInput) }
        guard let targetPID, frontmostPID == targetPID else { return .copyOnly(.targetChanged) }
        return .paste
    }

    /// Toast text after the panel closes.
    public func message(imageItem: Bool) -> String {
        let copied = imageItem ? "已复制图片" : "已复制"
        switch self {
        case .paste: return "已粘贴"
        case .copyOnly(.commandHeld): return copied
        case .copyOnly(.notTrusted): return copied + " · 开启「辅助功能」后回车可直接粘贴"
        case .copyOnly(.secureInput): return copied + " · 当前输入框不允许自动粘贴"
        case .copyOnly(.targetChanged): return copied + " · 原 App 已不在前台"
        }
    }

    /// Telemetry detail (no clipboard content).
    public var detail: String {
        switch self {
        case .paste: return "pasted"
        case .copyOnly(let r): return "copied:\(r.rawValue)"
        }
    }
}

/// FR28 flow (3.4 §5): copying → closing → deciding → posting. Side effects come in as closures so the order
/// constraints are testable: ⌘V only after the copy-back succeeded, and only into the app the panel opened over.
@MainActor
public enum PasteFlow {
    public struct Hooks {
        public var trusted: () -> Bool
        public var secureInput: () -> Bool
        public var frontmostPID: () -> Int32?
        public var panelIsKey: () -> Bool
        public var post: () -> Void
        /// One wait step while the hidden panel hands key status back (10 ms in the app).
        public var pause: () async -> Void
        public init(trusted: @escaping () -> Bool, secureInput: @escaping () -> Bool, frontmostPID: @escaping () -> Int32?,
                    panelIsKey: @escaping () -> Bool, post: @escaping () -> Void, pause: @escaping () async -> Void) {
            self.trusted = trusted; self.secureInput = secureInput; self.frontmostPID = frontmostPID
            self.panelIsKey = panelIsKey; self.post = post; self.pause = pause
        }
    }

    /// Throws what `copyBack` throws (copyFailed: the panel stays open, nothing is posted).
    public static func run(commandHeld: Bool, target: Int32?, hooks: Hooks,
                           copyBack: () async throws -> Void, close: () -> Void) async throws -> PasteDecision {
        try await copyBack()                                   // copying
        close()                                                // closing
        if !commandHeld {                                      // ≤ 15 steps for the panel to give up key status
            for _ in 0..<15 where hooks.panelIsKey() || hooks.frontmostPID() != target { await hooks.pause() }
        }
        let decision = PasteDecision.decide(commandHeld: commandHeld, trusted: hooks.trusted(), secureInput: hooks.secureInput(),
                                            frontmostPID: hooks.frontmostPID(), targetPID: target)   // deciding
        if decision == .paste { hooks.post() }                 // posting
        return decision
    }
}
