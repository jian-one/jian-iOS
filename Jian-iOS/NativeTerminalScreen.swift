import SwiftTerm
import SwiftUI

/// A deliberately unconfigured SwiftTerm view for all server terminal sessions.
struct NativeTerminalScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: AgentSession
    @State private var socket: TerminalSocket?
    @State private var errorMessage = ""
    @State private var isRestarting = false
    @State private var isReleasing = false
    @State private var refreshRequest = 0
    @AppStorage("terminalFontSize") private var fontSize = 12.0

    var body: some View {
        Group {
            if let socket {
                NativeTerminalView(socket: socket, fontSize: CGFloat(fontSize))
                    .id(refreshRequest)
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
                    Stepper(value: $fontSize, in: 10...24, step: 1) {
                        Text("字号 \(Int(fontSize))")
                    }

                    Button {
                        refreshRequest &+= 1
                    } label: {
                        Label("刷新会话", systemImage: "arrow.clockwise")
                    }

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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                socket?.reconnect()
                refreshRequest &+= 1
            case .inactive, .background:
                socket?.disconnect()
            @unknown default:
                break
            }
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

    func makeUIView(context: Context) -> RefreshableTerminalView {
        let view = RefreshableTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.terminalDelegate = context.coordinator
        context.coordinator.view = view
        socket.observeTerminal(
            output: { [weak view] text in view?.receiveOutput(text) },
            initialReplayComplete: { [weak view] in view?.finishInitialReplay() }
        )
        return view
    }

    func updateUIView(_ uiView: RefreshableTerminalView, context: Context) {
        uiView.setFontSize(fontSize)
        _ = uiView.becomeFirstResponder()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let socket: TerminalSocket
        weak var view: TerminalView?
        init(socket: TerminalSocket) {
            self.socket = socket
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            socket.sendResize(cols: newCols, rows: newRows)
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

final class RefreshableTerminalView: TerminalView {
    private static let beginSynchronizedOutput = "\u{1b}[?2026h"
    private static let endSynchronizedOutput = "\u{1b}[?2026l"
    private var initialReplay = ""
    private var hasFinishedInitialReplay = false
    private var isCoalescingViewportUpdates = false
    private var positionBeforeFontChange = 1.0
    private var fontChangeDeadline: UInt64 = 0
    private var fontChangeCompletion: DispatchWorkItem?

    deinit {
        fontChangeCompletion?.cancel()
    }

    func receiveOutput(_ text: String) {
        guard hasFinishedInitialReplay else {
            initialReplay.append(text)
            return
        }
        feed(text: text)
        if isCoalescingViewportUpdates {
            scheduleFontChangeCompletion()
        }
    }

    func finishInitialReplay() {
        guard !hasFinishedInitialReplay else { return }
        hasFinishedInitialReplay = true
        isCoalescingViewportUpdates = true
        feed(text: Self.beginSynchronizedOutput)
        feed(text: initialReplay)
        initialReplay.removeAll(keepingCapacity: false)
        scroll(toPosition: 1)
        isCoalescingViewportUpdates = false
        feed(text: Self.endSynchronizedOutput)
    }

    func setFontSize(_ size: CGFloat) {
        guard font.pointSize != size else { return }
        if !isCoalescingViewportUpdates {
            positionBeforeFontChange = scrollPosition
        }
        isCoalescingViewportUpdates = true
        fontChangeDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        font = font.withSize(size)
        feed(text: Self.beginSynchronizedOutput)
        scheduleFontChangeCompletion()
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        guard !isCoalescingViewportUpdates else { return }
        super.scrolled(source: terminal, yDisp: yDisp)
    }

    override func sizeChanged(source: Terminal) {
        guard isCoalescingViewportUpdates else {
            super.sizeChanged(source: source)
            return
        }
        let cols = source.cols
        let rows = source.rows
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            terminalDelegate?.sizeChanged(source: self, newCols: cols, newRows: rows)
        }
    }

    private func scheduleFontChangeCompletion() {
        fontChangeCompletion?.cancel()
        let completion = DispatchWorkItem { [weak self] in
            guard let self else { return }
            scroll(toPosition: positionBeforeFontChange)
            isCoalescingViewportUpdates = false
            feed(text: Self.endSynchronizedOutput)
            fontChangeCompletion = nil
        }
        fontChangeCompletion = completion
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = fontChangeDeadline > now ? fontChangeDeadline - now : 0
        let delay = min(250_000_000, remaining)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay)), execute: completion)
    }
}
