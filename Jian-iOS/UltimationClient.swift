import Foundation

enum UltimationError: LocalizedError {
    case invalidServerURL
    case insecureServerURL
    case missingServerURL
    case unauthenticated
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "服务器地址无效"
        case .insecureServerURL: "首版只支持 HTTPS 服务器地址"
        case .missingServerURL: "请先填写服务器地址"
        case .unauthenticated: "登录已过期，请重新登录"
        case .requestFailed(let message): message
        }
    }
}

struct NewSessionRequest: Encodable {
    let workspace: String
    let profile: String?
    let yolo: Bool?
}

@MainActor
@Observable
final class UltimationClient {
    var serverURLString: String {
        didSet {
            UserDefaults.standard.set(serverURLString, forKey: Self.serverURLKey)
        }
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    private static let serverURLKey = "jian.server_url"
    private static let legacyServerURLKey = "terminalme.server_url"

    init(session: URLSession = .shared) {
        self.session = session
        self.serverURLString = UserDefaults.standard.string(forKey: Self.serverURLKey)
            ?? UserDefaults.standard.string(forKey: Self.legacyServerURLKey)
            ?? ""
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    var hasServerURL: Bool {
        !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        try await request("/auth/login", method: "POST", body: ["username": username, "password": password])
    }

    func logout() async throws {
        let _: EmptyResponse = try await request("/auth/logout", method: "POST")
        clearCookies()
    }

    func authStatus() async throws -> AuthStatus {
        try await request("/auth/status")
    }

    func profiles() async throws -> [String] {
        try await request("/hermes/profiles")
    }

    func settings() async throws -> SettingsResponse {
        try await request("/settings")
    }

    func saveSettings(_ settings: AgentSettings) async throws -> AgentSettings {
        try await request("/settings", method: "PUT", body: settings)
    }

    func quickNote() async throws -> QuickNoteResponse {
        try await request("/quick-note")
    }

    func saveQuickNote(update: String) async throws {
        let _: EmptyResponse = try await request(
            "/quick-note",
            method: "PUT",
            body: QuickNoteUpdate(update: update)
        )
    }

    func apiWebsocketURL() throws -> URL {
        guard var components = URLComponents(url: try normalizedBaseURL(), resolvingAgainstBaseURL: false) else {
            throw UltimationError.invalidServerURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/ws"
        guard let url = components.url else { throw UltimationError.invalidServerURL }
        return url
    }

    /// Loads the server's current session snapshot. Native agent sessions are
    /// refreshed explicitly because GET now serves the server-side cache.
    func sessions(kind: AgentKind, refreshNative: Bool = false) async throws -> [AgentSession] {
        if kind == .local {
            return try await request("/local/sessions")
        }
        if refreshNative {
            return try await request("/agents/\(kind.rawValue)/sessions/refresh", method: "POST")
        }
        return try await request("/agents/\(kind.rawValue)/sessions")
    }

    func createSession(kind: AgentKind, workspace: String, profile: String?, yolo: Bool = false) async throws -> AgentSession {
        if kind == .local {
            return try await request("/local/sessions", method: "POST", body: NewSessionRequest(workspace: workspace, profile: nil, yolo: nil))
        }
        return try await request(
            "/agents/\(kind.rawValue)/sessions",
            method: "POST",
            body: NewSessionRequest(workspace: workspace, profile: kind == .hermes ? profile : nil, yolo: kind == .codex ? yolo : nil)
        )
    }

    func browseWorkspace(path: String) async throws -> WorkspaceBrowseResult {
        var components = URLComponents()
        components.path = "/workspaces/browse"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let pathWithQuery = components.string else {
            throw UltimationError.invalidServerURL
        }
        return try await request(pathWithQuery)
    }

    func stop(kind: AgentKind, sessionID: String) async throws {
        guard kind != .local else { return }
        let _: EmptyResponse = try await request("\(agentSessionPath(kind: kind, sessionID: sessionID))/stop", method: "POST")
    }

    func restartTerminal(sessionID: String) async throws {
        let _: EmptyResponse = try await request(
            "/settings/terminals/\(encodedPathComponent(sessionID))/restart",
            method: "POST"
        )
    }

    func releaseTerminal(sessionID: String) async throws {
        let _: EmptyResponse = try await request(
            "/settings/terminals/\(encodedPathComponent(sessionID))/release",
            method: "POST"
        )
    }

    func terminalStatus() async throws -> TerminalStatusResponse {
        try await request("/settings/terminal-status")
    }

    func releaseAllTerminals() async throws {
        let _: EmptyResponse = try await request("/settings/terminals/release-all", method: "POST")
    }

    func delete(kind: AgentKind, sessionID: String) async throws {
        if kind == .local {
            let _: EmptyResponse = try await request("/local/sessions/\(encodedPathComponent(sessionID))", method: "DELETE")
            return
        }
        let _: EmptyResponse = try await request(agentSessionPath(kind: kind, sessionID: sessionID), method: "DELETE")
    }

    func websocketURL(kind: AgentKind, sessionID: String) throws -> URL {
        let base = try normalizedBaseURL()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        if kind == .local {
            components?.percentEncodedPath = "/api/local/sessions/\(encodedPathComponent(sessionID))/terminal"
        } else {
            components?.percentEncodedPath = "/api/agents/\(kind.rawValue)/sessions/\(encodedPathComponent(sessionID))/terminal"
        }
        guard let url = components?.url else {
            throw UltimationError.invalidServerURL
        }
        return url
    }

    func cookieHeader() throws -> String? {
        let base = try normalizedBaseURL()
        guard let cookies = HTTPCookieStorage.shared.cookies(for: base), !cookies.isEmpty else {
            return nil
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func clearCookies() {
        guard let base = try? normalizedBaseURL(),
              let cookies = HTTPCookieStorage.shared.cookies(for: base)
        else { return }
        cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    private func request<T: Decodable, B: Encodable>(_ path: String, method: String = "GET", body: B? = Optional<String>.none) async throws -> T {
        let base = try normalizedBaseURL()
        guard let url = URL(string: "/api\(path)", relativeTo: base) else {
            throw UltimationError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UltimationError.requestFailed("服务器响应无效")
        }
        if http.statusCode == 401 {
            throw UltimationError.unauthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? decoder.decode(APIErrorResponse.self, from: data)
            throw UltimationError.requestFailed(apiError?.error ?? "请求失败：HTTP \(http.statusCode)")
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }

    private func normalizedBaseURL() throws -> URL {
        let raw = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw UltimationError.missingServerURL }
        guard let url = URL(string: raw), url.host != nil else { throw UltimationError.invalidServerURL }
        guard url.scheme?.lowercased() == "https" else { throw UltimationError.insecureServerURL }
        return url
    }

    private func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func agentSessionPath(kind: AgentKind, sessionID: String) -> String {
        "/agents/\(kind.rawValue)/sessions/\(encodedPathComponent(sessionID))"
    }
}

private struct EmptyResponse: Decodable {}
