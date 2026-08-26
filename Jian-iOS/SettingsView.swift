import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var serverURL = ""
    @State private var settings: AgentSettings?
    @State private var availableProfiles: [String] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var message: String?
    @State private var codexExpanded = true
    @State private var hermesExpanded = true
    @State private var piExpanded = true
    @State private var availablePiAgents: [String] = []
    @State private var terminals: [TerminalStatus] = []
    @State private var isLoadingTerminals = false
    @State private var showingReleaseAll = false
    @State private var showingPath = false
    @State private var selectedTerminalSession: AgentSession?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("https://ultimation.example.com", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存服务器地址") {
                        appModel.client.serverURLString = serverURL
                    }
                }

                if isLoading {
                    Section { ProgressView("正在读取 Agent 设置…") }
                } else if let settingsBinding = Binding($settings) {
                    Section("Local") {
                        LabeledContent("系统用户名", value: appModel.username ?? "未知用户")
                        LabeledContent("启动时的 PATH") {
                            let path = settingsBinding.path.wrappedValue
                            Button {
                                showingPath = true
                            } label: {
                                Text(path.isEmpty ? "未设置" : path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 180, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(path.isEmpty)
                            .popover(isPresented: $showingPath, arrowEdge: .trailing) {
                                Text(path)
                                    .textSelection(.enabled)
                                    .padding()
                                    .frame(maxWidth: 320)
                            }
                        }
                        StringListEditor(title: "自动加载的 profile 文件", values: settingsBinding.localProfiles, fixedFirst: true, placeholder: "~/.profile")
                        saveButton("Local")
                    }

                    Section {
                        DisclosureGroup(isExpanded: $codexExpanded) {
                            TextField("CODEX_BIN", text: settingsBinding.codexBin)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            EnvironmentEditor(values: settingsBinding.codexEnv)
                            StringListEditor(title: "启动参数", values: settingsBinding.codexArgs, placeholder: "--model")
                            saveButton("Codex")
                        } label: {
                            Toggle("启用 Codex", isOn: settingsBinding.codexEnabled)
                        }
                    }
                    .onChange(of: settingsBinding.wrappedValue.codexEnabled) { _, enabled in
                        if !enabled { codexExpanded = false }
                    }

                    Section {
                        DisclosureGroup(isExpanded: $hermesExpanded) {
                            TextField("HERMES_HOME", text: settingsBinding.hermesHome)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("HERMES_BIN", text: settingsBinding.hermesBin)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            EnvironmentEditor(values: settingsBinding.hermesEnv)
                            StringListEditor(title: "启动参数", values: settingsBinding.hermesArgs, placeholder: "启动参数")
                            if !availableProfiles.isEmpty {
                                DisclosureGroup("显示会话的 profiles") {
                                    ForEach(availableProfiles, id: \.self) { profile in
                                        Toggle(profile, isOn: profileBinding(profile, settings: settingsBinding))
                                    }
                                }
                            }
                            saveButton("Hermes")
                        } label: {
                            Toggle("启用 Hermes", isOn: settingsBinding.hermesEnabled)
                        }
                    }
                    .onChange(of: settingsBinding.wrappedValue.hermesEnabled) { _, enabled in
                        if !enabled { hermesExpanded = false }
                    }

                    Section {
                        DisclosureGroup(isExpanded: $piExpanded) {
                            TextField("PI_BIN", text: settingsBinding.piBin)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            EnvironmentEditor(values: settingsBinding.piEnv)
                            StringListEditor(title: "启动参数", values: settingsBinding.piArgs, placeholder: "启动参数")
                            if !availablePiAgents.isEmpty {
                                DisclosureGroup("显示 Pi agents") {
                                    ForEach(availablePiAgents, id: \.self) { agent in
                                        Text(agent)
                                    }
                                }
                            }
                            saveButton("Pi Agent")
                        } label: {
                            Toggle("启用 Pi Agent", isOn: settingsBinding.piEnabled)
                        }
                    }
                    .onChange(of: settingsBinding.wrappedValue.piEnabled) { _, enabled in
                        if !enabled { piExpanded = false }
                    }
                }

                Section {
                    if isLoadingTerminals {
                        ProgressView("正在读取终端…")
                    } else if terminals.isEmpty {
                        ContentUnavailableView("暂无活动终端", systemImage: "terminal")
                    } else {
                        ForEach(terminals) { terminal in
                            Button { open(terminal) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(terminal.title.isEmpty ? terminal.id : terminal.title)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(terminal.statusText)
                                            .font(.caption)
                                            .foregroundStyle(terminal.running ? (terminal.busy ? .orange : .green) : .secondary)
                                    }
                                    Text("\(terminal.label) · \(terminal.subscribers) 个连接")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !terminal.workspace.isEmpty {
                                        Text(terminal.workspace)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await release(terminal) }
                                } label: {
                                    Label("释放", systemImage: "xmark.circle")
                                }
                            }
                        }
                        Button("释放全部终端", role: .destructive) {
                            showingReleaseAll = true
                        }
                    }
                } header: {
                    HStack {
                        Text("终端管理")
                        Spacer()
                        Button { Task { await loadTerminalStatus() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoadingTerminals)
                    }
                } footer: {
                    Text("左滑单个终端可释放；释放会中断正在执行的命令。")
                }

                if let message {
                    Section { Text(message).foregroundStyle(message == "设置已保存" ? Color.secondary : Color.red) }
                }

                Section("账号") {
                    LabeledContent("登录用户", value: appModel.username ?? "未登录")
                    Button("退出登录", role: .destructive) {
                        Task { await appModel.logout() }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationDestination(item: $selectedTerminalSession) { session in
                NativeTerminalScreen(session: session)
            }
            .onAppear {
                serverURL = appModel.client.serverURLString
            }
            .task(id: appModel.username) {
                guard appModel.username != nil else { return }
                await loadSettings()
                await loadTerminalStatus()
            }
            .refreshable {
                await loadSettings()
                await loadTerminalStatus()
            }
            .confirmationDialog("释放全部终端？", isPresented: $showingReleaseAll) {
                Button("释放全部", role: .destructive) {
                    Task { await releaseAll() }
                }
            } message: {
                Text("所有正在运行的终端会被中断。")
            }
        }
    }

    @ViewBuilder
    private func saveButton(_ name: String) -> some View {
        Button(isSaving ? "正在保存…" : "保存 \(name) 设置") {
            Task { await saveSettings() }
        }
        .disabled(isSaving)
    }

    private func loadSettings() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await appModel.client.settings()
            settings = response.settings
            availableProfiles = response.availableProfiles
            availablePiAgents = response.availablePiAgents
            appModel.agentSettings = response.settings
            codexExpanded = response.settings.codexEnabled
            hermesExpanded = response.settings.hermesEnabled
            piExpanded = response.settings.piEnabled
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveSettings() async {
        guard let settings else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            self.settings = try await appModel.client.saveSettings(settings)
            appModel.agentSettings = self.settings
            if !self.settings!.codexEnabled { codexExpanded = false }
            if !self.settings!.hermesEnabled { hermesExpanded = false }
            if !self.settings!.piEnabled { piExpanded = false }
            message = "设置已保存"
            await appModel.loadProfilesIfNeeded()
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadTerminalStatus() async {
        isLoadingTerminals = true
        defer { isLoadingTerminals = false }
        do {
            terminals = try await appModel.client.terminalStatus().activePool
        } catch {
            message = error.localizedDescription
        }
    }

    private func release(_ terminal: TerminalStatus) async {
        do {
            try await appModel.release(terminal)
            await loadTerminalStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    private func releaseAll() async {
        do {
            try await appModel.releaseAllTerminals()
            terminals = []
        } catch {
            message = error.localizedDescription
        }
    }

    private func open(_ terminal: TerminalStatus) {
        guard let kind = AgentKind(rawValue: terminal.label) else { return }
        selectedTerminalSession = AgentSession(
            id: terminal.id,
            kind: kind,
            nativeID: nil,
            profile: terminal.profile,
            src: nil,
            channel: nil,
            workspace: terminal.workspace,
            yolo: nil,
            launchArgs: nil,
            title: terminal.title,
            status: terminal.running ? "running" : "ended",
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func profileBinding(_ profile: String, settings: Binding<AgentSettings>) -> Binding<Bool> {
        Binding(
            get: { settings.wrappedValue.hermesProfiles.contains(profile) },
            set: { selected in
                if selected {
                    if !settings.wrappedValue.hermesProfiles.contains(profile) {
                        settings.wrappedValue.hermesProfiles.append(profile)
                    }
                } else {
                    settings.wrappedValue.hermesProfiles.removeAll { $0 == profile }
                }
            }
        )
    }
}

private struct StringListEditor: View {
    let title: String
    @Binding var values: [String]
    var fixedFirst = false
    let placeholder: String

    var body: some View {
        DisclosureGroup(title) {
            ForEach(values.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: $values[index])
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(fixedFirst && index == 0)
                    if !fixedFirst || index > 0 {
                        Button(role: .destructive) { values.remove(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                }
            }
            Button("添加", systemImage: "plus") { values.append("") }
        }
    }
}

private struct EnvironmentEditor: View {
    @Binding var values: [EnvironmentVariable]

    var body: some View {
        DisclosureGroup("环境变量") {
            ForEach(values.indices, id: \.self) { index in
                HStack {
                    TextField("KEY", text: $values[index].key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("VALUE", text: $values[index].value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(role: .destructive) { values.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            Button("添加", systemImage: "plus") { values.append(EnvironmentVariable(key: "", value: "")) }
        }
    }
}
