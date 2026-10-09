import ChatbotCore
import Foundation
import Testing

/// 文本文件的用例在 Linux 上也能跑；图片和 PDF 依赖 ImageIO、PDFKit，只在 Apple 平台上跑（CI）。
struct AttachmentIntakeTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AttachmentIntakeTests-\(UUID().uuidString)", isDirectory: true)

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func file(_ name: String, text: String) throws -> URL {
        try file(name, Array(text.utf8))
    }

    // MARK: 文本和代码

    @Test func sourceFilesBecomeTextAttachments() throws {
        let attachment = try AttachmentIntake().attachment(fromFile: try file("main.swift", text: "print(\"你好\")\n"))
        #expect(attachment.kind == .text)
        #expect(attachment.originalName == "main.swift")
        #expect(attachment.content == .text("print(\"你好\")\n"))
    }

    @Test func unknownExtensionsAreAcceptedWhenTheyAreText() throws {
        let attachment = try AttachmentIntake().attachment(fromFile: try file("Makefile", text: "all:\n\tswift build\n"))
        #expect(attachment.content == .text("all:\n\tswift build\n"))
    }

    @Test func utf8ByteOrderMarkIsRemoved() throws {
        let attachment = try AttachmentIntake().attachment(fromFile: try file("a.csv", [0xEF, 0xBB, 0xBF] + Array("a,b".utf8)))
        #expect(attachment.content == .text("a,b"))
    }

    @Test func utf16WithByteOrderMarkIsDecoded() throws {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in "中文 text".utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        let attachment = try AttachmentIntake().attachment(fromFile: try file("a.txt", bytes))
        #expect(attachment.content == .text("中文 text"))
    }

    @Test func binaryFilesAreRejected() throws {
        // .docx 是 zip，里面有 NUL 字节
        let url = try file("报告.docx", [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00, 0x00, 0x00])
        #expect(throws: AttachmentError.unsupportedType(name: "报告.docx")) {
            try AttachmentIntake().attachment(fromFile: url)
        }
    }

    @Test func eachAttachmentGetsItsOwnID() throws {
        let url = try file("a.md", text: "# a")
        #expect(try AttachmentIntake().attachment(fromFile: url).id != AttachmentIntake().attachment(fromFile: url).id)
    }
}
