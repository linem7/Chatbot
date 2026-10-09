import AppKit
import SwiftUI

enum MenuBarIconState: Equatable {
    case idle
    /// 生成中。MenuBarExtra 的 label 会被渲染成静态图片，`.symbolEffect` 不会播放，
    /// 所以由 store 的计时器推进 `frame`，在两张图之间切换。
    case generating(frame: Int)
    /// 生成完了但用户还没看，下次打开面板后消失。
    case unread
}

/// 菜单栏图标的三种状态（SPEC §2.3）。三种状态都用同样方式绘制的 template 图片，大小一致，颜色跟随菜单栏。
struct MenuBarIcon: View {
    let state: MenuBarIconState

    var body: some View {
        switch state {
        case .idle:
            Image(nsImage: Self.idleImage)
        case .generating(let frame):
            Image(nsImage: frame.isMultiple(of: 2) ? Self.idleImage : Self.dimmedImage)
        case .unread:
            Image(nsImage: Self.unreadImage)
        }
    }

    @MainActor private static let idleImage = makeImage(alpha: 1, dot: false)
    @MainActor private static let dimmedImage = makeImage(alpha: 0.35, dot: false)
    @MainActor private static let unreadImage = makeImage(alpha: 1, dot: true)

    private static func makeImage(alpha: CGFloat, dot: Bool) -> NSImage {
        let size = symbolImage()?.size ?? NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            symbolImage()?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            if dot {
                // 图标右上角的小圆点
                let diameter: CGFloat = 6
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

private func symbolImage() -> NSImage? {
    NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
}
