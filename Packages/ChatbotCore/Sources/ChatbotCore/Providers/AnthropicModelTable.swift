/// Claude 的内置能力表：`/v1/models` 没有报告 capabilities 时（经中转、OpenRouter 等）按模型名兜底
/// （ARCHITECTURE §3.2，优先级是「接口报告 > 内置表 > 保守默认」）。新模型发布时在这里维护。
/// 依据：Anthropic 文档里各模型的 thinking、effort 规则（ADR-0002「能关就关」）。
enum AnthropicModelTable {
    /// 关闭思考的方式。
    enum Thinking: Equatable {
        /// 发 `thinking: {type: "disabled"}`
        case disabled
        /// 发 `thinking: {type: "between_tools"}`（Sonnet 5.5：发 disabled 会 400）
        case betweenTools
        /// 关不掉，走默认的 adaptive（Opus 5.5、Fable）
        case adaptive
        /// 不发 `thinking` 就不思考（Opus 4.6、Sonnet 4.6 和更早的模型）
        case offByDefault
    }

    struct Entry {
        var thinking: Thinking
        /// 支持 `output_config.effort: "low"`
        var lowEffort: Bool
    }

    /// 按模型名前缀匹配，第一个匹配的生效。前缀后面紧跟版本号的不算匹配（`claude-opus-5` 不匹配 `claude-opus-5-5`），
    /// 跟日期或其他后缀的算（`claude-opus-4-5-20251101`）。以 `-` 结尾的前缀是整代兜底，不检查版本号，放在最后。
    private static let entries: [(prefix: String, entry: Entry)] = [
        ("claude-fable", Entry(thinking: .adaptive, lowEffort: true)),
        ("claude-mythos", Entry(thinking: .adaptive, lowEffort: true)),
        ("claude-opus-5-5", Entry(thinking: .adaptive, lowEffort: true)),
        // Opus 5、Haiku 5.5：disabled 只在 effort 不超过 high 时可用，我们发 low
        ("claude-opus-5", Entry(thinking: .disabled, lowEffort: true)),
        ("claude-opus-4-8", Entry(thinking: .disabled, lowEffort: true)),
        ("claude-opus-4-7", Entry(thinking: .disabled, lowEffort: true)),
        ("claude-opus-4-6", Entry(thinking: .offByDefault, lowEffort: true)),
        ("claude-opus-4-5", Entry(thinking: .offByDefault, lowEffort: true)),
        ("claude-sonnet-5-5", Entry(thinking: .betweenTools, lowEffort: true)),
        ("claude-sonnet-5", Entry(thinking: .disabled, lowEffort: true)),
        ("claude-sonnet-4-6", Entry(thinking: .offByDefault, lowEffort: true)),
        ("claude-haiku-5-5", Entry(thinking: .disabled, lowEffort: true)),
        // 更早的模型（Haiku 4.5、Sonnet 4.5、Opus 4.1、Claude 3.x 等）不发 thinking 就不思考；发 effort 会报错
        ("claude-haiku-4-", Entry(thinking: .offByDefault, lowEffort: false)),
        ("claude-sonnet-4-", Entry(thinking: .offByDefault, lowEffort: false)),
        ("claude-opus-4-", Entry(thinking: .offByDefault, lowEffort: false)),
        ("claude-3-", Entry(thinking: .offByDefault, lowEffort: false)),
    ]

    /// 不认识的模型返回 nil：什么都不发，避免 400。
    static func entry(for modelID: String) -> Entry? {
        let id = normalized(modelID)
        return entries.first { matches(id, prefix: $0.prefix) }?.entry
    }

    /// 是不是 Claude：图片和 Web Search 视为都支持（#49 的结论）。
    static func isClaude(_ modelID: String) -> Bool {
        normalized(modelID).hasPrefix("claude-")
    }

    /// 中转和 OpenRouter 的模型 ID 可能带厂商前缀、用点号写版本（`anthropic/claude-sonnet-4.5`），统一成官方写法。
    static func normalized(_ modelID: String) -> String {
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return name.lowercased().replacingOccurrences(of: ".", with: "-")
    }

    private static func matches(_ id: String, prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        if prefix.hasSuffix("-") { return true }
        let rest = id.dropFirst(prefix.count)
        if rest.isEmpty { return true }
        guard rest.hasPrefix("-") else { return false }
        // 紧跟一到两位数字的是更具体的版本号，例如 claude-opus-5 后面的 -5
        let next = rest.dropFirst().prefix { $0 != "-" }
        return !(next.count <= 2 && next.allSatisfy(\.isNumber))
    }
}
