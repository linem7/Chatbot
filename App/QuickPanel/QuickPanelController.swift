import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 持有 Quick Panel：配置窗口、显示和隐藏、处理面板里的快捷键（ARCHITECTURE §7，SPEC §2.2–§2.4）。
///
/// 隐藏只是 `orderOut`，不影响正在执行的 Turn。
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 680
    private static let preferredHeight: CGFloat = 560
    private static let maxScreenHeightFraction: CGFloat = 0.7
    /// 面板顶边距屏幕顶边的比例，对应原型的「偏上居中」。
    private static let topOffsetFraction: CGFloat = 0.16
    private static let cornerRadius: CGFloat = 22

    private let store: ChatStore
    private let composer = ComposerHandle()
    private let panel: QuickPanel
    private var isShown = false
    private var keyMonitor: Any?
    /// 文件面板打开期间，Quick Panel 会失焦，但不应该隐藏。
    private var isPresentingFilePicker = false
    /// 为了打开文件面板激活过 app 时，原来在前台的 app。隐藏 Quick Panel 时把激活状态还给它
    /// （CONTEXT：Quick Panel 不抢走前台 app 的激活状态）。
    private var previousFrontmostApp: NSRunningApplication?

    init(store: ChatStore) {
        self.store = store
        panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.preferredHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 只有顶栏能拖（#63）：isMovable 给 performDrag 用；isMovableByWindowBackground 保持 false，
        // 否则在消息区按住想选字会变成拖窗口
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = makeContentView()
        store.presentFilePicker = { [weak self] in self?.presentFilePicker() }
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        guard !isShown else { return }
        // app 被隐藏（hidden）时，不激活 app 的面板也显示不出来；只取消隐藏，不激活
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        isShown = true
        store.panelWillShow()
        // 拖过之后就停在拖到的位置，重新唤起不再回到屏幕中间（SPEC §2.2、#63）
        if !store.hasMovedPanel { positionOnMouseScreen() }
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        composer.focus()
        installKeyMonitor()
    }

    /// 再按一次 Hotkey、按 Esc、失焦时调用。只隐藏，不停止生成。
    ///
    /// 固定住时什么都不做（SPEC §2.3，#59）。三种收起方式都走这里，所以守卫放在这一处就够，
    /// 调用点不用各自判断。
    func hide() {
        guard isShown, !store.isPanelPinned else { return }
        isShown = false
        removeKeyMonitor()
        panel.orderOut(nil)
        store.panelDidHide()
        restorePreviousFrontmostApp()
    }

    /// 把激活状态还给打开文件面板之前在前台的 app。设置窗口（以后还有主窗口）开着时，说明用户正在用我们的 app，不还。
    private func restorePreviousFrontmostApp() {
        guard let app = previousFrontmostApp else { return }
        previousFrontmostApp = nil
        // 用户已经自己切到别的 app 了，就不要再把焦点抢回去
        guard NSApp.isActive else { return }
        let hasOtherVisibleWindow = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        guard !hasOtherVisibleWindow, !app.isTerminated else { return }
        app.receiveActivation()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isPresentingFilePicker else { return }
        // 固定住时 hide() 会挡掉，面板留在原地（SPEC §2.3）
        hide()
    }

    // MARK: - 「+」添加附件

    /// 打开文件面板选附件（SPEC §4）。
    ///
    /// Quick Panel 是不激活 app 的面板，app 本身不在前台，文件面板可能出现在别的 app 的窗口后面。
    /// 所以打开前先激活 app 兜底；关闭后让 Quick Panel 重新成为 key window，焦点回到输入框。
    /// 激活过的话，隐藏 Quick Panel 时再把激活状态还给原来的 app（见 `restorePreviousFrontmostApp`）。
    private func presentFilePicker() {
        guard isShown, !isPresentingFilePicker else { return }
        isPresentingFilePicker = true
        defer {
            isPresentingFilePicker = false
            panel.makeKeyAndOrderFront(nil)
            composer.focus()
        }
        // 激活前记下原来在前台的 app；我们的 app 本来就在前台时（例如设置窗口开着）不用记
        if previousFrontmostApp == nil, let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            previousFrontmostApp = frontmost
        }
        NSApp.activate()
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        guard openPanel.runModal() == .OK else { return }
        store.addAttachments(fromFiles: openPanel.urls)
    }

    // MARK: - 布局

    private func makeContentView() -> NSView {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.preferredHeight)
        let background = NSVisualEffectView(frame: frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedRectMask(cornerRadius: Self.cornerRadius)

        let hosting = NSHostingView(rootView: QuickPanelView(store: store, composer: composer))
        hosting.sizingOptions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        return background
    }

    /// 出现在鼠标所在屏幕的偏上居中位置。高度约 560pt，最多占可见区域的 70%。
    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let width = min(Self.width, visible.width - 32)
        let height = min(Self.preferredHeight, visible.height * Self.maxScreenHeightFraction)
        let top = min(screen.frame.maxY - screen.frame.height * Self.topOffsetFraction, visible.maxY)
        let originY = max(visible.minY, top - height)
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: originY, width: width, height: height), display: false)
    }

    // MARK: - 快捷键

    /// AppKit 把 Esc 和 ⌘. 都当作 `cancelOperation:`，所以不用 `.onExitCommand`，
    /// 而是在这里按 keyCode 区分：Esc 隐藏面板，⌘. 停止生成（SPEC §2.4）。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKeyDown(event) else { return event }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            // 输入法正在组字时，Esc 交给输入法取消组字。
            if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            hide()
            return true
        }

        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case ".":
            store.stop()
            return true
        case "n":
            store.newConversation()
            composer.focus()
            return true
        default:
            return false
        }
    }
}

private extension NSImage {
    /// `NSVisualEffectView.maskImage` 用的圆角矩形，可以拉伸到任意尺寸。
    static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
