import Foundation

@MainActor
@Observable
final class AppModel {
    let client = UltimationClient()

    var username: String?
    var selectedKind: AgentKind = .codex
    var selectedProfile = UserDefaults.standard.string(forKey: "jian.hermes_profile")
        ?? UserDefaults.standard.string(forKey: "terminalme.hermes_profile")
        ?? "default" {
        didSet { UserDefaults.standard.set(selectedProfile, forKey: "jian.hermes_profile") }
    }
    var selectedWorkspace = UserDefaults.standard.string(forKey: "jian.codex_workspace") ?? "" {
        didSet { UserDefaults.standard.set(selectedWorkspace, forKey: "jian.codex_workspace") }
    }
    var profiles: [String] = ["default"]
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
        return Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func bootstrap() async {
        authState = .loading
        do {
            let status = try await client.authStatus()
            username = status.authenticated ? status.username : nil
            authState = .loaded(username)
            if username != nil {
                await loadProfilesIfNeeded()
                await loadSessions()
            }
        } catch {
            username = nil
            authState = .loaded(nil)
        }
    }

    func login(username: String, password: String) async throws {
        let response = try await client.login(username: username, password: password)
        self.username = response.username
        authState = .loaded(response.username)
        await loadProfilesIfNeeded()
        await loadSessions()
    }

    func logout() async {
        try? await client.logout()
        username = nil
        sessions = []
        sessionsState = .idle
        authState = .loaded(nil)
    }

    func select(kind: AgentKind) async {
        selectedKind = kind
        if kind == .hermes {
            await loadProfilesIfNeeded()
        }
        await loadSessions()
    }

    func loadProfilesIfNeeded() async {
        guard username != nil else { return }
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

    /// The backend refreshes its native catalog as part of the list endpoint.
    /// Keep the argument for callers that distinguish pull-to-refresh from an
    /// ordinary load, but use the single current endpoint for both.
    func loadSessions(refreshNative _: Bool = false) async {
        guard username != nil else { return }
        sessionsState = .loading
        do {
            let loaded = try await client.sessions(kind: selectedKind)
            merge(loaded)
            if selectedKind == .codex {
                selectFirstWorkspaceIfNeeded()
            }
            sessionsState = .loaded(visibleSessions)
        } catch UltimationError.unauthenticated {
            username = nil
            sessionsState = .failed(UltimationError.unauthenticated.localizedDescription)
        } catch {
            sessionsState = .failed(error.localizedDescription)
        }
    }

    func createSession(workspace: String, yolo: Bool = false) async throws -> AgentSession {
        let session = try await client.createSession(kind: selectedKind, workspace: workspace, profile: selectedProfile, yolo: yolo)
        upsert(session)
        if selectedKind == .codex {
            selectedWorkspace = normalizedWorkspace(session.workspace)
        }
        return session
    }

    func stop(_ session: AgentSession) async throws {
        try await client.stop(kind: session.kind, sessionID: session.id)
    }

    func delete(_ session: AgentSession) async throws {
        try await client.delete(kind: session.kind, sessionID: session.id)
        sessions.removeAll { $0.kind == session.kind && $0.id == session.id }
        if selectedKind == .codex && session.kind == .codex {
            selectFirstWorkspaceIfNeeded()
        }
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
        }
    }

    private func selectFirstWorkspaceIfNeeded() {
        guard !workspaces.isEmpty else {
            selectedWorkspace = ""
            return
        }
        if !workspaces.contains(selectedWorkspace) {
            selectedWorkspace = workspaces[0]
        }
    }

    private func normalizedWorkspace(_ workspace: String) -> String {
        let value = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未知工作区" : value
    }
}
