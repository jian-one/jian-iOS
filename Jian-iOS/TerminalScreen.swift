import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(AppModel.self) private var appModel
    let session: AgentSession
    @State private var socket: TerminalSocket?
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            if let socket {
                TerminalViewBridge(socket: socket)
                    .background(Color.black)
                    .overlay(alignment: .topTrailing) {
                        Text(socket.state.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                    }
                TerminalShortcutBar(socket: socket)
            } else {
                ProgressView("正在建立终端")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await stop() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
            }
        }
        .task(id: session.id) {
            let next = TerminalSocket(client: appModel.client)
            socket = next
            next.connect(kind: session.kind, sessionID: session.id)
        }
        .onDisappear {
            socket?.disconnect()
        }
    }

    private func stop() async {
        do {
            try await appModel.stop(session)
            socket?.sendInterrupt()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TerminalShortcutBar: View {
    let socket: TerminalSocket

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shortcut("ESC") { socket.sendInput("\u{1b}") }
                shortcut("↑") { socket.sendInput("\u{1b}[A") }
                shortcut("↓") { socket.sendInput("\u{1b}[B") }
                shortcut("←") { socket.sendInput("\u{1b}[D") }
                shortcut("→") { socket.sendInput("\u{1b}[C") }
                shortcut("⌫") { socket.sendInput("\u{7f}") }
                shortcut("Enter") { socket.sendInput("\r") }
                shortcut("Ctrl-C") { socket.sendInterrupt() }
                shortcut("Paste") {
                    if let text = UIPasteboard.general.string, !text.isEmpty {
                        socket.sendInput(text)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func shortcut(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(minWidth: 44, minHeight: 36)
        }
        .buttonStyle(.bordered)
    }
}
