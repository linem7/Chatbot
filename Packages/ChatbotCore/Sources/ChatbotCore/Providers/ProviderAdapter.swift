import Foundation

/// 一种 Provider 的接入（ARCHITECTURE §3.1，ADR-0001）：只做「一次模型调用」和「拉取 Model 列表」，
/// 多次调用的串联由 TurnRunner 负责。
public protocol ProviderAdapter: Sendable {
    /// 一次模型调用：把各家的流统一成 ModelEvent。出错时抛出 ChatError。
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error>
    /// 拉取 Model 列表和能力；保存 Connection 时也用它做连接测试。出错时抛出 ChatError。
    func listModels(_ connection: Connection, apiKey: String) async throws -> [ModelInfo]
}

public struct ModelRequest: Sendable {
    public var connection: Connection
    public var apiKey: String
    public var modelID: String
    public var systemPrompt: String
    /// 领域 Message，由 adapter 序列化成各家格式。
    public var messages: [Message]
    /// 当前 Model 支持搜索，并且这个 Conversation 没有关掉搜索。
    public var webSearch: Bool

    public init(
        connection: Connection,
        apiKey: String,
        modelID: String,
        systemPrompt: String,
        messages: [Message],
        webSearch: Bool
    ) {
        self.connection = connection
        self.apiKey = apiKey
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.webSearch = webSearch
    }
}

public enum ModelEvent: Sendable, Hashable {
    case textDelta(String)
    /// app 侧工具；v1 没有，保留这个接口。
    case toolCallStarted(id: String, name: String)
    case toolCallArgumentsDelta(id: String, json: String)
    case toolCallCompleted(id: String, argumentsJSON: String)
    case webSearchStarted(query: String)
    /// 正文中引用的范围（UTF-16 偏移）。
    case citation(Citation, textRange: Range<Int>?)
    /// 必须原样回传的数据。
    case providerData(blockIndex: Int, opaque: JSONValue)
    case finished(FinishReason)
}

public enum FinishReason: Sendable, Hashable {
    case stop
    /// 达到输出上限，正文可能被截断。
    case length
    /// Anthropic 搜索时要求把当前内容原样发回去继续。
    case pauseTurn
    case toolUse
}

extension Provider {
    /// 这个 Provider 对应的 adapter。
    public func makeAdapter(transport: any HTTPTransport = defaultHTTPTransport()) -> any ProviderAdapter {
        switch self {
        case .openAICompatible:
            OpenAICompatibleAdapter(transport: transport)
        case .anthropic, .gemini:
            // #23、#24 实现
            UnimplementedAdapter(provider: self)
        }
    }
}

/// 还没实现的 Provider：调用时直接报错。
struct UnimplementedAdapter: ProviderAdapter {
    let provider: Provider

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ChatError.providerError("\(provider.rawValue) 还没有实现")) }
    }

    func listModels(_ connection: Connection, apiKey: String) async throws -> [ModelInfo] {
        throw ChatError.providerError("\(provider.rawValue) 还没有实现")
    }
}
