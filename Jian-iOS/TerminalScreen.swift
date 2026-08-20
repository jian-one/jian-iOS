import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let session: AgentSession
    @State private var socket: TerminalSocket?
    @State private var errorMessage = ""
    @State private var isReleasing = false

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
                Menu {
                    Button {
                        socket?.reconnect()
                    } label: {
                        Label("刷新会话", systemImage: "arrow.clockwise")
                    }

                    Button {
                        Task { await restart() }
                    } label: {
                        Label("重启会话", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button(role: .destructive) {
                        Task { await release() }
                    } label: {
                        Label("释放会话", systemImage: "xmark.circle")
                    }
                    .disabled(isReleasing)

                    Divider()

                    Button {
                        Task { await stop() }
                    } label: {
                        Label("停止会话", systemImage: "stop.fill")
                    }
                } label: {
                    Label("终端操作", systemImage: "ellipsis")
                }
                .disabled(socket == nil)
            }
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

    private func stop() async {
        do {
            try await appModel.stop(session)
            socket?.sendInterrupt()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restart() async {
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
