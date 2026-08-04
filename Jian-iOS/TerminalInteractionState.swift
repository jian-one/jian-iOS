struct TerminalReplayGate {
    private(set) var isComplete = false
    private(set) var isWaitingForQuietPeriod = false
    private var generation = 0

    mutating func reset() {
        self = TerminalReplayGate()
    }

    @discardableResult
    mutating func sessionStarted() -> Int {
        guard !isComplete else { return generation }
        isWaitingForQuietPeriod = true
        return advanceGeneration()
    }

    @discardableResult
    mutating func receivedOutput() -> Int {
        guard isWaitingForQuietPeriod, !isComplete else { return generation }
        return advanceGeneration()
    }

    @discardableResult
    mutating func explicitReplayCompleted() -> Bool {
        guard !isComplete else { return false }
        isComplete = true
        isWaitingForQuietPeriod = false
        return true
    }

    @discardableResult
    mutating func quietPeriodElapsed(generation: Int) -> Bool {
        guard isWaitingForQuietPeriod,
              !isComplete,
              generation == self.generation
        else { return false }
        isComplete = true
        isWaitingForQuietPeriod = false
        return true
    }

    private mutating func advanceGeneration() -> Int {
        generation &+= 1
        return generation
    }
}

struct TerminalViewportFollowState {
    private(set) var shouldFollowOutput = true
    private(set) var isUserScrolling = false

    mutating func reset() {
        self = TerminalViewportFollowState()
    }

    mutating func setFollowing(_ enabled: Bool) {
        shouldFollowOutput = enabled
    }

    mutating func userScrollBegan() {
        isUserScrolling = true
        shouldFollowOutput = false
    }

    mutating func userScrolled(isNearBottom: Bool) {
        guard !isUserScrolling else {
            shouldFollowOutput = false
            return
        }
        shouldFollowOutput = isNearBottom
    }

    @discardableResult
    mutating func userScrollEnded(isNearBottom: Bool) -> Bool {
        isUserScrolling = false
        shouldFollowOutput = isNearBottom
        return shouldFollowOutput
    }
}
