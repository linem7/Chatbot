import Foundation

#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// 图片缩放和编码（ARCHITECTURE §6）：长边 ≤ 2000px，有透明通道的保持 PNG，其他转成 JPEG（质量 0.85）。
/// 动图只取第一帧；EXIF 方向会应用到像素上。
enum ImageCompressor {
    static let maxPixelSize = 2_000
    static let jpegQuality = 0.85

    static func compress(_ data: Data, name: String) throws -> (Data, mediaType: String) {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw AttachmentError.unreadable(name: name)
        }

        // 用缩略图接口统一处理缩放和 EXIF 方向；小图按原尺寸，不放大
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError.unreadable(name: name)
        }

        let keepsAlpha = hasAlpha(image)
        let type = keepsAlpha ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw AttachmentError.unreadable(name: name)
        }
        let destinationOptions: [CFString: Any] = keepsAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AttachmentError.unreadable(name: name)
        }
        return (output as Data, keepsAlpha ? "image/png" : "image/jpeg")
        #else
        throw AttachmentError.unsupportedType(name: name)
        #endif
    }

    #if canImport(ImageIO)
    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
    #endif
}
