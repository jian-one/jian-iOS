import Foundation

@MainActor
@Observable
final class AppModel {
    let client = UltimationClient()

    var username: String?
    var selectedKind: AgentKind = .local
    var selectedProfile = UserDefaults.standard.string(forKey: "jian.hermes_profile")
        ?? UserDefaults.standard.string(forKey: "terminalme.hermes_profile")
        ?? "default" {
        didSet { UserDefaults.standard.set(selectedProfile, forKey: "jian.hermes_profile") }
    }
    var selectedWorkspace = UserDefaults.standard.string(forKey: "jian.codex_workspace") ?? "" {
        didSet { saveWorkspace(selectedWorkspace, for: .codex) }
    }
    var profiles: [String] = ["default"]
    var agentSettings: AgentSettings?
    var sessions: [AgentSession] = []
    var authState: LoadState<String?> = .idle
    var sessionsState: LoadState<[AgentSession]> = .idle

    var isAuthenticated: Bool {
        username != nil
    }

    var visibleSessions: [AgentSession] {
        sessions
            .filter { session in
                session.kind == selectedKind && matchesCurrentGroup(session)
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var workspaces: [String] {
        let values = sessions
            .filter { $0.kind == .codex }
            .map { $0.workspace.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.isEmpty ? "未知工作区" : $0 }
        let remembered = lastWorkspace(for: .codex).map { [$0] } ?? []
        return Array(Set(values + remembered)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func bootstrap() async {
        authState = .loading
        do {
            let status = try await client.authStatus()
            username = status.authenticated ? status.username : nil
            if username == nil { client.clearCookies() }
            if username != nil {
                await loadAgentSettings()
                await loadProfilesIfNeeded()
                await loadSessions()
            }
            authState = .loaded(username)
        } catch {
            username = nil
            authState = .loaded(nil)
        }
    }

    func login(username: String, password: String) async throws {
        let response = try await client.login(username: username, password: password)
        self.username = response.username
        await loadAgentSettings()
        await loadProfilesIfNeeded()
        await loadSessions()
        authState = .loaded(response.username)
    }

    func logout() async {
        try? await client.logout()
        username = nil
        sessions = []
        sessionsState = .idle
        authState = .loaded(nil)
    }

    func select(kind: AgentKind) async {
        guard kind == .local || isEnabled(kind) else { return }
        selectedKind = kind
        if kind == .hermes {
            await loadProfilesIfNeeded()
        }
        await loadSessions(refreshNative: false)
        if kind == .codex {
            selectedWorkspace = lastWorkspace(for: .codex) ?? recentWorkspace() ?? ""
        }
    }

    func loadProfilesIfNeeded() async {
        guard username != nil, isEnabled(.hermes) else {
            profiles = ["default"]
            return
        }
        do {
            let loaded = try await client.profiles()
            profiles = loaded.isEmpty ? ["default"] : loaded
            if !profiles.contains(selectedProfile) {
                selectedProfile = profiles[0]
            }
        } catch {
            profiles = ["default"]
        }
    }

    /// The app keeps a local snapshot for fast startup. Ordinary loads then
    /// read the server's in-memory snapshot, while an explicit refresh asks
    /// the backend to rediscover native sessions.
    func loadSessions(refreshNative: Bool = false) async {
        guard username != nil else { return }

        if !refreshNative, let cached = cachedSessions(for: selectedKind) {
            merge(cached)
            sessionsState = .loaded(visibleSessions)
        }

        sessionsState = .loading
        do {
            let loaded = try await client.sessions(kind: selectedKind, refreshNative: refreshNative)
            merge(loaded)
            saveCachedSessions(loaded, for: selectedKind)
            sessionsState = .loaded(visibleSessions)
        } catch UltimationError.unauthenticated {
            username = nil
            sessionsState = .failed(UltimationError.unauthenticated.localizedDescription)
        } catch {
            sessionsState = .failed(error.localizedDescription)
        }
    }

    func createSession(workspace: String, yolo: Bool = false, launchArgs: [String]? = nil) async throws -> AgentSession {
        let session = try await client.createSession(kind: selectedKind, workspace: workspace, profile: selectedProfile, yolo: yolo, launchArgs: launchArgs)
        upsert(session)
        saveCachedSessions(sessions.filter { $0.kind == session.kind }, for: session.kind)
        rememberWorkspace(session.workspace, for: session.kind)
        if selectedKind == .codex { selectedWorkspace = normalizedWorkspace(session.workspace) }
        return session
    }

    func lastWorkspace(for kind: AgentKind) -> String? {
        let key = workspaceKey(for: kind)
        let value = UserDefaults.standard.string(forKey: key)
            ?? (kind == .codex ? UserDefaults.standard.string(forKey: "jian.codex_workspace") : nil)
        let workspace = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return workspace.isEmpty ? nil : workspace
    }

    func stop(_ session: AgentSession) async throws {
        try await client.stop(kind: session.kind, sessionID: session.id)
    }

    func restart(_ session: AgentSession) async throws {
        try await client.restartTerminal(sessionID: session.id)
    }

    func release(_ session: AgentSession) async throws {
        try await client.releaseTerminal(sessionID: session.id)
        if session.kind == .local {
            sessions.removeAll { $0.kind == .local && $0.id == session.id }
            saveCachedSessions(sessions.filter { $0.kind == .local }, for: .local)
        } else if session.kind == selectedKind {
            await loadSessions(refreshNative: true)
        }
    }

    func release(_ terminal: TerminalStatus) async throws {
        try await client.releaseTerminal(sessionID: terminal.id)
        if terminal.label == AgentKind.local.rawValue {
            sessions.removeAll { $0.kind == .local && $0.id == terminal.id }
            saveCachedSessions(sessions.filter { $0.kind == .local }, for: .local)
        } else if let kind = AgentKind(rawValue: terminal.label), kind == selectedKind {
            await loadSessions(refreshNative: true)
        }
    }

    func releaseAllTerminals() async throws {
        try await client.releaseAllTerminals()
        sessions.removeAll { $0.kind == .local }
        saveCachedSessions([], for: .local)
        if selectedKind == .local { sessionsState = .loaded([]) }
    }

    func delete(_ session: AgentSession) async throws {
        try await client.delete(kind: session.kind, sessionID: session.id)
        sessions.removeAll { $0.kind == session.kind && $0.id == session.id }
        saveCachedSessions(sessions.filter { $0.kind == session.kind }, for: session.kind)
    }

    private func merge(_ loaded: [AgentSession]) {
        sessions.removeAll { $0.kind == selectedKind }
        sessions.append(contentsOf: loaded)
    }

    private func upsert(_ session: AgentSession) {
        sessions.removeAll { $0.kind == session.kind && $0.id == session.id }
        sessions.insert(session, at: 0)
    }

    private func matchesCurrentGroup(_ session: AgentSession) -> Bool {
        switch selectedKind {
        case .hermes:
            return session.displayProfile == selectedProfile
        case .codex:
            return selectedWorkspace.isEmpty || normalizedWorkspace(session.workspace) == selectedWorkspace
        case .local:
            return true
        case .pi:
            return true
        }
    }

    func isEnabled(_ kind: AgentKind) -> Bool {
        switch kind {
        case .local: true
        case .codex: agentSettings?.codexEnabled ?? false
        case .hermes: agentSettings?.hermesEnabled ?? false
        case .pi: agentSettings?.piEnabled ?? false
        }
    }

    func loadAgentSettings() async {
        guard username != nil else { return }
        if let response = try? await client.settings() {
            agentSettings = response.settings
        }
    }

    private func recentWorkspace() -> String? {
        guard let recent = sessions
            .filter({ $0.kind == .codex })
            .max(by: { $0.lastActivity < $1.lastActivity })
        else { return nil }
        return normalizedWorkspace(recent.workspace)
    }

    private func normalizedWorkspace(_ workspace: String) -> String {
        let value = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未知工作区" : value
    }

    private func cacheKey(for kind: AgentKind) -> String {
        "jian.session_cache.\(username ?? "anonymous").\(kind.rawValue)"
    }

    private func cachedSessions(for kind: AgentKind) -> [AgentSession]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: kind)) else { return nil }
        return try? JSONDecoder().decode([AgentSession].self, from: data)
    }

    private func saveCachedSessions(_ value: [AgentSession], for kind: AgentKind) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(for: kind))
    }

    private func workspaceKey(for kind: AgentKind) -> String {
        "jian.last_workspace.\(username ?? "anonymous").\(kind.rawValue)"
    }

    private func rememberWorkspace(_ workspace: String, for kind: AgentKind) {
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return }
        UserDefaults.standard.set(workspace, forKey: workspaceKey(for: kind))
    }

    private func saveWorkspace(_ workspace: String, for kind: AgentKind) {
        guard username != nil else { return }
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.isEmpty {
            UserDefaults.standard.removeObject(forKey: workspaceKey(for: kind))
        } else {
            UserDefaults.standard.set(workspace, forKey: workspaceKey(for: kind))
        }
    }
}
