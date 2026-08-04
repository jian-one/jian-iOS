import SwiftUI

struct NewSessionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let kind: AgentKind

    @State private var workspace = "~"
    @State private var currentPath = ""
    @State private var parentPath = ""
    @State private var entries: [WorkspaceEntry] = []
    @State private var isBrowsing = false
    @State private var isCreating = false
    @State private var errorMessage = ""
    @State private var yolo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("~/project", text: $workspace)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await browse(workspace) }
                        }
                    HStack {
                        Button {
                            Task { await browse("~") }
                        } label: {
                            Label("Home", systemImage: "house")
                        }
                        Button {
                            Task { await browse(parentPath) }
                        } label: {
                            Label("上级", systemImage: "chevron.up")
                        }
                        .disabled(parentPath.isEmpty || parentPath == currentPath)
                        Spacer()
                        Button {
                            Task { await browse(workspace) }
                        } label: {
                            Label("前往", systemImage: "arrow.right")
                        }
                        .disabled(workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBrowsing)
                    }
                } header: {
                    Text("服务器工作目录")
                } footer: {
                    Text("路径在 ultimation 服务器上解析，可手输或从远端目录中选择。")
                }

                let recent = recentWorkspaces
                if !recent.isEmpty {
                    Section("已有对话目录") {
                        ForEach(recent, id: \.self) { path in
                            Button {
                                workspace = path
                                Task { await browse(path) }
                            } label: {
                                Label(path, systemImage: "clock")
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section {
                    if isBrowsing {
                        HStack {
                            ProgressView()
                            Text("正在读取目录")
                        }
                    } else if entries.isEmpty {
                        ContentUnavailableView("没有子目录", systemImage: "folder")
                    } else {
                        ForEach(entries.filter(\.directory)) { entry in
                            Button {
                                let next = currentPath == "/" ? "/\(entry.name)" : "\(currentPath)/\(entry.name)"
                                workspace = next
                                Task { await browse(next) }
                            } label: {
                                Label(entry.name, systemImage: "folder")
                            }
                        }
                    }
                } header: {
                    Text(currentPath.isEmpty ? "远端目录" : currentPath)
                }

                if kind == .hermes {
                    Section("Profile") {
                        Text(appModel.selectedProfile)
                    }
                }

                if kind == .codex {
                    Section {
                        Toggle("跳过权限确认（YOLO）", isOn: $yolo)
                    } footer: {
                        Text("仅在你信任该服务器工作目录时启用。")
                    }
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建 \(kind.title)")
            .task {
                await browse(workspace)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "创建中" : "创建") {
                        Task { await create() }
                    }
                    .disabled(isCreating || workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var recentWorkspaces: [String] {
        var seen: Set<String> = []
        return appModel.sessions
            .filter { !$0.workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.lastActivity > $1.lastActivity }
            .compactMap { session in
                guard seen.insert(session.workspace).inserted else { return nil }
                return session.workspace
            }
    }

    private func browse(_ path: String) async {
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        isBrowsing = true
        errorMessage = ""
        do {
            let result = try await appModel.client.browseWorkspace(path: target)
            currentPath = result.path
            parentPath = result.parent
            workspace = result.path
            entries = result.entries.filter(\.directory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
        isBrowsing = false
    }

    private func create() async {
        isCreating = true
        errorMessage = ""
        do {
            _ = try await appModel.createSession(workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines), yolo: yolo)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }
}
