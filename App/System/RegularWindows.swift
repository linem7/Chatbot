import AppKit
import SwiftUI

/// 设置窗口和 Main Window 这类普通窗口的行为（#46，SPEC §1）：
/// - app 失去激活时不自动隐藏。这是 #46 的根因：SwiftUI 在菜单栏 app（LSUIElement）里创建的窗口
///   `hidesOnDeactivate` 为 true，用户点别的 app 时 AppKit 会把它们藏起来。
/// - 开着时临时出现在 Dock 和 ⌘Tab 里（激活策略 `.regular`），被别的窗口盖住也能切回来；
///   全部关掉后恢复成只在菜单栏（`.accessory`）。
///
/// Quick Panel 不经过这里：它不激活 app，失焦就隐藏，也不让 Dock 出现图标。
@MainActor
final class RegularWindows {
    enum Kind: Hashable, Sendable {
        case settings
        case main
    }

    static let shared = RegularWindows()

    private var openWindows: Set<Kind> = []

    func windowDidOpen(_ kind: Kind) {
        openWindows.insert(kind)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func windowWillClose(_ kind: Kind) {
        guard openWindows.remove(kind) != nil, openWindows.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
        Task {
            // 等窗口真的关掉。app 还在前台却已经没有窗口了，就把前台还给别的 app，免得焦点悬空
            await Task.yield()
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && ($0.canBecomeMain || $0 is QuickPanel) }
            if NSApp.isActive, !hasVisibleWindow { NSApp.hide(nil) }
        }
    }
}

extension View {
    /// 用在设置窗口和 Main Window 的根视图上，见 `RegularWindows`。
    func regularWindow(_ kind: RegularWindows.Kind) -> some View {
        background(RegularWindowConfigurator(kind: kind))
            .onAppear { RegularWindows.shared.windowDidOpen(kind) }
    }
}

/// 拿到所在的 NSWindow：关掉自动隐藏，并在它关闭时通知 `RegularWindows`。
private struct RegularWindowConfigurator: NSViewRepresentable {
    let kind: RegularWindows.Kind

    func makeNSView(context: Context) -> NSView {
        ConfiguratorView(kind: kind)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguratorView: NSView {
        private let kind: RegularWindows.Kind
        private var closeObserver: NSObjectProtocol?

        init(kind: RegularWindows.Kind) {
            self.kind = kind
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            guard let window else { return }
            window.hidesOnDeactivate = false
            RegularWindows.shared.windowDidOpen(kind)
            let kind = kind
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { RegularWindows.shared.windowWillClose(kind) }
            }
        }
    }
}
