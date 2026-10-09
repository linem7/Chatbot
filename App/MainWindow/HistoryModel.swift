import ChatbotCore
import Foundation
import Observation

/// Main Window 的状态：历史列表、全文搜索和当前选中的 Conversation（SPEC §8）。
@MainActor
@Observable
final class HistoryModel {
    private let store: HistoryStore
    private let chat: ChatStore

    /// 按最后一条消息的时间倒序；有搜索词时只包含匹配的。
    private(set) var conversations: [Conversation] = []
    var query = "" {
        didSet { scheduleReload() }
    }
    var selectedID: UUID? {
        didSet {
            if selectedID != oldValue { loadSelectedMessages() }
        }
    }
    private(set) var selectedMessages: [Message] = []
    /// 选中对话里的附件，消息气泡按 `attachmentRef` 查这里显示。
    private(set) var selectedAttachments: [UUID: Attachment] = [:]

    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var messagesTask: Task<Void, Never>?

    init(store: HistoryStore, chat: ChatStore) {
        self.store = store
        self.chat = chat
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    /// 重新读取列表和选中对话的消息。窗口出现、历史有变化时调用。
    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { await load() }
    }

    /// 打开 Main Window 时选中给定的 Conversation。搜索词会过滤掉它的话，先清空搜索。
    func select(_ conversationID: UUID?) {
        if conversationID != nil, !query.isEmpty { query = "" }
        selectedID = conversationID
        reload()
    }

    /// 右键或按 ⌫ 删除单个 Conversation，不确认（SPEC §8）。
    func delete(_ conversationID: UUID) {
        Task {
            await chat.prepareToDelete(conversationID)
            try? await store.deleteConversation(conversationID)
            if selectedID == conversationID { selectedID = nil }
            await load()
        }
    }

    /// 「清空全部历史」，二次确认由调用方负责（设置的高级页，#22）。
    func deleteAll() async {
        await chat.prepareToDeleteAll()
        try? await store.deleteAll()
        selectedID = nil
        await load()
    }

    /// 删除 Connection 时，连同用它的所有 Conversation 一起删除（SPEC §9）。
    func deleteConversations(ofConnection connectionID: UUID) async {
        await chat.prepareToDeleteConnection(connectionID)
        try? await store.deleteConversations(connectionID: connectionID)
        if let selectedConversation, selectedConversation.connectionID == connectionID { selectedID = nil }
        await load()
    }

    /// 回到 Quick Panel 继续这个对话。
    func continueInQuickPanel(_ conversationID: UUID) {
        Task {
            await chat.open(conversationID)
            chat.showQuickPanel()
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            // 输入时稍等一下再搜，避免每个字都查一次
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        let query = query
        guard let result = try? await store.search(query), !Task.isCancelled else { return }
        conversations = result
        await loadMessages(of: selectedID)
    }

    private func loadSelectedMessages() {
        messagesTask?.cancel()
        let selectedID = selectedID
        messagesTask = Task { await loadMessages(of: selectedID) }
    }

    private func loadMessages(of conversationID: UUID?) async {
        guard let conversationID else {
            selectedMessages = []
            selectedAttachments = [:]
            return
        }
        guard let messages = try? await store.messages(in: conversationID) else { return }
        let attachments = (try? await store.attachments(in: conversationID)) ?? []
        guard !Task.isCancelled, conversationID == selectedID else { return }
        selectedMessages = messages
        selectedAttachments = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
