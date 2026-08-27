import SwiftTerm
import SwiftUI

/// A deliberately unconfigured SwiftTerm view for all server terminal sessions.
struct NativeTerminalScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let session: AgentSession
    @State private var socket: TerminalSocket?
    @State private var errorMessage = ""
    @State private var isRestarting = false
    @State private var isReleasing = false
    @AppStorage("terminalFontSize") private var fontSize = 12.0

    var body: some View {
        Group {
            if let socket {
                NativeTerminalView(socket: socket, fontSize: CGFloat(fontSize))
            } else {
                ProgressView("正在建立终端")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ControlGroup {
                        Button("-") {
                            fontSize = max(fontSize - 1, 10)
                        }
                        .disabled(fontSize <= 10)

                        Text("字号 \(Int(fontSize))")
                            .font(.body)

                        Button("+") {
                            fontSize = min(fontSize + 1, 24)
                        }
                        .disabled(fontSize >= 24)
                    }
                    .menuActionDismissBehavior(.disabled)

                    Button {
                        Task { await restart() }
                    } label: {
                        Label("重启会话", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isRestarting)

                    Button(role: .destructive) {
                        Task { await release() }
                    } label: {
                        Label("释放会话", systemImage: "xmark.circle")
                    }
                    .disabled(isReleasing)
                } label: {
                    Label("终端操作", systemImage: "ellipsis")
                }
                .disabled(socket == nil)
            }
        }
        .alert("终端操作失败", isPresented: errorAlertPresented) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            let next = TerminalSocket(client: appModel.client)
            socket = next
            next.connect(kind: session.kind, sessionID: session.id)
        }
        .onDisappear {
            socket?.disconnect()
            socket = nil
        }
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding {
            !errorMessage.isEmpty
        } set: { presented in
            if !presented { errorMessage = "" }
        }
    }

    private func restart() async {
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        do {
            socket?.disconnect()
            try await appModel.restart(session)
            socket?.reconnect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func release() async {
        guard !isReleasing else { return }
        isReleasing = true
        socket?.disconnect()
        do {
            try await appModel.release(session)
            dismiss()
        } catch {
            isReleasing = false
            errorMessage = error.localizedDescription
        }
    }
}

/// SwiftTerm's native `TerminalView` rendered directly through
/// `UIViewRepresentable`, with only the delegate bridge needed to connect it
/// to the existing server Bash WebSocket.
struct NativeTerminalView: UIViewRepresentable {
    let socket: TerminalSocket
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(socket: socket)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.terminalDelegate = context.coordinator
        context.coordinator.view = view
        socket.observeTerminal(
            output: { [weak coordinator = context.coordinator] text in
                coordinator?.receiveOutput(text)
            },
            initialReplayComplete: { [weak coordinator = context.coordinator] in
                coordinator?.finishInitialReplay()
            }
        )
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        guard uiView.font.pointSize != fontSize else { return }
        uiView.font = uiView.font.withSize(fontSize)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let socket: TerminalSocket
        weak var view: TerminalView?
        private var initialOutput = ""
        private var initialReplayComplete = false
        private var resizeOutput = ""
        private var resizeOutputTask: Task<Void, Never>?

        deinit {
            resizeOutputTask?.cancel()
        }
        init(socket: TerminalSocket) {
            self.socket = socket
        }

        func receiveOutput(_ text: String) {
            guard initialReplayComplete else {
                initialOutput += text
                return
            }
            if resizeOutputTask != nil {
                resizeOutput += text
                return
            }
            view?.feed(text: text)
        }

        func finishInitialReplay() {
            guard !initialReplayComplete else { return }
            initialReplayComplete = true
            guard !initialOutput.isEmpty else { return }
            view?.feed(text: "\u{1B}[?2026h" + initialOutput + "\u{1B}[?2026l")
            initialOutput.removeAll(keepingCapacity: false)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            socket.sendResize(cols: newCols, rows: newRows)
            resizeOutputTask?.cancel()
            resizeOutputTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                self.resizeOutputTask = nil
                guard !self.resizeOutput.isEmpty else { return }
                self.view?.feed(text: "\u{1B}[?2026h" + self.resizeOutput + "\u{1B}[?2026l")
                self.resizeOutput.removeAll(keepingCapacity: false)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            socket.sendInput(String(decoding: data, as: UTF8.self))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        func bell(source: TerminalView) {}

        func clipboardRead(source: TerminalView) -> Data? { nil }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
