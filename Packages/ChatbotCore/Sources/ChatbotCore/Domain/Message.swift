import Foundation

/// Conversation 里的一条消息。一条 assistant Message 就是一次 Turn 的完整回答，
/// 内部是有序的内容块；没有单独的 tool 角色（ADR-0001）。
public struct Message: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable, Hashable {
        case user
        case assistant
    }

    public var id: UUID
    public var role: Role
    public var status: MessageStatus
    public var content: [ContentBlock]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        status: MessageStatus = .complete,
        content: [ContentBlock],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.content = content
        self.createdAt = createdAt
    }

    /// 只有一段文字的用户 Message。
    public static func user(_ text: String) -> Message {
        Message(role: .user, content: [ContentBlock(.text(text))])
    }

    /// 回答的 Markdown 原文：按顺序拼接所有 text 块。用于「复制」和全文搜索。
    public var markdownText: String {
        content.compactMap { block in
            if case .text(let text, _) = block.kind { return text }
            return nil
        }.joined()
    }
}

public enum MessageStatus: Codable, Sendable, Hashable {
    /// Turn 还在执行，内容还在增长。
    case streaming
    case complete
    /// 用户取消了，已经收到的部分保留（CONTEXT.md 的 Interrupted）。
    case interrupted
    /// 出错了，已经收到的部分保留。
    case failed(ChatError)
}

/// assistant Message 或用户 Message 里的一个内容块（ARCHITECTURE §5.2）。
public struct ContentBlock: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case text(String, citations: [CitationSpan] = [])
        case attachmentRef(UUID)
        /// app 侧工具的调用；v1 没有 app 侧工具，保留这个形状。
        case toolCall(id: String, name: String, argumentsJSON: String)
        case toolResult(toolCallID: String, content: String, isError: Bool)
        /// 模型发起的 Web Search。
        case webSearch(query: String)
        /// 只有 adapter 能理解的整块原生数据，例如 Anthropic 的 `web_search_tool_result`。
        case opaque(provider: Provider, JSONValue)
    }

    public var kind: Kind
    /// 必须逐字保存、原样回传的 Provider 原生数据，只由 adapter 读写（ADR-0001）。
    public var providerData: JSONValue?

    public init(_ kind: Kind, providerData: JSONValue? = nil) {
        self.kind = kind
        self.providerData = providerData
    }
}

/// 回答正文所依据的一条网页来源。
public struct Citation: Codable, Sendable, Hashable {
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

/// text 块里一段正文和它的 Citation。
public struct CitationSpan: Codable, Sendable, Hashable {
    public var citation: Citation
    /// 正文中被引用的范围（UTF-16 偏移）；Provider 没给范围时为 nil。
    public var textRange: Range<Int>?

    public init(citation: Citation, textRange: Range<Int>?) {
        self.citation = citation
        self.textRange = textRange
    }
}
