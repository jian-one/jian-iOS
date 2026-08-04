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
    @State private var selectedTab: AppTab = .codex

    var body: some View {
        TabView(selection: $selectedTab) {
            SessionsView(kind: .local)
                .tabItem { Label("终端", systemImage: "terminal") }
                .tag(AppTab.local)

            SessionsView(kind: .codex)
                .tabItem { Label("Codex", systemImage: "terminal") }
                .tag(AppTab.codex)

            SessionsView(kind: .hermes)
                .tabItem { Label("Hermes", systemImage: "message") }
                .tag(AppTab.hermes)

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
                case .settings:
                    break
                }
            }
        }
    }
}

private enum AppTab: Hashable {
    case local
    case codex
    case hermes
    case settings
}
