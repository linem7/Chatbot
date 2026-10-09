import AppKit
import ChatbotCore
import KeyboardShortcuts
import os

/// 持有 Hotkey、Quick Panel、历史和定时任务（ARCHITECTURE §2）。
/// 显式标注 @MainActor：只靠 NSApplicationDelegate 推断隔离时，下面几个 lazy 属性的默认值会被当作在非隔离上下文里求值。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.linem7.Chatbot", category: "History")

    private(set) lazy var history = Self.openHistory()
    private(set) lazy var chatStore = ChatStore(history: history)
    private(set) lazy var historyModel = HistoryModel(store: history, chat: chatStore)
    private var quickPanel: QuickPanelController?
    private var cleanup: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let quickPanel = QuickPanelController(store: chatStore)
        self.quickPanel = quickPanel
        KeyboardShortcuts.onKeyDown(for: .toggleQuickPanel) { [weak quickPanel] in
            quickPanel?.toggle()
        }
        chatStore.showQuickPanel = { [weak quickPanel] in
            quickPanel?.show()
        }
        Hotkey.warnIfTakenBySystem()

        // 启动时清理一次，之后每 24 小时一次（SPEC §8）
        let history = history
        cleanup = Task { await history.runPeriodicCleanup() }
    }

    /// 退出时，正在生成的回答以 Interrupted 保存（SPEC §8）。等它落库再退出，最多等几秒。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard chatStore.isGenerating || chatStore.hasPendingTurns else { return .terminateNow }
        let chatStore = chatStore
        Task {
            await chatStore.stopForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 历史在 `~/Library/Application Support/com.linem7.Chatbot/`（ARCHITECTURE §5.2）。
    /// 打不开时退到临时目录：app 仍然能用，只是这次的历史不会保留。
    private static func openHistory() -> HistoryStore {
        let directory = URL.applicationSupportDirectory.appending(path: "com.linem7.Chatbot", directoryHint: .isDirectory)
        do {
            return try HistoryStore(directory: directory)
        } catch {
            logger.error("Couldn't open history at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let fallback = URL.temporaryDirectory.appending(path: "com.linem7.Chatbot-\(UUID().uuidString)", directoryHint: .isDirectory)
            // 临时目录也打不开，说明磁盘出了大问题，没法继续
            return try! HistoryStore(directory: fallback)
        }
    }
}
