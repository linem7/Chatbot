import Foundation

/// 模型 API 协议族，固定三种，用户不能新增（CONTEXT.md）。
public enum Provider: String, Codable, Sendable, Hashable, CaseIterable {
    case openAICompatible
    case anthropic
    case gemini
}

/// 用户配置的一条模型接入。以 JSON 存在 UserDefaults（ARCHITECTURE §5.1）；
/// API key 不在这里，存在 Keychain。
public struct Connection: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var provider: Provider
    /// DeepSeek 的 base URL 不带 `/v1`。
    public var baseURL: URL
    /// 用户在设置里隐藏的 Model。
    public var hiddenModelIDs: Set<String>
    /// 上次拉取到的 Model 列表及其能力。
    public var models: [ModelInfo]

    public init(
        id: UUID = UUID(),
        name: String,
        provider: Provider,
        baseURL: URL,
        hiddenModelIDs: Set<String> = [],
        models: [ModelInfo] = []
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.hiddenModelIDs = hiddenModelIDs
        self.models = models
    }

    /// DeepSeek 模板：OpenAI 兼容 Provider，base URL `https://api.deepseek.com`。
    public static func deepSeek(id: UUID = UUID(), name: String = "DeepSeek") -> Connection {
        Connection(id: id, name: name, provider: .openAICompatible, baseURL: URL(string: "https://api.deepseek.com")!)
    }

    /// Anthropic 模板：base URL `https://api.anthropic.com`，路径里的 `/v1` 由 adapter 加。
    public static func anthropic(id: UUID = UUID(), name: String = "Anthropic") -> Connection {
        Connection(id: id, name: name, provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!)
    }

    /// 是否是 DeepSeek 的官方接口。DeepSeek 需要一些非标准字段（例如关闭思考的 `thinking`）。
    var isDeepSeek: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "deepseek.com" || host.hasSuffix(".deepseek.com")
    }
}

/// 某个 Connection 下可调用的一个 Model。
public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    /// API 里的模型 ID，例如 `deepseek-flash`。
    public var id: String
    public var displayName: String?
    public var contextWindow: Int?
    /// 单次回答最多能输出的 token 数。Anthropic 的 `max_tokens` 是必填项，不能超过它。
    public var maxOutputTokens: Int?
    public var capabilities: ModelCapabilities
    /// 接口报告的能力原文，只由对应的 adapter 读取（例如 Anthropic 判断能否关闭思考、能否用 low effort）。
    public var providerData: JSONValue?

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        capabilities: ModelCapabilities,
        providerData: JSONValue? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.providerData = providerData
    }
}

/// 一个 Model 能接受什么输入、能做什么。来源优先级：接口报告 > 内置表 > 保守默认（ARCHITECTURE §3.2）。
public struct ModelCapabilities: Codable, Sendable, Hashable {
    public var imageInput: Bool
    public var toolCalling: Bool
    public var webSearch: Bool

    public init(imageInput: Bool, toolCalling: Bool, webSearch: Bool) {
        self.imageInput = imageInput
        self.toolCalling = toolCalling
        self.webSearch = webSearch
    }

    /// 保守默认：只支持文本和 tools，不支持图片，不支持搜索。
    public static let conservative = ModelCapabilities(imageInput: false, toolCalling: true, webSearch: false)
}
