import AppKit
import KeyboardShortcuts

/// 持有 Hotkey、Quick Panel 和定时任务（ARCHITECTURE §2）。
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
