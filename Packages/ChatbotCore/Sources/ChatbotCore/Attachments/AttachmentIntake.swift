import Foundation

/// 把「+」、粘贴、拖放进来的文件统一处理成 Attachment（ARCHITECTURE §6，SPEC §4）。
/// App 侧的三个入口都调用这里，规则只有一套。
///
/// - 图片：缩到长边 ≤ 2000px；有透明通道的保持 PNG，其他转成 JPEG（质量 0.85）。
/// - PDF：在本地逐页抽取文字；抽不出来时报 `AttachmentError.scannedPDF`。
/// - 其他文件当作文本：按 UTF-8 解码，失败时做编码检测；看起来是二进制的拒绝。
///
/// 图片和 PDF 依赖 ImageIO、PDFKit，只在 Apple 平台上可用。
public struct AttachmentIntake: Sendable {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]

    public init() {}

    /// 处理一个文件（「+」、拖放，或者从 Finder 复制后粘贴）。
    public func attachment(fromFile url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AttachmentError.unreadable(name: name)
        }

        switch url.pathExtension.lowercased() {
        case let ext where Self.imageExtensions.contains(ext):
            return try attachment(fromImageData: data, name: name)
        case "pdf":
            return Attachment(kind: .pdf, originalName: name, content: .text(try PDFTextExtractor.text(from: data, name: name)))
        default:
            guard let text = TextDecoder.decode(data) else { throw AttachmentError.unsupportedType(name: name) }
            return Attachment(kind: .text, originalName: name, content: .text(text))
        }
    }

    /// 处理剪贴板里的图片数据（例如截图工具复制的图片）。
    public func attachment(fromImageData data: Data, name: String) throws -> Attachment {
        let (compressed, mediaType) = try ImageCompressor.compress(data, name: name)
        return Attachment(kind: .image, originalName: name, content: .image(compressed, mediaType: mediaType))
    }
}

/// 文本文件的解码。
enum TextDecoder {
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        // UTF-16 和 UTF-32 带 BOM 时会有 NUL 字节，要在二进制检查之前处理
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        // 前 8KB 里有 NUL 字节，就当成二进制文件（Office 文档、压缩包、可执行文件……）
        if bytes.prefix(8_192).contains(0) { return nil }

        if var text = String(validating: bytes, as: UTF8.self) {
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return text
        }
        return detectEncoding(data)
    }

    /// UTF-8 失败时用系统的编码检测（例如 GBK、Shift_JIS 的旧文件）。
    private static func detectEncoding(_ data: Data) -> String? {
        #if canImport(Darwin)
        var converted: NSString?
        var usedLossyConversion = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: &usedLossyConversion
        )
        guard encoding != 0, let converted else { return nil }
        return converted as String
        #else
        return nil
        #endif
    }
}
