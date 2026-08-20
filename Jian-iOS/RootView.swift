import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            switch appModel.authState {
            case .idle, .loading:
                ProgressView("正在检查登录状态")
            case .loaded:
                if appModel.isAuthenticated {
                    MainTabsView()
                } else {
                    LoginView()
                }
            case .failed:
                LoginView()
            }
        }
        .task {
            await appModel.bootstrap()
        }
    }
}

struct MainTabsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedTab: AppTab = .local

    var body: some View {
        TabView(selection: $selectedTab) {
            SessionsView(kind: .local)
                .tabItem { Label("Local", systemImage: "terminal") }
                .tag(AppTab.local)

            if appModel.isEnabled(.codex) {
                SessionsView(kind: .codex)
                    .tabItem { Label("Codex", systemImage: "terminal") }
                    .tag(AppTab.codex)
            }

            if appModel.isEnabled(.hermes) {
                SessionsView(kind: .hermes)
                    .tabItem { Label("Hermes", systemImage: "message") }
                    .tag(AppTab.hermes)
            }

            if appModel.isEnabled(.pi) {
                SessionsView(kind: .pi)
                    .tabItem { Label("Pi Agent", systemImage: "terminal.fill") }
                    .tag(AppTab.pi)
            }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onChange(of: selectedTab) { _, value in
            Task {
                switch value {
                case .local:
                    await appModel.select(kind: .local)
                case .codex:
                    await appModel.select(kind: .codex)
                case .hermes:
                    await appModel.select(kind: .hermes)
                case .pi:
                    await appModel.select(kind: .pi)
                case .settings:
                    break
                }
            }
        }
        .onChange(of: appModel.isEnabled(.codex)) { _, enabled in
            if !enabled, selectedTab == .codex { selectedTab = .local }
        }
        .onChange(of: appModel.isEnabled(.hermes)) { _, enabled in
            if !enabled, selectedTab == .hermes { selectedTab = .local }
        }
        .onChange(of: appModel.isEnabled(.pi)) { _, enabled in
            if !enabled, selectedTab == .pi { selectedTab = .local }
        }
        .overlay(alignment: .bottomTrailing) {
            QuickNoteButton().padding(.trailing, 18).padding(.bottom, 72)
        }
    }
}

private enum AppTab: Hashable {
    case local
    case codex
    case hermes
    case pi
    case settings
}
