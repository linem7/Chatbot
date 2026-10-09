import Foundation

/// 附在用户 Message 上的一个文件（CONTEXT.md）。这里保存的是处理之后、要发给模型的内容：
/// 图片是缩放压缩后的版本，PDF 和文本文件是抽出的文字（SPEC §4）。
/// Message 里用 `ContentBlock.Kind.attachmentRef(id)` 引用它。
public struct Attachment: Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case image
        case pdf
        case text
    }

    public enum Content: Sendable, Hashable {
        /// 压缩后的图片和它的 MIME 类型（`image/jpeg` 或 `image/png`）。
        case image(Data, mediaType: String)
        /// PDF 抽出的文字，或者解码后的文本文件。
        case text(String)
    }

    public var id: UUID
    public var kind: Kind
    /// 用户看到的文件名；粘贴的图片没有文件名时由调用方给一个。
    public var originalName: String
    public var content: Content

    public init(id: UUID = UUID(), kind: Kind, originalName: String, content: Content) {
        self.id = id
        self.kind = kind
        self.originalName = originalName
        self.content = content
    }
}

/// 加入附件时的问题。由界面提示给用户，不会进入 Turn。
public enum AttachmentError: Error, Sendable, Hashable {
    /// 不支持的类型（包括 Office 文档等二进制文件）。
    case unsupportedType(name: String)
    /// 文件读不出来，或者图片、PDF 无法解析。
    case unreadable(name: String)
    /// PDF 抽不出文字，多半是扫描版。
    case scannedPDF(name: String)
}

extension Message {
    /// 带附件的用户 Message：先是附件，最后是文字。
    public static func user(_ text: String, attachments: [Attachment]) -> Message {
        var content = attachments.map { ContentBlock(.attachmentRef($0.id)) }
        if !text.isEmpty { content.append(ContentBlock(.text(text))) }
        return Message(role: .user, content: content)
    }

    /// 这条 Message 引用的附件 id，按出现顺序。
    public var attachmentIDs: [UUID] {
        content.compactMap { block in
            if case .attachmentRef(let id) = block.kind { return id }
            return nil
        }
    }
}
