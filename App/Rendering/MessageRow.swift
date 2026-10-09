import ChatbotCore
import SwiftUI

/// 一条消息：用户消息是靠右的气泡，回答用 Markdown 渲染，下面附上 Interrupted 或 Failed 的说明。
/// Quick Panel 和 Main Window 共用。
struct MessageRow: View {
    let message: Message
    /// 这条消息引用的附件（用户消息的缩略图和文件名）。
    let attachments: [Attachment]

    var body: some View {
        switch message.role {
        case .user:
            UserMessageBubble(text: message.markdownText, attachments: attachments)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.status == .streaming && message.content.isEmpty {
                    TypingIndicator()
                } else {
                    AssistantMessageView(markdown: message.markdownText, isStreaming: message.status == .streaming)
                        .equatable()
                }
                switch message.status {
                case .interrupted:
                    NoticeText(text: String(localized: "Interrupted"))
                case .failed(let error):
                    NoticeText(text: error.displayText)
                case .streaming, .complete:
                    EmptyView()
                }
            }
        }
    }
}

struct NoticeText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }
}

struct TypingIndicator: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tertiary)
            .symbolEffect(.variableColor.iterative)
            .padding(.vertical, 4)
    }
}
