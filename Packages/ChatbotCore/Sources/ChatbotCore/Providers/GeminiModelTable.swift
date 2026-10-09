/// Gemini 的内置能力表（ARCHITECTURE §3.2：Gemini 的 `/v1beta/models` 只提供 token 上限，能力按模型名判断）。
/// 新模型发布时在这里维护。依据：
/// - 思考：https://ai.google.dev/gemini-api/docs/generate-content/thinking （thinkingLevel 表和 thinkingBudget 表）
/// - 搜索：https://ai.google.dev/gemini-api/docs/google-search （支持 google_search 的模型表）
enum GeminiModelTable {
    /// 最低的思考设置（ADR-0002：能关就关，关不掉的用它支持的最低档）。
    enum Thinking: Equatable {
        case budget(Int)
        case level(String)
    }

    /// 按前缀匹配，**更具体的前缀放前面**（例如 flash-lite 在 flash 之前）。
    private static let thinking: [(prefix: String, setting: Thinking)] = [
        // 2.5：thinkingBudget。Pro 关不掉，最小 128；Flash、Flash-Lite 设 0 就是关闭
        ("gemini-2.5-pro", .budget(128)),
        ("gemini-2.5-flash-lite", .budget(0)),
        ("gemini-2.5-flash", .budget(0)),
        // 3.x：thinkingLevel。Pro 和 3.7、3.8 Flash 不支持 minimal（会报错），最低是 low
        ("gemini-3.8-flash", .level("low")),
        ("gemini-3.7-flash", .level("low")),
        ("gemini-3.1-pro", .level("low")),
        ("gemini-3-pro", .level("low")),
        ("gemini-3.5-flash-lite", .level("minimal")),
        ("gemini-3.1-flash-lite", .level("minimal")),
        ("gemini-3.6-flash", .level("minimal")),
        ("gemini-3.5-flash", .level("minimal")),
        ("gemini-3-flash", .level("minimal")),
    ]

    /// 不认识的模型返回 nil：什么都不发，用模型的默认值，避免发了不支持的档位报错。
    static func lowestThinking(for modelID: String) -> Thinking? {
        thinking.first { modelID.hasPrefix($0.prefix) }?.setting
    }

    /// 支持 google_search 的模型（文档的支持表：2.0 Flash、2.5 全系、3.x 全系）。
    static func supportsWebSearch(_ modelID: String) -> Bool {
        // 支持表里有 2.0 Flash，没有 2.0 Flash-Lite，前缀相同，要单独排除
        if modelID.hasPrefix("gemini-2.0-flash-lite") { return false }
        return ["gemini-2.0-flash", "gemini-2.5-", "gemini-3"].contains { modelID.hasPrefix($0) }
    }

    /// 现役的 Gemini 聊天模型都能看图。
    static func acceptsImages(_ modelID: String) -> Bool {
        modelID.hasPrefix("gemini-")
    }

    /// 不是聊天用的模型（嵌入、语音、生图、实时等），不出现在 Model 列表里。
    /// `-latest` 是指向其他模型的别名，能力和思考档位对不上内置表，也不列出来。
    static func isChatModel(_ modelID: String) -> Bool {
        let excluded = ["embedding", "tts", "image", "audio", "live", "robotics", "aqa", "imagen", "veo", "-latest"]
        return modelID.hasPrefix("gemini-") && !excluded.contains { modelID.contains($0) }
    }
}
