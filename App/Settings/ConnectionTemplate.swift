import ChatbotCore
import Foundation

/// 添加 Connection 时先选的模板（SPEC §9）：填好 Provider 和 base URL，用户只需要粘贴 key。
enum ConnectionTemplate: CaseIterable, Identifiable {
    case deepSeek
    case anthropic
    case gemini
    case openAI
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        case .custom: String(localized: "Custom")
        }
    }

    func makeConnection() -> Connection {
        switch self {
        case .deepSeek: .deepSeek()
        case .anthropic: .anthropic()
        case .gemini: .gemini()
        // OpenAI 兼容 adapter 在 base URL 后面直接拼 `/chat/completions`，所以 OpenAI 的 base URL 要带 `/v1`
        // （DeepSeek 的不带）。
        case .openAI: Connection(name: "OpenAI", provider: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!)
        case .custom: Connection(name: String(localized: "Custom"), provider: .openAICompatible, baseURL: URL(string: "https://")!)
        }
    }

    /// 自定义模板可以选 Provider；其他模板的 Provider 是固定的。
    var allowsChoosingProvider: Bool { self == .custom }
}
