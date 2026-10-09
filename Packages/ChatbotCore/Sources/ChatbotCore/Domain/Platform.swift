import Foundation

/// 提供模型 API 的平台，按 Connection 的 base URL 的 host 识别（CONTEXT.md）。
/// 同一个 Provider 下，不同平台要发不同的非标准字段，例如关闭思考的写法各不相同。
/// 依据见 `docs/research/third-party-web-search.md`（§1.7、§2.7）。
public enum Platform: Sendable, Hashable {
    /// DeepSeek 官方：`api.deepseek.com`
    case deepSeek
    /// OpenRouter：`openrouter.ai`，以及地域端点 `us.openrouter.ai`、`eu.openrouter.ai`
    case openRouter(OpenRouterEndpoint)
    /// 阿里云百炼（DashScope）：`dashscope.aliyuncs.com`、`dashscope-intl.aliyuncs.com`、
    /// `cn-hongkong.dashscope.aliyuncs.com`、业务空间专属域名 `{WorkspaceId}.{region}.maas.aliyuncs.com` 等。
    /// 地域决定哪些模型能联网搜索，所以带在类型里（`BailianRegion`）。
    case bailian(BailianRegion)

    /// OpenRouter 的端点。地域端点只在 In-Region Routing 时用，能用的 server tool 引擎不同（research §1.7）。
    public enum OpenRouterEndpoint: Sendable, Hashable {
        case global
        case us
        case eu
    }

    /// 百炼的地域。联网搜索支持的模型按地域分成三张表，差别很大（research §2.2），所以要一起判断。
    public enum BailianRegion: Sendable, Hashable {
        /// 华北2（北京）：`dashscope.aliyuncs.com`，以及 `{WorkspaceId}.cn-beijing.maas.aliyuncs.com`
        case beijing
        /// 新加坡：`dashscope-intl.aliyuncs.com`，以及 `{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com`
        case singapore
        /// 全球：美国（弗吉尼亚）、中国香港、日本（东京）、德国（法兰克福），以及认不出的其他地域
        case global
    }

    /// 不认识的 host 返回 nil：按标准 OpenAI 兼容接口处理，不发任何非标准字段。
    public init?(host: String?) {
        guard let host = host?.lowercased() else { return nil }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }

        if matches("deepseek.com") {
            self = .deepSeek
        } else if matches("eu.openrouter.ai") {
            self = .openRouter(.eu)
        } else if matches("us.openrouter.ai") {
            self = .openRouter(.us)
        } else if matches("openrouter.ai") {
            self = .openRouter(.global)
        } else if host.hasSuffix(".aliyuncs.com"),
                  host.hasPrefix("dashscope") || matches("dashscope.aliyuncs.com") || matches("maas.aliyuncs.com") {
            self = .bailian(Self.bailianRegion(host: host))
        } else {
            return nil
        }
    }

    /// 从 host 认百炼的地域。业务空间专属域名把地域写在第二段（`trial.cn-beijing.maas.aliyuncs.com`、
    /// `llm-x.ap-southeast-1.maas.aliyuncs.com`）；公共域名只有 `dashscope`（北京）和 `dashscope-intl`（新加坡）。
    /// 认不出的算全球：弗吉尼亚、香港、东京、法兰克福都归这一档，能联网的模型最少，宁可保守。
    private static func bailianRegion(host: String) -> BailianRegion {
        if host.contains("cn-beijing") || host == "dashscope.aliyuncs.com" { return .beijing }
        if host.contains("ap-southeast-1") || host == "dashscope-intl.aliyuncs.com" { return .singapore }
        return .global
    }

    /// 平台本身能不能在服务端联网（OpenAI 兼容接口下）：OpenRouter 的 `openrouter:web_search`、百炼的 `enable_search`。
    /// DeepSeek 官方没有原生搜索；OpenRouter 的 EU 端点上没有任何搜索引擎（research §1.7）。
    /// 百炼这一档说的是「平台有搜索」，具体哪些模型能用要看 `BailianModelTable`。
    public var supportsServerWebSearch: Bool {
        switch self {
        case .deepSeek: false
        case .openRouter(let endpoint): endpoint != .eu
        case .bailian: true
        }
    }

    /// 百炼的地域；不是百炼时是 nil。
    public var bailianRegion: BailianRegion? {
        if case .bailian(let region) = self { return region }
        return nil
    }
}

extension Connection {
    /// 这条 Connection 所在的平台；自己部署的服务和不认识的中转是 nil。
    public var platform: Platform? {
        Platform(host: baseURL.host)
    }

    /// 某个 Model 的能力。缓存的 Model 列表里没有它时用保守默认。
    ///
    /// OpenAI 兼容 Connection 在能联网的平台上按平台规则判断 Web Search（ADR-0003）：`/models` 看不出这个能力，
    /// 所以不依赖缓存的值，#54 之前保存的 Connection 也不用重新拉取。
    /// OpenRouter 的引擎在平台侧、对任何 Model 都能用；百炼只支持文档列出的 Model，按模型名和地域查表。
    public func capabilities(ofModel modelID: String) -> ModelCapabilities {
        var capabilities = models.first { $0.id == modelID }?.capabilities ?? .conservative
        guard provider == .openAICompatible, let platform else { return capabilities }
        switch platform {
        case .openRouter(let endpoint):
            capabilities.webSearch = endpoint != .eu
        case .bailian(let region):
            capabilities.webSearch = BailianModelTable.supportsWebSearch(modelID, in: region)
        case .deepSeek:
            break
        }
        return capabilities
    }
}
