# Lessons learned（本需求内的 L 条目；Phase 9 评估是否升格为 C）

格式：现象 → 后果 → 约束。

## L1 — 仅有 Command Line Tools 时 `swift test` 间歇性找不到 Swift Testing 宏插件（2026-10-17）
- 现象：同一份代码 `swift test` 交替通过 / 失败，错误为 `plugin for module 'TestingMacros' not found`；`--build-system native` 则直接 `no such module 'Testing'`。
- 后果：测试结果不可信——同一提交一次绿一次红，容易被误判为代码问题，或在"碰巧绿"时误报通过。
- 约束：测试入口统一为 `scripts/test.sh`，显式 `-plugin-path $(xcode-select -p)/usr/lib/swift/host/plugins/testing`；改后连续 4 次全绿（evidence/tdd/S1-green.txt）。
- 升格评估：方法缺口候选——scv-app 的 7A「回归基线 clean」没有提到「工具链本身不确定」，同一命令应至少重复运行确认稳定。

## L2 — SDK 27 把 SwiftUI `@State` 改成了宏，宏插件只随 Xcode 发布（2026-10-17）
- 现象：`swift build` 报 `plugin for module 'SwiftUIMacros' not found`，所有 `@State` 处失败；CLT 只带 `libObservationMacros` / `libSwiftMacros` / testing。`@FocusState`、`@Bindable` 仍是 property wrapper，不受影响。
- 后果：「只装 Command Line Tools 也能构建」这一 Phase 0 事实（F1/F2）对 SwiftUI 的一部分不成立；若不是在 S7 立即构建，会在打包阶段才暴露。
- 约束：UI 不使用 `@State`，视图局部状态放进 `@Observable` 模型（PanelModel / SettingsModel / Thumbnails）；构建环境事实在 Phase 0 要覆盖「每个用到的框架的宏」而不只是「编译器可用」。
- 升格评估：与 L1 同类（工具链事实没有被逐项验证），本需求内发作 2 次 → 满足升格门槛「同类问题 ≥ 2 次」。
