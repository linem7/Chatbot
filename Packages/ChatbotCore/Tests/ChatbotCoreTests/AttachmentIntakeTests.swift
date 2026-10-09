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

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 只在 Apple 平台上跑（CI）：图片用 CoreGraphics 现场画出来。
struct ImageAttachmentTests {
    /// 画一张纯色图，编码成 PNG。
    private func pngData(width: Int, height: Int, alpha: Bool) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelSize(_ data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try #require(properties[kCGImagePropertyPixelWidth] as? Int), try #require(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    @Test func largeOpaqueImagesAreShrunkTo2000pxAndBecomeJPEG() throws {
        let attachment = try AttachmentIntake().attachment(fromImageData: try pngData(width: 3_000, height: 1_000, alpha: false), name: "截图.png")
        #expect(attachment.kind == .image)
        guard case .image(let data, let mediaType) = attachment.content else { Issue.record("不是图片"); return }
        #expect(mediaType == "image/jpeg")
        let (width, height) = try pixelSize(data)
        #expect(width == 2_000)
        #expect((666...667).contains(height))
    }

    @Test func smallImagesWithTransparencyStayPNGAndAreNotEnlarged() throws {
        let attachment = try AttachmentIntake().attachment(fromImageData: try pngData(width: 100, height: 50, alpha: true), name: "图标.png")
        guard case .image(let data, let mediaType) = attachment.content else { Issue.record("不是图片"); return }
        #expect(mediaType == "image/png")
        let (width, height) = try pixelSize(data)
        #expect(width == 100 && height == 50)
    }

    @Test func imageFilesGoThroughTheSameRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("photo.PNG")
        try pngData(width: 2_500, height: 2_500, alpha: false).write(to: url)
        let attachment = try AttachmentIntake().attachment(fromFile: url)
        guard case .image(let data, _) = attachment.content else { Issue.record("不是图片"); return }
        #expect(try pixelSize(data) == (2_000, 2_000))
        #expect(attachment.originalName == "photo.PNG")
    }

    @Test func brokenImagesAreUnreadable() {
        #expect(throws: AttachmentError.unreadable(name: "坏的.png")) {
            try AttachmentIntake().attachment(fromImageData: Data([1, 2, 3]), name: "坏的.png")
        }
    }
}
#endif

#if canImport(PDFKit)
/// 只在 Apple 平台上跑（CI）。Fixtures/text.pdf 和 Fixtures/scanned.pdf 是手写的最小 PDF：
/// 前者有一行文字 "Hello PDF"，后者是一个空白页，模拟扫描版。
struct PDFAttachmentTests {
    private func fixtureURL(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    @Test func textIsExtractedLocally() throws {
        let attachment = try AttachmentIntake().attachment(fromFile: try fixtureURL("text.pdf"))
        #expect(attachment.kind == .pdf)
        guard case .text(let text) = attachment.content else { Issue.record("不是文字"); return }
        #expect(text.contains("Hello PDF"))
    }

    @Test func pdfsWithoutTextAreReportedAsScanned() throws {
        let url = try fixtureURL("scanned.pdf")
        #expect(throws: AttachmentError.scannedPDF(name: "scanned.pdf")) {
            try AttachmentIntake().attachment(fromFile: url)
        }
    }
}
#endif
