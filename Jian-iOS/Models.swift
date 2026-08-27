import Foundation

enum AgentKind: String, CaseIterable, Codable, Identifiable {
    case local
    case codex
    case hermes
    case pi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local"
        case .codex: "Codex"
        case .hermes: "Hermes"
        case .pi: "Pi Agent"
        }
    }

    var symbolName: String {
        switch self {
        case .local: "terminal"
        case .codex: "terminal"
        case .hermes: "message"
        case .pi: "terminal.fill"
        }
    }
}

struct AgentSession: Codable, Identifiable, Hashable {
    let id: String
    let kind: AgentKind
    let nativeID: String?
    let profile: String?
    let src: String?
    let channel: String?
    let workspace: String
    let yolo: Bool?
    let launchArgs: [String]?
    let title: String
    let status: String
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case nativeID = "native_id"
        case profile
        case src
        case channel
        case workspace
        case yolo
        case launchArgs = "launch_args"
        case title
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "-" || value == "—" ? "无标题" : value
    }

    var displayProfile: String {
        (profile?.isEmpty == false ? profile : "default") ?? "default"
    }

    var displayChannel: String {
        let raw = [src, channel, kind == .codex ? "codex" : nil]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未标注"
        let names = ["weixin": "微信", "dingtalk": "钉钉", "telegram": "Telegram", "discord": "Discord", "slack": "Slack", "cli": "CLI", "acp": "ACP", "codex": "Codex"]
        return names[raw.lowercased()] ?? raw
    }

    var lastActivity: Date {
        updatedAt ?? createdAt ?? .distantPast
    }
}

struct AuthStatus: Decodable {
    let authenticated: Bool
    let username: String?
}

struct LoginResponse: Decodable {
    let username: String
}

struct QuickNoteResponse: Decodable {
    let state: String
    let version: Int
}

struct QuickNoteUpdate: Encodable {
    let update: String
}

struct TerminalStatusResponse: Decodable {
    let activePool: [TerminalStatus]

    enum CodingKeys: String, CodingKey {
        case activePool = "active_pool"
    }
}

struct TerminalStatus: Decodable, Identifiable {
    let id: String
    let label: String
    let title: String
    let workspace: String
    let profile: String?
    let running: Bool
    let busy: Bool
    let subscribers: Int

    var statusText: String {
        running ? (busy ? "忙碌" : "空闲") : "已结束"
    }
}

struct EnvironmentVariable: Codable, Hashable {
    var key: String
    var value: String
}

struct AgentSettings: Codable {
    var codexBin: String
    var path: String
    var hermesHome: String
    var hermesBin: String
    var hermesProfiles: [String]
    var piArgs: [String]
    var piEnv: [EnvironmentVariable]
    var localProfiles: [String]
    var codexArgs: [String]
    var hermesArgs: [String]
    var codexEnv: [EnvironmentVariable]
    var hermesEnv: [EnvironmentVariable]
    var localEnabled: Bool
    var codexEnabled: Bool
    var hermesEnabled: Bool
    var piEnabled: Bool
    var agentTogglesSet: Bool?

    enum CodingKeys: String, CodingKey {
        case codexBin = "codex_bin"
        case path
        case hermesHome = "hermes_home"
        case hermesBin = "hermes_bin"
        case hermesProfiles = "hermes_profiles"
        case piArgs = "pi_args"
        case piEnv = "pi_env"
        case localProfiles = "local_profiles"
        case codexArgs = "codex_args"
        case hermesArgs = "hermes_args"
        case codexEnv = "codex_env"
        case hermesEnv = "hermes_env"
        case localEnabled = "local_enabled"
        case codexEnabled = "codex_enabled"
        case hermesEnabled = "hermes_enabled"
        case piEnabled = "pi_enabled"
        case agentTogglesSet = "agent_toggles_set"
    }
}

struct SettingsResponse: Decodable {
    let settings: AgentSettings
    let availableProfiles: [String]
    enum CodingKeys: String, CodingKey {
        case settings
        case availableProfiles = "available_profiles"
    }
}

struct APIErrorResponse: Decodable {
    let error: String
}

struct WorkspaceBrowseResult: Decodable {
    let path: String
    let parent: String
    let entries: [WorkspaceEntry]
}

struct WorkspaceEntry: Decodable, Identifiable, Hashable {
    let name: String
    let directory: Bool

    var id: String { name }
}

struct TerminalEvent: Decodable {
    let sessionID: String?
    let seq: UInt64?
    let type: String
    let payload: EventPayload?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case seq
        case type
        case payload
    }
}

enum EventPayload: Decodable {
    case string(String)
    case dictionary([String: String])
    case ignored

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: String].self) {
            self = .dictionary(value)
        } else {
            self = .ignored
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}

enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}
