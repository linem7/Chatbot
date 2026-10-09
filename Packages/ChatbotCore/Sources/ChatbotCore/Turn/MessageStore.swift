import Foundation

/// TurnRunner 落库用的接口（ARCHITECTURE §4）。#19 注入内存实现，#20 换成 GRDB。
///
/// 约定：Turn 被取消之后，TurnRunner 仍然会调用这里保存用户 Message 和 interrupted 的回答。
/// TurnRunner 会在一个没有被取消的 Task 里调用，实现可以照常检查取消（例如 GRDB 的 `write`）。
public protocol MessageStore: Sendable {
    /// Turn 开始时保存用户 Message。Conversation 还没保存过时一起创建（第一次 Turn）。
    func saveUserMessage(_ message: Message, in conversation: Conversation) async throws
    /// Turn 结束（complete / interrupted / failed）时保存 assistant Message。同一个 id 只会保存一次。
    func saveAssistantMessage(_ message: Message, conversationID: UUID) async throws
}

/// 只存在内存里的 MessageStore。
public actor InMemoryMessageStore: MessageStore {
    private var conversationsByID: [UUID: Conversation] = [:]
    private var messagesByConversation: [UUID: [Message]] = [:]

    public init() {}

    public func saveUserMessage(_ message: Message, in conversation: Conversation) {
        if conversationsByID[conversation.id] == nil { conversationsByID[conversation.id] = conversation }
        upsert(message, conversationID: conversation.id)
    }

    public func saveAssistantMessage(_ message: Message, conversationID: UUID) {
        upsert(message, conversationID: conversationID)
    }

    public func conversation(_ id: UUID) -> Conversation? {
        conversationsByID[id]
    }

    /// 一个 Conversation 的全部 Message，按保存顺序排列。
    public func messages(in conversationID: UUID) -> [Message] {
        messagesByConversation[conversationID, default: []]
    }

    private func upsert(_ message: Message, conversationID: UUID) {
        var messages = messagesByConversation[conversationID, default: []]
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messagesByConversation[conversationID] = messages
    }
}
