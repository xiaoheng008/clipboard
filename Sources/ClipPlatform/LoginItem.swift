import ClipCore
import Foundation
import ServiceManagement

/// FR17: launch at login via the system login-item service. Off by default — it changes
/// system settings, so only the user turns it on (Settings › 通用, or `--login-item on`).
public enum LoginItem {
    public enum State: String, Sendable { case enabled, disabled, requiresApproval, notFound, unavailable }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval      // user must allow it in System Settings › General › Login Items
        // Observed on macOS 27: a bundle that was never registered also reports .notFound.
        case .notFound: Bundle.main.bundleURL.pathExtension == "app" ? .disabled : .notFound
        @unknown default: .unavailable
        }
    }

    public static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        Log.shared.event("login_item.set", ["on": .bool(on), "state": .label(state.rawValue)])
    }

    public static var displayName: String {
        switch state {
        case .enabled: "已开启"
        case .disabled: "未开启"
        case .requiresApproval: "等待你在「系统设置 › 通用 › 登录项」中允许"
        case .notFound: "需要从 ClipVault.app 运行"
        case .unavailable: "不可用"
        }
    }
}
