import Testing
@testable import ClipCore

/// AC28.1 — Enter pastes at the original cursor only when every condition holds (3.4 §5, table order = priority).
@Suite struct PasteDecisionTests {
    func decide(command: Bool = false, trusted: Bool = true, secure: Bool = false,
                frontmost: Int32? = 42, target: Int32? = 42) -> PasteDecision {
        PasteDecision.decide(commandHeld: command, trusted: trusted, secureInput: secure, frontmostPID: frontmost, targetPID: target)
    }

    @Test func everythingInPlacePastes() {
        #expect(decide() == .paste)
    }

    @Test func eachConditionFallsBackToCopyWithItsReason() {
        #expect(decide(command: true) == .copyOnly(.commandHeld))
        #expect(decide(trusted: false) == .copyOnly(.notTrusted))
        #expect(decide(secure: true) == .copyOnly(.secureInput))
        #expect(decide(frontmost: 7) == .copyOnly(.targetChanged))
        #expect(decide(frontmost: nil) == .copyOnly(.targetChanged))
        #expect(decide(target: nil) == .copyOnly(.targetChanged))
    }

    // When several hold, the earlier row of the table wins (⌘ is the user's explicit choice; permission next).
    @Test func priorityFollowsTheTable() {
        for trusted in [true, false] { for secure in [true, false] { for front: Int32? in [42, 7, nil] {
            #expect(decide(command: true, trusted: trusted, secure: secure, frontmost: front) == .copyOnly(.commandHeld))
        } } }
        #expect(decide(trusted: false, secure: true, frontmost: 7) == .copyOnly(.notTrusted))
        #expect(decide(secure: true, frontmost: 7) == .copyOnly(.secureInput))
    }

    @Test func userFacingMessages() {
        #expect(PasteDecision.paste.message(imageItem: false) == "已粘贴")
        #expect(PasteDecision.copyOnly(.commandHeld).message(imageItem: true) == "已复制图片")
        #expect(PasteDecision.copyOnly(.notTrusted).message(imageItem: false) == "已复制 · 开启「辅助功能」后回车可直接粘贴")
        #expect(PasteDecision.copyOnly(.secureInput).message(imageItem: false) == "已复制 · 当前输入框不允许自动粘贴")
        #expect(PasteDecision.copyOnly(.targetChanged).message(imageItem: false) == "已复制 · 原 App 已不在前台")
    }
}

/// AC28.2 and the order constraints of 3.4 §5: copy back → close → decide → ⌘V, never ⌘V without a copy-back.
@MainActor @Suite struct PasteFlowTests {
    final class Calls { var log: [String] = [] }
    struct Boom: Error {}

    func run(command: Bool = false, trusted: Bool = true, copyFails: Bool = false,
             frontAfterClose: Int32? = 42, target: Int32? = 42) async -> (PasteDecision?, [String], Bool) {
        let c = Calls()
        var front: Int32? = 99            // the panel is key until close
        var threw = false
        let hooks = PasteFlow.Hooks(trusted: { trusted }, secureInput: { false }, frontmostPID: { front },
                                    panelIsKey: { c.log.last == "close" ? false : true }, post: { c.log.append("⌘V") },
                                    pause: { })
        do {
            let d = try await PasteFlow.run(commandHeld: command, target: target, hooks: hooks,
                                            copyBack: { c.log.append("copyBack"); if copyFails { throw Boom() } },
                                            close: { c.log.append("close"); front = frontAfterClose })
            return (d, c.log, threw)
        } catch { threw = true; return (nil, c.log, threw) }
    }

    @Test func pastesAfterCopyBackAndClose() async {
        let (d, log, _) = await run()
        #expect(d == .paste)
        #expect(log == ["copyBack", "close", "⌘V"])
    }

    @Test func copyBackFailureNeitherClosesNorPastes() async {
        let (d, log, threw) = await run(copyFails: true)
        #expect(threw && d == nil)
        #expect(log == ["copyBack"])
    }

    @Test func copyOnlyPathsNeverPost() async {
        #expect(await run(command: true).1 == ["copyBack", "close"])
        #expect(await run(trusted: false).1 == ["copyBack", "close"])
        let (d, log, _) = await run(frontAfterClose: 7)               // user switched apps meanwhile
        #expect(d == .copyOnly(.targetChanged) && log == ["copyBack", "close"])
    }
}
