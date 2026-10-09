import ChatbotCore
import SwiftUI

/// 设置窗口。#19 先只支持一个 DeepSeek Connection；三个标签页在 #22 里做。
struct SettingsView: View {
    let store: ChatStore

    var body: some View {
        Form {
            DeepSeekConnectionSection(store: store)
            DefaultModelSection(connections: store.connections)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DeepSeekConnectionSection: View {
    let store: ChatStore
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var connection: Connection? {
        store.connections.connections.first { $0.provider == .openAICompatible && $0.baseURL == Connection.deepSeek().baseURL }
    }

    var body: some View {
        Section("DeepSeek") {
            SecureField("API Key", text: $apiKey, prompt: Text(connection == nil ? LocalizedStringKey("sk-…") : "Saved — paste a new key to replace it"))
            HStack {
                if let connection {
                    Text("\(connection.models.count) models available")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save") { Task { await save() } }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
    }

    /// 保存时拉取 Model 列表，这一步同时就是连接测试（SPEC §9）。成功后才写入 Keychain。
    private func save() async {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        var connection = connection ?? Connection.deepSeek()
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            connection.models = try await connection.provider.makeAdapter().listModels(connection, apiKey: key)
            try store.apiKeys.setAPIKey(key, for: connection.id)
            store.connections.save(connection)
            store.connectionsDidChange()
            apiKey = ""
        } catch let error as ChatError {
            errorMessage = error.displayText
        } catch is KeychainError {
            errorMessage = String(localized: "Couldn't save the API key to the Keychain.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DefaultModelSection: View {
    @Bindable var connections: ConnectionStore

    var body: some View {
        Section("Default Model") {
            Picker("Default Model", selection: $connections.defaultModel) {
                ForEach(connections.connections) { connection in
                    ForEach(connections.visibleModels(of: connection)) { model in
                        Text(verbatim: "\(connection.name) / \(model.displayName ?? model.id)")
                            .tag(Optional(ModelRef(connectionID: connection.id, modelID: model.id)))
                    }
                }
            }
            .disabled(connections.connections.isEmpty)
        }
    }
}
