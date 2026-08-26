import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var appModel
    let kind: AgentKind
    @State private var showingNewSession = false
    @State private var errorMessage = ""
    @State private var selectedSession: AgentSession?

    var body: some View {
        NavigationStack {
            List {
                if kind == .hermes {
                    Section {
                        Picker("Profile", selection: profileBinding) {
                            ForEach(appModel.profiles, id: \.self) { profile in
                                Text(profile).tag(profile)
                            }
                        }
                    }
                }

                if kind == .codex {
                    Section {
                        Picker("工作目录", selection: workspaceBinding) {
                            ForEach(appModel.workspaces, id: \.self) { workspace in
                                Text(workspace).tag(workspace)
                            }
                        }
                    }
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("会话") {
                    if appModel.visibleSessions.isEmpty {
                        ContentUnavailableView("暂无会话", systemImage: kind.symbolName, description: Text(emptyDescription))
                    } else {
                        ForEach(appModel.visibleSessions) { session in
                            NavigationLink(value: session) {
                                SessionRow(session: session)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await delete(session) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(kind.title)
            .navigationDestination(for: AgentSession.self) { session in
                NativeTerminalScreen(session: session)
            }
            .navigationDestination(item: $selectedSession) { session in
                NativeTerminalScreen(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await appModel.loadSessions(refreshNative: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewSession = true
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionView(kind: kind) { session in
                    selectedSession = session
                }
            }
            .refreshable {
                await appModel.loadSessions(refreshNative: true)
            }
        }
    }

    private var profileBinding: Binding<String> {
        Binding {
            appModel.selectedProfile
        } set: { value in
            Task {
                appModel.selectedProfile = value
                await appModel.loadSessions()
            }
        }
    }

    private var workspaceBinding: Binding<String> {
        Binding {
            appModel.selectedWorkspace
        } set: { value in
            appModel.selectedWorkspace = value
        }
    }

    private var emptyDescription: String {
        kind == .local
            ? "新建一个服务器工作目录中的 Bash 终端。"
            : "新建一个服务器工作目录中的 \(kind.title) 会话。"
    }

    private func delete(_ session: AgentSession) async {
        do {
            try await appModel.delete(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(status: session.status)
            }
            Text(session.workspace.isEmpty ? "未知工作区" : session.workspace)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(session.displayChannel)
                if session.kind == .hermes {
                    Text(session.displayProfile)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        let normalized = status.lowercased()
        if normalized == "running" { return "运行中" }
        if normalized == "ended" { return "已结束" }
        if normalized == "idle" { return "待启动" }
        return status
    }

    private var color: Color {
        let normalized = status.lowercased()
        if normalized == "running" { return .green }
        if normalized == "ended" { return .secondary }
        return .orange
    }
}
