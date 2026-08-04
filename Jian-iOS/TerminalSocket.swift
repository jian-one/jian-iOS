import Foundation

@MainActor
@Observable
final class TerminalSocket {
    private static let maximumInputPayloadBytes = 8 * 1024
    private static let maximumWebSocketMessageBytes = 64 * 1024 * 1024

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case ended
        case failed(String)

        var label: String {
            switch self {
            case .idle: "待连接"
            case .connecting: "连接中"
            case .connected: "已连接"
            case .ended: "已结束"
            case .failed(let message): message
            }
        }
    }

    var state: State = .idle

    private let client: UltimationClient
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var legacyReplayCompletionTask: Task<Void, Never>?
    private var onOutput: ((String) -> Void)?
    private var onInitialReplayComplete: (() -> Void)?
    private var pendingOutput: [String] = []
    private var replayGate = TerminalReplayGate()
    private var lastResize: (cols: Int, rows: Int)?

    init(client: UltimationClient) {
        self.client = client
    }

    func connect(kind: AgentKind, sessionID: String) {
        disconnect()
        replayGate.reset()
        state = .connecting
        do {
            let url = try client.websocketURL(kind: kind, sessionID: sessionID)
            var request = URLRequest(url: url)
            if let cookie = try client.cookieHeader() {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.maximumMessageSize = Self.maximumWebSocketMessageBytes
            task = socket
            socket.resume()
            state = .connected
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        legacyReplayCompletionTask?.cancel()
        legacyReplayCompletionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lastResize = nil
        if state == .connecting || state == .connected {
            state = .idle
        }
    }

    func sendInput(_ text: String) {
        var containsEnter = false
        for chunk in text.chunks(maxUTF8Bytes: Self.maximumInputPayloadBytes) {
            send(["type": "input", "data": chunk])
            containsEnter = containsEnter || chunk.utf8.contains { $0 == 0x0D || $0 == 0x0A }
        }

        if containsEnter, let lastResize {
            // A remote client may have cleared its terminal without changing
            // the iOS view bounds. Re-send the current PTY size after Enter
            // so the remote terminal catches up on the next command.
            sendResize(cols: lastResize.cols, rows: lastResize.rows)
        }
    }

    func sendInterrupt() {
        send(["type": "interrupt"])
    }

    func sendResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastResize = (cols, rows)
        send(["type": "resize", "cols": cols, "rows": rows])
    }

    /// Installs the terminal consumer before draining output received during
    /// SwiftUI's view-creation transition. This prevents the server replay from
    /// being dropped when the WebSocket opens before `makeUIView` runs.
    func observeTerminal(
        output: @escaping (String) -> Void,
        initialReplayComplete: @escaping () -> Void
    ) {
        onOutput = output
        onInitialReplayComplete = initialReplayComplete

        let buffered = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        buffered.forEach(output)
        if replayGate.isComplete {
            initialReplayComplete()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let task else { return }
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handle(text)
                    }
                @unknown default:
                    break
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    state = .failed(error.localizedDescription)
                }
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? decoder.decode(TerminalEvent.self, from: data)
        else {
            return
        }
        switch event.type {
        case "pty.output":
            if let output = event.payload?.stringValue {
                if let onOutput {
                    onOutput(output)
                } else {
                    pendingOutput.append(output)
                }
                if replayGate.isWaitingForQuietPeriod {
                    scheduleLegacyReplayCompletion(generation: replayGate.receivedOutput())
                }
            }
        case "session.replay.complete":
            if replayGate.explicitReplayCompleted() {
                notifyInitialReplayComplete()
            }
        case "session.started", "session.ready":
            state = .connected
            // Legacy servers may emit `session.started` before all replay
            // chunks. Wait until replay output has been quiet instead of
            // exposing each chunk as live terminal animation.
            if !replayGate.isComplete {
                scheduleLegacyReplayCompletion(generation: replayGate.sessionStarted())
            }
        case "pty.exit":
            if replayGate.explicitReplayCompleted() {
                notifyInitialReplayComplete()
            }
            state = .ended
        case "error":
            state = .failed(event.payload?.stringValue ?? "终端连接失败")
        default:
            break
        }
    }

    private func scheduleLegacyReplayCompletion(generation: Int) {
        legacyReplayCompletionTask?.cancel()
        legacyReplayCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.replayGate.quietPeriodElapsed(generation: generation) {
                self.notifyInitialReplayComplete()
            }
        }
    }

    private func notifyInitialReplayComplete() {
        legacyReplayCompletionTask?.cancel()
        legacyReplayCompletionTask = nil
        onInitialReplayComplete?()
    }

    private func send(_ object: [String: Any]) {
        guard let task else { return }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.state = .failed(message)
            }
        }
    }
}

private extension String {
    func chunks(maxUTF8Bytes: Int) -> [String] {
        guard maxUTF8Bytes > 0, !isEmpty else { return [] }

        var chunks: [String] = []
        var chunkStart = startIndex
        var chunkBytes = 0
        var index = startIndex

        while index < endIndex {
            let nextIndex = self.index(after: index)
            let characterBytes = self[index..<nextIndex].utf8.count

            if chunkBytes > 0, chunkBytes + characterBytes > maxUTF8Bytes {
                chunks.append(String(self[chunkStart..<index]))
                chunkStart = index
                chunkBytes = 0
            }

            chunkBytes += characterBytes
            index = nextIndex
        }

        if chunkStart < endIndex {
            chunks.append(String(self[chunkStart..<endIndex]))
        }

        return chunks
    }
}
