import ChatbotCore
import Foundation

extension ChatError {
    /// 显示在回答位置的错误说明（SPEC §7）。
    var displayText: String {
        switch self {
        case .authentication:
            String(localized: "The API key is invalid or has expired.")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                String(localized: "Too many requests or out of quota. Try again in \(Int(retryAfter.rounded(.up))) seconds.")
            } else {
                String(localized: "Too many requests or out of quota.")
            }
        case .overloaded:
            String(localized: "The service is temporarily unavailable.")
        case .network:
            String(localized: "Network connection failed.")
        case .contextTooLong:
            String(localized: "This conversation is too long. Start a new one.")
        case .unsupportedInput:
            String(localized: "The current model doesn't support this input.")
        case .invalidRequest(let raw), .providerError(let raw):
            raw
        }
    }
}

/// 回答下面的操作按钮（SPEC §7 的「操作」一列）。
enum AnswerAction: Hashable {
    case openSettings
    case retry
    case newConversation
}

extension ChatError {
    /// 这类错误给哪些操作，第一个是主按钮。不自动重试（SPEC §7）。
    var actions: [AnswerAction] {
        switch self {
        // key 改好之后回来可以直接重试
        case .authentication: [.openSettings, .retry]
        case .rateLimited, .overloaded, .network, .invalidRequest, .providerError: [.retry]
        case .contextTooLong: [.newConversation]
        case .unsupportedInput: []
        }
    }
}

extension MessageStatus {
    /// Interrupted（用户取消）给「重试」；Failed 按错误类别给。
    var actions: [AnswerAction] {
        switch self {
        case .interrupted: [.retry]
        case .failed(let error): error.actions
        case .streaming, .complete: []
        }
    }
}

