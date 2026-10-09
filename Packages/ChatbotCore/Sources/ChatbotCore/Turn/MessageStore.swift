import Foundation

/// TurnRunner 落库用的接口（ARCHITECTURE §4）。#19 注入内存实现，#20 换成 GRDB。
public protocol MessageStore: Sendable {
    /// Turn 开始时保存用户 Message。
    func saveUserMessage(_ message: Message, conversationID: UUID) async throws
    /// Turn 结束（complete / interrupted / failed）时保存 assistant Message。
    /// 同一个 id 再次保存时覆盖旧的（Retry 会替换旧回答）。
    func saveAssistantMessage(_ message: Message, conversationID: UUID) async throws
}

/// 只存在内存里的 MessageStore。
public actor InMemoryMessageStore: MessageStore {
    private var messagesByConversation: [UUID: [Message]] = [:]

    public init() {}

    public func saveUserMessage(_ message: Message, conversationID: UUID) {
        upsert(message, conversationID: conversationID)
    }

    public func saveAssistantMessage(_ message: Message, conversationID: UUID) {
        upsert(message, conversationID: conversationID)
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
