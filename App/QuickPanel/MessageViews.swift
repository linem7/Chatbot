import MarkdownUI
import SwiftUI

/// 用户消息：靠右的气泡。
struct UserMessageBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .background(.tint.opacity(0.12), in: UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16
            ))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 80)
    }
}

/// 回答：不加气泡，用 MarkdownUI 渲染。悬停时显示「复制」，复制的是整条回答的 Markdown 原文（SPEC §6）。
///
/// 只接收值类型参数，并且实现 Equatable：流式生成时只有最后一条回答的参数在变，其余的不会重新解析 Markdown。
struct AssistantMessageView: View, Equatable {
    let markdown: String
    let isStreaming: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Markdown(markdown)
                .markdownTheme(.chatbot)
                .markdownCodeSyntaxHighlighter(HighlightedCodeSyntaxHighlighter(colorScheme: colorScheme))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: markdown)
                .opacity(isHovering && !isStreaming ? 1 : 0)
        }
        .padding(.trailing, 24)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.markdown == rhs.markdown && lhs.isStreaming == rhs.isStreaming
    }
}
