import ChatbotCore
import SwiftUI

/// Connection 页：左边是 Connection 列表和「+」模板菜单，右边编辑选中的 Connection（SPEC §9）。
struct ConnectionsSettingsView: View {
    let chat: ChatStore
    let history: HistoryModel
    @Bindable var navigation: SettingsNavigation

    @State private var selection: UUID?
    /// 正在编辑的 Connection。新建的在保存之前只存在这里。
    @State private var draft: ConnectionDraft?

    private var connections: ConnectionStore { chat.connections }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(connections.connections) { connection in
                        Text(verbatim: connection.name).tag(connection.id)
                    }
                    if let draft, draft.isNew {
                        Text(verbatim: draft.name).italic().tag(draft.id)
                    }
                }
                Divider()
                HStack {
                    Menu {
                        ForEach(ConnectionTemplate.allCases) { template in
                            Button(template.title) { startNew(from: template) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add Connection")
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 190)

            Divider()

            if let binding = Binding($draft) {
                ConnectionEditor(draft: binding, chat: chat, history: history) { savedID in
                    selection = savedID
                } onDeleted: { deletedDefaultModel in
                    draft = nil
                    selection = connections.connections.first?.id
                    // Default Model 跟着 Connection 一起没了：到通用页重新选
                    if deletedDefaultModel, !connections.connections.isEmpty { navigation.tab = .general }
                } onDefaultModelRemoved: {
                    navigation.tab = .general
                }
                .id(binding.wrappedValue.id)
            } else {
                ContentUnavailableView {
                    Label("No Connection", systemImage: "network")
                } description: {
                    Text("Add a Connection with the + button, then paste your API key.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            applyPendingTemplate()
            applyPendingConnection()
            if selection == nil, draft == nil { selection = connections.connections.first?.id }
        }
        .onChange(of: navigation.pendingTemplate) { applyPendingTemplate() }
        .onChange(of: navigation.pendingConnectionID) { applyPendingConnection() }
        .onChange(of: selection) { loadDraft(for: selection) }
    }

    private func startNew(from template: ConnectionTemplate) {
        let newDraft = ConnectionDraft(template: template)
        draft = newDraft
        selection = newDraft.id
    }

    /// 首次启动或从 Quick Panel 点「添加 Connection…」：预选模板（SPEC §10）。
    private func applyPendingTemplate() {
        guard let template = navigation.pendingTemplate else { return }
        navigation.pendingTemplate = nil
        startNew(from: template)
    }

    /// 从回答旁边的「打开设置」过来：选中那个对话用的 Connection。
    private func applyPendingConnection() {
        guard let connectionID = navigation.pendingConnectionID else { return }
        navigation.pendingConnectionID = nil
        if connections.connection(id: connectionID) != nil { selection = connectionID }
    }

    private func loadDraft(for id: UUID?) {
        guard let id else {
            draft = nil
            return
        }
        if draft?.id == id { return }
        draft = connections.connection(id: id).map {
            ConnectionDraft(connection: $0, manualModelIDs: connections.manualModelIDs(of: $0.id))
        }
    }
}

/// 编辑中的 Connection。API key 单独放着，留空表示沿用 Keychain 里已经保存的。
struct ConnectionDraft {
    let id: UUID
    var name: String
    var provider: Provider
    var baseURL: String
    var apiKey = ""
    var models: [ModelInfo]
    var hiddenModelIDs: Set<String>
    /// 用户手动填写的模型 ID，重新拉取时保留。
    var manualModelIDs: [String]
    /// 还没保存过。
    var isNew: Bool
    let allowsChoosingProvider: Bool

    init(template: ConnectionTemplate) {
        let connection = template.makeConnection()
        id = connection.id
        name = connection.name
        provider = connection.provider
        baseURL = template == .custom ? "" : connection.baseURL.absoluteString
        models = []
        hiddenModelIDs = []
        manualModelIDs = []
        isNew = true
        allowsChoosingProvider = template.allowsChoosingProvider
    }

    init(connection: Connection, manualModelIDs: [String]) {
        id = connection.id
        name = connection.name
        provider = connection.provider
        baseURL = connection.baseURL.absoluteString
        models = connection.models
        hiddenModelIDs = connection.hiddenModelIDs
        self.manualModelIDs = manualModelIDs
        isNew = false
        allowsChoosingProvider = false
    }

    /// base URL 不是合法的 http(s) 地址时返回 nil。
    func makeConnection() -> Connection? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http", url.host() != nil
        else { return nil }
        let name = name.trimmingCharacters(in: .whitespaces)
        return Connection(
            id: id,
            name: name.isEmpty ? (url.host() ?? "") : name,
            provider: provider,
            baseURL: url,
            hiddenModelIDs: hiddenModelIDs,
            models: models
        )
    }
}

private struct ConnectionEditor: View {
    @Binding var draft: ConnectionDraft
    let chat: ChatStore
    let history: HistoryModel
    let onSaved: (UUID) -> Void
    /// 参数：被删掉的 Connection 里是否有 Default Model。
    let onDeleted: (Bool) -> Void
    /// 删掉的手动 Model 正好是 Default Model。
    let onDefaultModelRemoved: () -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?
    /// 拉取 Model 列表失败之后，允许不测试直接保存，再手动填写模型 ID。
    @State private var canSaveWithoutTesting = false
    @State private var manualModelID = ""
    @State private var isConfirmingDelete = false
    /// Keychain 里是否已经有这个 Connection 的 key。出现时读一次，保存新 key 后更新，不在每次重绘时查 Keychain。
    @State private var hasSavedKey = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                if draft.allowsChoosingProvider {
                    Picker("Provider", selection: $draft.provider) {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            Text(verbatim: provider.displayName).tag(provider)
                        }
                    }
                } else {
                    LabeledContent("Provider") { Text(verbatim: draft.provider.displayName) }
                }
                TextField("Base URL", text: $draft.baseURL, prompt: Text(verbatim: "https://"))
                SecureField(
                    "API Key",
                    text: $draft.apiKey,
                    prompt: Text(hasSavedKey ? LocalizedStringKey("Saved — paste a new key to replace it") : "Paste your API key")
                )
                HStack {
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    if canSaveWithoutTesting {
                        Button("Save Without Testing") { Task { await save(testing: false) } }
                            .disabled(isSaving)
                    }
                    Button("Save") { Task { await save(testing: true) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                }
            } footer: {
                Text("Saving fetches the model list, which also tests the connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                if draft.models.isEmpty {
                    Text("No models yet. Save to fetch them, or add a model ID below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.models) { model in
                    HStack {
                        Toggle(isOn: visibility(of: model.id)) {
                            HStack(spacing: 6) {
                                Text(verbatim: model.displayName ?? model.id)
                                if model.capabilities.imageInput {
                                    Image(systemName: "photo").foregroundStyle(.secondary).help("Accepts images")
                                }
                                if model.capabilities.webSearch {
                                    Image(systemName: "globe").foregroundStyle(.secondary).help("Can search the web")
                                }
                            }
                        }
                        // 只有手动填写的可以删掉；拉取到的用勾选来隐藏
                        if draft.manualModelIDs.contains(model.id) {
                            Button {
                                removeManualModel(model.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
                HStack {
                    TextField("Model ID", text: $manualModelID, prompt: Text("Add a model ID manually"))
                    Button("Add") { addManualModel() }
                        .disabled(manualModelID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !draft.isNew {
                Section {
                    Button("Delete Connection…", role: .destructive) { isConfirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasSavedKey = !draft.isNew && ((try? chat.apiKeys.apiKey(for: draft.id)) ?? nil) != nil
        }
        .confirmationDialog(
            Text("Delete “\(draft.name)”?"),
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("All conversations that use this Connection will be deleted too. This can't be undone.")
        }
    }

    /// 勾选表示在模型选择器里显示。已经保存过的 Connection 立即生效，不用再按保存。
    private func visibility(of modelID: String) -> Binding<Bool> {
        Binding {
            !draft.hiddenModelIDs.contains(modelID)
        } set: { isVisible in
            if isVisible { draft.hiddenModelIDs.remove(modelID) } else { draft.hiddenModelIDs.insert(modelID) }
            guard !draft.isNew, var stored = chat.connections.connection(id: draft.id) else { return }
            stored.hiddenModelIDs = draft.hiddenModelIDs
            chat.connections.save(stored)
        }
    }

    /// 手动填写模型 ID（SPEC §9）：拉取失败时，或者 `/models` 返回的列表不全时用。
    /// 能力用保守默认，用户不能手动改能力。已经保存过的 Connection 立即生效。
    private func addManualModel() {
        let id = manualModelID.trimmingCharacters(in: .whitespaces)
        manualModelID = ""
        guard !draft.models.contains(where: { $0.id == id }) else { return }
        draft.models.append(ModelInfo(id: id, capabilities: .conservative))
        draft.manualModelIDs.append(id)
        persistModelsIfSaved()
    }

    private func removeManualModel(_ id: String) {
        draft.models.removeAll { $0.id == id }
        draft.manualModelIDs.removeAll { $0 == id }
        persistModelsIfSaved()
        // 删掉的正好是 Default Model：和删除 Connection 时一样，清空并到通用页重新选（SPEC §9）
        if !draft.isNew, chat.connections.defaultModel == ModelRef(connectionID: draft.id, modelID: id) {
            chat.connections.defaultModel = nil
            onDefaultModelRemoved()
        }
    }

    private func persistModelsIfSaved() {
        guard !draft.isNew, var stored = chat.connections.connection(id: draft.id) else { return }
        stored.models = draft.models
        chat.connections.save(stored)
        chat.connections.setManualModelIDs(draft.manualModelIDs, of: draft.id)
    }

    /// 保存时拉取 Model 列表，这一步同时就是连接测试；成功才写进 Keychain（SPEC §9）。
    private func save(testing: Bool) async {
        errorMessage = nil
        guard var connection = draft.makeConnection() else {
            errorMessage = String(localized: "Enter a valid base URL, starting with https://.")
            return
        }
        let newKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedKey = draft.isNew ? nil : (try? chat.apiKeys.apiKey(for: connection.id)) ?? nil
        guard let key = newKey.isEmpty ? savedKey : newKey else {
            errorMessage = String(localized: "Paste an API key.")
            return
        }

        isSaving = true
        defer { isSaving = false }
        var manualModelIDs = draft.manualModelIDs
        if testing {
            do {
                let fetched = try await connection.provider.makeAdapter().listModels(connection, apiKey: key)
                // 拉取结果加上手动填写、而列表里没有的模型；手动填的 ID 这次拉到了，就不再算手动的
                let fetchedIDs = Set(fetched.map(\.id))
                manualModelIDs.removeAll { fetchedIDs.contains($0) }
                connection.models = fetched + draft.models.filter { manualModelIDs.contains($0.id) }
            } catch {
                errorMessage = (error as? ChatError)?.displayText ?? error.localizedDescription
                canSaveWithoutTesting = true
                return
            }
        }
        if !newKey.isEmpty {
            do {
                try chat.apiKeys.setAPIKey(newKey, for: connection.id)
            } catch {
                errorMessage = String(localized: "Couldn't save the API key to the Keychain.")
                return
            }
        }
        chat.connections.save(connection)
        chat.connections.setManualModelIDs(manualModelIDs, of: connection.id)
        chat.connectionsDidChange()
        canSaveWithoutTesting = false
        if !newKey.isEmpty { hasSavedKey = true }
        draft = ConnectionDraft(connection: connection, manualModelIDs: manualModelIDs)
        onSaved(connection.id)
    }

    /// 删除 Connection：先删用它的 Conversation，再删 key 和 Connection 本身（SPEC §9）。
    private func delete() async {
        let id = draft.id
        await history.deleteConversations(ofConnection: id)
        try? chat.apiKeys.deleteAPIKey(for: id)
        let hadDefaultModel = chat.connections.defaultModel?.connectionID == id
        chat.connections.delete(id)
        chat.connectionsDidChange()
        onDeleted(hadDefaultModel)
    }
}

extension Provider {
    var displayName: String {
        switch self {
        case .openAICompatible: String(localized: "OpenAI Compatible")
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        }
    }
}
