import Foundation
import Observation

/// Quick Panel 的界面状态（ARCHITECTURE §4）。
///
/// Turn 在 TurnRunner 自己的 Task 里执行，面板隐藏不会打断它。
@MainActor
@Observable
final class ChatStore {
    /// 距离上次 Turn 结束不到这个时长，唤起面板时接着上一个 Conversation（SPEC §2.3）。
    nonisolated static let continuationWindow: TimeInterval = 10 * 60

    var draft = ""
    private(set) var title = ""
    private(set) var isGenerating = false
    private(set) var hasUnread = false
    private var isPanelVisible = false
    private var lastTurnEndedAt: Date?

    var canSend: Bool {
        !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var menuBarState: MenuBarIconState {
        if isGenerating { return .generating }
        return hasUnread ? .unread : .idle
    }

    func panelWillShow(now: Date = .now) {
        isPanelVisible = true
        hasUnread = false
        if Self.shouldStartNewConversation(lastTurnEndedAt: lastTurnEndedAt, isGenerating: isGenerating, now: now) {
            newConversation()
        }
    }

    func panelDidHide() {
        isPanelVisible = false
    }

    func send() {
        guard canSend else { return }
        // TODO(#19)：#18 合并后在这里组装 TurnInput，交给 TurnRunner。
    }

    /// 停止生成（⌘. 或停止按钮）。Esc 和失焦只隐藏面板，不调用它。
    func stop() {
        // TODO(#19)：调用 TurnHandle.cancel()，然后等流里的 finished 收尾。
    }

    func newConversation() {
        guard !isGenerating else { return }
        title = ""
        lastTurnEndedAt = nil
    }

    /// Turn 结束（完成、中断或失败）时调用。面板隐藏期间结束的，菜单栏显示未读。
    private func turnDidEnd(now: Date = .now) {
        isGenerating = false
        lastTurnEndedAt = now
        if !isPanelVisible { hasUnread = true }
    }

    nonisolated static func shouldStartNewConversation(lastTurnEndedAt: Date?, isGenerating: Bool, now: Date) -> Bool {
        if isGenerating { return false }
        guard let lastTurnEndedAt else { return true }
        return now.timeIntervalSince(lastTurnEndedAt) >= continuationWindow
    }
}
