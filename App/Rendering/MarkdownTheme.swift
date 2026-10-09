import MarkdownUI
import SwiftUI

extension Theme {
    /// 回答的 Markdown 主题：在 `.basic` 的基础上调整字号、行内代码和代码块。
    ///
    /// MarkdownUI 2.4.1 的 Theme 不是 Sendable，所以限定在 MainActor 上（ARCHITECTURE §8 第 1 条）。
    @MainActor
    static let chatbot = Theme.basic
        .text {
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color.primary.opacity(0.06))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 10)
        }
        .codeBlock { configuration in
            CodeBlockView(configuration: configuration)
                .markdownMargin(top: 0, bottom: 10)
        }
}

/// 代码块：横向滚动，悬停时右上角显示「复制」。
private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @State private var isHovering = false

    var body: some View {
        ScrollView(.horizontal) {
            configuration.label
                .relativeLineSpacing(.em(0.2))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.9))
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            CopyButton(text: configuration.content)
                .padding(6)
                .opacity(isHovering ? 1 : 0)
        }
        .onHover { isHovering = $0 }
    }
}
