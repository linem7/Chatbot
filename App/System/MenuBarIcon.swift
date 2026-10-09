import AppKit
import SwiftUI

enum MenuBarIconState {
    case idle
    case generating
    /// 生成完了但用户还没看，下次打开面板后消失。
    case unread
}

private let symbolName = "bubble.left.and.text.bubble.right"

/// 菜单栏图标的三种状态（SPEC §2.3）。
struct MenuBarIcon: View {
    let state: MenuBarIconState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: symbolName)
        case .generating:
            Image(systemName: symbolName)
                .symbolEffect(.pulse)
        case .unread:
            Image(nsImage: Self.unreadImage)
        }
    }

    /// 图标右上角加一个小圆点。用 template 图片，颜色跟随菜单栏。
    @MainActor
    private static let unreadImage: NSImage = {
        let size = symbolImage()?.size ?? NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            symbolImage()?.draw(in: rect)
            let diameter: CGFloat = 6
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private func symbolImage() -> NSImage? {
    NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
}
