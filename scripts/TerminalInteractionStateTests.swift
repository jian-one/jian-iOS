@main
struct TerminalInteractionStateTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }

    static func main() {
        var legacyReplay = TerminalReplayGate()
        let startedGeneration = legacyReplay.sessionStarted()
        expect(!legacyReplay.isComplete, "session.started must not expose replay immediately")

        let outputGeneration = legacyReplay.receivedOutput()
        expect(
            !legacyReplay.quietPeriodElapsed(generation: startedGeneration),
            "output received after session.started must invalidate the old quiet period"
        )
        expect(
            legacyReplay.quietPeriodElapsed(generation: outputGeneration),
            "the latest quiet period should finish legacy replay"
        )

        var explicitReplay = TerminalReplayGate()
        expect(explicitReplay.explicitReplayCompleted(), "explicit replay fence should complete immediately")
        expect(!explicitReplay.explicitReplayCompleted(), "replay completion must only fire once")

        var viewport = TerminalViewportFollowState()
        viewport.userScrollBegan()
        expect(!viewport.shouldFollowOutput, "drag begin must release the viewport from the live tail")
        viewport.userScrolled(isNearBottom: true)
        expect(!viewport.shouldFollowOutput, "dragging near the bottom must not re-enable following")
        expect(!viewport.userScrollEnded(isNearBottom: false), "history position must stay detached")

        viewport.userScrollBegan()
        expect(viewport.userScrollEnded(isNearBottom: true), "ending at the bottom must resume following")

        print("Terminal interaction state tests passed")
    }
}
