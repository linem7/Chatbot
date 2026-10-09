import AppKit
import KeyboardShortcuts

/// 持有 Hotkey、Quick Panel 和定时任务（ARCHITECTURE §2）。
/// 显式标注 @MainActor：只靠 NSApplicationDelegate 推断隔离时，下面 chatStore 的默认值会被当作在非隔离上下文里求值。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var chatStore = ChatStore()
    private var quickPanel: QuickPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let quickPanel = QuickPanelController(store: chatStore)
        self.quickPanel = quickPanel
        KeyboardShortcuts.onKeyDown(for: .toggleQuickPanel) { [weak quickPanel] in
            quickPanel?.toggle()
        }
        Hotkey.warnIfTakenBySystem()
    }
}
