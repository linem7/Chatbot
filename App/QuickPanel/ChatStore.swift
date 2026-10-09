import ChatbotCore
import Foundation
import Observation

/// Quick Panel 的界面状态（ARCHITECTURE §4）。
///
/// Turn 在 TurnRunner 自己的 Task 里执行，面板隐藏不会打断它。#19 用内存里的 MessageStore，#20 换成 GRDB。
@MainActor
@Observable
final class ChatStore {
    /// 距离上次 Turn 结束不到这个时长，唤起面板时接着上一个 Conversation（SPEC §2.3）。
    nonisolated static let continuationWindow: TimeInterval = 10 * 60

    let connections: ConnectionStore
    let apiKeys: APIKeyStore
    private let runner: TurnRunner

    var draft = ""
    /// 输入区待发送的附件（「+」、粘贴、拖放）。和草稿文字一样，新开对话时不清空。
    var draftAttachments: [DraftAttachment] = []
    /// 加入附件失败时的提示（AttachmentError），显示在输入区上方；和发送时的 `notice` 分开。
    var attachmentNotice: String?
    /// 已经发出的附件，消息气泡按 `attachmentRef` 查这里显示。
    var attachmentsByID: [UUID: Attachment] = [:]
    private(set) var conversation: Conversation?
    private(set) var messages: [Message] = []
    private(set) var hasUnread = false
    /// 发送前的问题（例如还没有 API key），显示在消息区底部。
    private(set) var notice: String?
    private var turn: TurnHandle? {
        didSet {
            if turn == nil { stopMenuBarAnimation() } else { startMenuBarAnimation() }
        }
    }
    /// 生成中菜单栏图标的帧，由计时器推进。
    private var menuBarFrame = 0
    @ObservationIgnored private var menuBarAnimation: Task<Void, Never>?
    private var isPanelVisible = false
    private var lastTurnEndedAt: Date?

    /// 由菜单栏的视图注入：在 SwiftUI 场景之外打开设置窗口。
    @ObservationIgnored var openSettings: @MainActor () -> Void = {}
    /// 由 QuickPanelController 注入：「+」打开文件面板（面板失焦时不隐藏 Quick Panel）。
    @ObservationIgnored var presentFilePicker: @MainActor () -> Void = {}

    init(connections: ConnectionStore = ConnectionStore(), apiKeys: APIKeyStore = APIKeyStore()) {
        self.connections = connections
        self.apiKeys = apiKeys
        runner = TurnRunner(store: InMemoryMessageStore())
        conversation = makeConversation()
    }

    var isGenerating: Bool { turn != nil }

    var hasConnection: Bool { !connections.connections.isEmpty }

    /// 有文字或者有这次能发出去的附件才能发送。只有图片、而当前 Model 不接受图片时不能发送；
    /// 附件还在处理时也先不发（SPEC §4）。
    var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isGenerating && conversation != nil && !isProcessingAttachments && (hasText || hasSendableAttachments)
    }

    var title: String { conversation?.title ?? "" }

    var currentModel: ModelRef? {
        conversation.map { ModelRef(connectionID: $0.connectionID, modelID: $0.modelID) }
    }

    var menuBarState: MenuBarIconState {
        if isGenerating { return .generating(frame: menuBarFrame) }
        return hasUnread ? .unread : .idle
    }

    // MARK: - 面板

    func panelWillShow(now: Date = .now) {
        isPanelVisible = true
        hasUnread = false
        if conversation == nil
            || Self.shouldStartNewConversation(lastTurnEndedAt: lastTurnEndedAt, isGenerating: isGenerating, now: now) {
            newConversation()
        }
    }

    func panelDidHide() {
        isPanelVisible = false
    }

    nonisolated static func shouldStartNewConversation(lastTurnEndedAt: Date?, isGenerating: Bool, now: Date) -> Bool {
        // 后台还有回答在生成时，一律接着那个 Conversation
        if isGenerating { return false }
        guard let lastTurnEndedAt else { return false }
        return now.timeIntervalSince(lastTurnEndedAt) >= continuationWindow
    }

    // MARK: - Conversation

    /// ⌘N 或顶栏的「新对话」。生成中时先停止当前回答（按 interrupted 落库），再新开（SPEC §2.4）。
    func newConversation() {
        turn?.cancel()
        turn = nil
        conversation = makeConversation()
        messages = []
        notice = nil
        lastTurnEndedAt = nil
    }

    /// 模型选择器：还没有消息时直接改掉当前 Conversation 的 Model，否则用新 Model 开一个新 Conversation。
    /// 正在生成时和 ⌘N 一样，先停止当前回答再新开（SPEC §3）。
    func selectModel(_ model: ModelRef) {
        guard model != currentModel else { return }
        if messages.isEmpty, var conversation {
            conversation.connectionID = model.connectionID
            conversation.modelID = model.modelID
            self.conversation = conversation
        } else {
            newConversation()
            conversation = makeConversation(model: model)
        }
    }

    /// 设置里保存了 Connection 之后调用：之前没有可用的 Model 时，现在补一个 Conversation。
    func connectionsDidChange() {
        if conversation == nil { conversation = makeConversation() }
    }

    private func makeConversation(model: ModelRef? = nil) -> Conversation? {
        guard let model = model ?? connections.defaultModel ?? firstAvailableModel() else { return nil }
        return Conversation(connectionID: model.connectionID, modelID: model.modelID)
    }

    private func firstAvailableModel() -> ModelRef? {
        for connection in connections.connections {
            if let model = connections.visibleModels(of: connection).first {
                return ModelRef(connectionID: connection.id, modelID: model.id)
            }
        }
        return nil
    }

    // MARK: - Turn

    func send() {
        guard canSend, var conversation, let connection = connections.connection(id: conversation.connectionID) else { return }
        let apiKey: String
        do {
            guard let key = try apiKeys.apiKey(for: connection.id) else {
                notice = ChatError.authentication.displayText
                return
            }
            apiKey = key
        } catch {
            notice = String(localized: "Couldn't read the API key from the Keychain.")
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = takeDraftAttachments()
        rememberAttachments(attachments)
        let userMessage = Message.user(text, attachments: attachments)
        if conversation.title.isEmpty {
            // 标题生成在 #20 里做，之前先用第一条用户消息的第一行（SPEC §8）；只有附件时用第一个附件的文件名
            conversation.title = text.isEmpty
                ? attachments.first?.originalName ?? ""
                : text.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        }
        conversation.lastMessageAt = userMessage.createdAt
        self.conversation = conversation

        // 没有得到回答的问题由 TurnRunner 在拼请求时去掉
        let history = messages
        messages.append(userMessage)
        draft = ""
        notice = nil

        let turn = runner.run(TurnInput(
            conversation: conversation,
            connection: connection,
            apiKey: apiKey,
            systemPrompt: SystemPrompt.default(),
            history: history,
            userMessage: userMessage,
            attachments: attachments
        ))
        self.turn = turn
        Task { await consume(turn, conversationID: conversation.id) }
    }

    /// 停止生成（⌘. 或停止按钮）。Esc 和失焦只隐藏面板，不调用它。
    func stop() {
        turn?.cancel()
    }

    /// 把 Turn 的更新合并进当前的消息列表。用户在生成中新开了对话的话，旧 Turn 的更新不再显示。
    private func consume(_ turn: TurnHandle, conversationID: UUID) async {
        for await update in turn.updates where conversation?.id == conversationID {
            switch update {
            case .updated(let answer), .finished(let answer):
                upsert(answer)
            }
        }
        guard self.turn === turn else { return }
        self.turn = nil
        let now = Date.now
        lastTurnEndedAt = now
        conversation?.lastMessageAt = now
        // 面板隐藏期间结束的，菜单栏显示未读
        if !isPanelVisible { hasUnread = true }
    }

    private func startMenuBarAnimation() {
        menuBarAnimation?.cancel()
        menuBarAnimation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.menuBarFrame += 1
            }
        }
    }

    private func stopMenuBarAnimation() {
        menuBarAnimation?.cancel()
        menuBarAnimation = nil
        menuBarFrame = 0
    }

    private func upsert(_ message: Message) {
        if let index = messages.lastIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }
}
