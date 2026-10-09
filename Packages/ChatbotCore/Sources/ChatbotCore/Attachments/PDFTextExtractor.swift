import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

/// PDF 在本地逐页抽取文字（SPEC §4）：不用任何 Provider 的原生 PDF 输入，DeepSeek 也能用。
enum PDFTextExtractor {
    static func text(from data: Data, name: String) throws -> String {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw AttachmentError.unreadable(name: name)
        }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = pages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        // 抽不出文字，多半是扫描版
        if text.isEmpty { throw AttachmentError.scannedPDF(name: name) }
        return text
        #else
        throw AttachmentError.unsupportedType(name: name)
        #endif
    }
}
