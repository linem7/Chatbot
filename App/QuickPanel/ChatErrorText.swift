import ChatbotCore
import Foundation

extension ChatError {
    /// 显示在回答位置的错误说明（SPEC §7）。对应的操作按钮在 #25 里做。
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
