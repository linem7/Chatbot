import ChatbotCore
import SwiftUI

/// 一条消息。Quick Panel 和 Main Window 共用这一套（ARCHITECTURE §2 的 Rendering/）。
///
/// 回答的显示按 SPEC §5、§6：搜索状态、带角标的正文、来源列表、Gemini 的搜索建议，以及中断或出错的提示。
struct MessageRow: View {
    let message: Message
    /// 用户消息里引用的附件（按 `attachmentRef` 查好的）。
    let attachments: [Attachment]
    /// 回答下面的操作按钮。只有 Quick Panel 里最后一条中断或出错的回答才有；Main Window 不给。
    var actions: AnswerActionHandler?

    var body: some View {
        switch message.role {
        case .user:
            UserMessageBubble(text: message.markdownText, attachments: attachments)
        case .assistant:
            AssistantMessageRow(message: message, presentation: AnswerPresentation(message), actions: actions)
        }
    }
}

/// 执行回答下面的操作按钮。
struct AnswerActionHandler {
    let perform: @MainActor (AnswerAction) -> Void
}

private struct AssistantMessageRow: View {
    let message: Message
    let presentation: AnswerPresentation
    let actions: AnswerActionHandler?

    private var isStreaming: Bool { message.status == .streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = presentation.searchStatus {
                SearchStatusLine(status: status)
            }
            if !presentation.markdown.isEmpty {
                AssistantMessageView(markdown: presentation.markdown, copyText: presentation.copyText, isStreaming: isStreaming)
                    .equatable()
            } else if isStreaming, presentation.searchStatus == nil {
                TypingIndicator()
            }
            if !presentation.sources.isEmpty {
                SourceList(sources: presentation.sources)
            }
            if let html = presentation.searchSuggestionHTML {
                SearchSuggestionView(html: html)
            }
            switch message.status {
            case .interrupted:
                StatusNotice(text: String(localized: "Interrupted"), actions: message.status.actions, handler: actions)
            case .failed(let error):
                StatusNotice(text: error.displayText, actions: message.status.actions, handler: actions)
            case .streaming, .complete:
                EmptyView()
            }
        }
    }
}

/// 「正在搜索：关键词」；正文开始输出后变成一行灰字「搜索了：A、B」（SPEC §5）。
private struct SearchStatusLine: View {
    let status: AnswerPresentation.SearchStatus

    private var isSearching: Bool {
        if case .searching = status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe")
                .symbolEffect(.pulse, isActive: isSearching)
            switch status {
            case .searching(let query):
                Text("Searching: \(query)")
            case .searched(let queries):
                Text("Searched: \(queries.joined(separator: String(localized: ", ", comment: "搜索词之间的分隔符")))")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
}

/// 回答末尾的来源列表：「[1] 标题 · 域名」，点击用默认浏览器打开（SPEC §5）。
private struct SourceList: View {
    let sources: [AnswerPresentation.Source]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                Link(destination: source.url) {
                    HStack(spacing: 4) {
                        Text(verbatim: "[\(source.number)]")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(verbatim: source.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if source.domain != source.title {
                            Text(verbatim: "· \(source.domain)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 12))
                }
                .help(source.url.absoluteString)
            }
        }
        .padding(.top, 2)
    }
}

/// 中断、出错等提示。
struct NoticeText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }
}

/// 中断或出错的说明，后面跟着对应的操作按钮（SPEC §7）。没有 handler 时只显示说明。
private struct StatusNotice: View {
    let text: String
    let actions: [AnswerAction]
    let handler: AnswerActionHandler?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NoticeText(text: text)
            if let handler {
                ForEach(actions, id: \.self) { action in
                    AnswerActionButton(action: action, isPrimary: action == actions.first) {
                        handler.perform(action)
                    }
                }
            }
        }
    }
}

struct AnswerActionButton: View {
    let action: AnswerAction
    let isPrimary: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            switch action {
            case .openSettings: Text("Open Settings")
            case .retry: Text("Retry")
            case .newConversation: Text("New Conversation")
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
    }
}

/// 回答开始之前的「正在输入」。
struct TypingIndicator: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tertiary)
            .symbolEffect(.variableColor.iterative)
            .padding(.vertical, 4)
    }
}
