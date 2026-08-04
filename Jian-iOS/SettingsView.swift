import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var serverURL = ""

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

                Section("账号") {
                    LabeledContent("登录用户", value: appModel.username ?? "未登录")
                    Button("退出登录", role: .destructive) {
                        Task { await appModel.logout() }
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                serverURL = appModel.client.serverURLString
            }
        }
    }
}
