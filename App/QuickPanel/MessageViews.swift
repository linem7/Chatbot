import AppKit
import ChatbotCore
import ImageIO
import MarkdownUI
import SwiftUI

/// 用户消息：靠右的气泡。附件显示在文字上方。
struct UserMessageBubble: View {
    let text: String
    var attachments: [Attachment] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        AttachmentChip(name: attachment.originalName, attachment: attachment)
                    }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(.tint.opacity(0.12), in: UnevenRoundedRectangle(
                        topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
    }
}

/// 一个附件：图片显示缩略图，文件显示图标和文件名；还在处理时（attachment 为 nil）显示进度。
struct AttachmentChip: View {
    let name: String
    let attachment: Attachment?

    var body: some View {
        Group {
            if let attachment, let image = ThumbnailCache.shared.thumbnail(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    if attachment == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: attachment?.kind == .pdf ? "doc.richtext" : "doc.text")
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .help(name)
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

/// 附件缩略图的缓存：按附件 id 缓存一张小图。
/// 不缓存的话，流式生成时每个更新都会让气泡重绘，把长边 2000px 的原图重新解码一次。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// 缩略图显示成 44pt，按 2 倍屏取 88px，再留一点余量。
    private static let maxPixelSize = 128
    private let cache = NSCache<NSUUID, NSImage>()

    func thumbnail(for attachment: Attachment) -> NSImage? {
        guard case .image(let data, _) = attachment.content else { return nil }
        let key = attachment.id as NSUUID
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }
}
