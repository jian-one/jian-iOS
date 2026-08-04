import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var appModel
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://ultimation.example.com", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                } header: {
                    Text("连接")
                } footer: {
                    Text("首版只连接公网 HTTPS ultimation 服务。登录会使用服务端现有 Cookie Session。")
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("登录")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Jian-iOS")
            .onAppear {
                serverURL = appModel.client.serverURLString
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = ""
        appModel.client.serverURLString = serverURL
        do {
            try await appModel.login(username: username, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}
