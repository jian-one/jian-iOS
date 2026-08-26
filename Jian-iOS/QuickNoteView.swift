import SwiftUI
import YSwift
import Yniffi

@MainActor
@Observable
final class QuickNoteModel {
    let client: UltimationClient
    let username: String
    private let document = YDocument()
    private let note: YText
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var pending: [String] = []
    private var isFlushing = false

    var value = ""
    var errorMessage = ""

    init(client: UltimationClient, username: String) {
        self.client = client
        self.username = username
        self.note = document.getOrCreateText(named: "body")
    }

    func start() async {
        loadCache()
        do {
            let remote = try await client.quickNote()
            if let update = decode(remote.state) {
                document.transactSync { transaction in
                    try? transaction.transactionApplyUpdate(update: update)
                }
                value = note.getString()
                persist()
            }
            await flush()
        } catch {
            errorMessage = error.localizedDescription
        }
        connectSocket()
    }

    func replace(_ next: String) {
        guard next != value else { return }
        value = next
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.value == next else { return }
            self.updateTask = nil
            self.commit(next)
        }
    }

    private func commit(_ next: String) {
        // ponytail: replace-all edits, fine for a short note; add a text diff if note size becomes a problem.
        let update = document.transactSync { transaction -> [UInt8] in
            let length = self.note.length(in: transaction)
            if length > 0 { self.note.removeRange(start: 0, length: length, in: transaction) }
            if !next.isEmpty { self.note.insert(next, at: 0, in: transaction) }
            return transaction.transactionEncodeUpdate()
        }
        guard !update.isEmpty else { return }
        pending.append(encode(update))
        persist()
        Task { await flush() }
    }

    func stop() {
        if updateTask != nil {
            updateTask?.cancel()
            updateTask = nil
            commit(value)
        }
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        receiveTask = nil
        socket = nil
    }

    private func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let update = pending.first {
            do {
                try await client.saveQuickNote(update: update)
                pending.removeFirst()
                persist()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private func connectSocket() {
        guard socket == nil, let url = try? client.apiWebsocketURL() else { return }
        var request = URLRequest(url: url)
        if let cookie = try? client.cookieHeader() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let object = try? JSONDecoder().decode(QuickNoteSocketEvent.self, from: data),
                      object.type == "quick-note.update",
                      let update = self?.decode(object.update) else { continue }
                self?.applyRemote(update)
            }
        }
    }

    private func applyRemote(_ update: [UInt8]) {
        document.transactSync { transaction in
            try? transaction.transactionApplyUpdate(update: update)
        }
        value = note.getString()
        persist()
    }

    private func loadCache() {
        let defaults = UserDefaults.standard
        let key = "jian.quick-note.\(username)"
        if let state = defaults.string(forKey: "\(key).state"), let update = decode(state) {
            document.transactSync { transaction in try? transaction.transactionApplyUpdate(update: update) }
            value = note.getString()
        }
        pending = defaults.stringArray(forKey: "\(key).pending") ?? []
    }

    private func persist() {
        let key = "jian.quick-note.\(username)"
        let state = document.transactSync { transaction in transaction.transactionEncodeStateAsUpdate() }
        UserDefaults.standard.set(encode(state), forKey: "\(key).state")
        UserDefaults.standard.set(pending, forKey: "\(key).pending")
    }

    private func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decode(_ value: String) -> [UInt8]? {
        var raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        return Data(base64Encoded: raw).map(Array.init)
    }
}

private struct QuickNoteSocketEvent: Decodable {
    let type: String
    let update: String
}

struct QuickNoteButton: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingNote = false

    var body: some View {
        Button { showingNote = true } label: {
            Image(systemName: "note.text")
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("快速笔记")
        .sheet(isPresented: $showingNote) {
            QuickNoteEditor(client: appModel.client, username: appModel.username ?? "")
        }
    }
}

private struct QuickNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: QuickNoteModel

    init(client: UltimationClient, username: String) {
        _model = State(initialValue: QuickNoteModel(client: client, username: username))
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: Binding(get: { model.value }, set: model.replace))
                .padding(8)
                .navigationTitle("快速笔记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !model.errorMessage.isEmpty {
                        Text(model.errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal)
                    }
                }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}
