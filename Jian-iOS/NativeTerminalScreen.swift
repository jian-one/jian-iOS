import SwiftTerm
import SwiftUI

/// A deliberately unconfigured SwiftTerm view for all server terminal sessions.
struct NativeTerminalScreen: View {
    @Environment(AppModel.self) private var appModel
    let session: AgentSession
    @State private var socket: TerminalSocket?

    var body: some View {
        Group {
            if let socket {
                NativeTerminalView(socket: socket)
            } else {
                ProgressView("正在建立终端")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) {
            let next = TerminalSocket(client: appModel.client)
            socket = next
            next.connect(kind: session.kind, sessionID: session.id)
        }
        .onDisappear {
            socket?.disconnect()
        }
    }
}

/// SwiftTerm's native `TerminalView` rendered directly through
/// `UIViewRepresentable`, with only the delegate bridge needed to connect it
/// to the existing server Bash WebSocket.
struct NativeTerminalView: UIViewRepresentable {
    let socket: TerminalSocket

    func makeCoordinator() -> Coordinator {
        Coordinator(socket: socket)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.view = view
        socket.observeTerminal(
            output: { [weak view] text in view?.feed(text: text) },
            initialReplayComplete: {}
        )
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

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
