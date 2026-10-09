import Foundation

/// 一段可以持续多轮的对话。创建时选定 Model，之后不再更换（CONTEXT.md）。
/// 字段对应 ARCHITECTURE §5.2 的 conversation 表；Message 单独存取。
public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var titleIsGenerated: Bool
    public var connectionID: UUID
    public var modelID: String
    public var webSearchEnabled: Bool
    public var createdAt: Date
    public var lastMessageAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        titleIsGenerated: Bool = false,
        connectionID: UUID,
        modelID: String,
        webSearchEnabled: Bool = false,
        createdAt: Date = Date(),
        lastMessageAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.titleIsGenerated = titleIsGenerated
        self.connectionID = connectionID
        self.modelID = modelID
        self.webSearchEnabled = webSearchEnabled
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt ?? createdAt
    }
}
