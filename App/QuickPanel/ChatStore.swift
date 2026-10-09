import ChatbotCore
import Foundation
import Observation

/// Quick Panel 的界面状态（ARCHITECTURE §4）。
///
/// Turn 在 TurnRunner 自己的 Task 里执行，面板隐藏不会打断它。消息存在 HistoryStore 里（ARCHITECTURE §5.2）。
@MainActor
@Observable
final class ChatStore {
    /// 距离上次 Turn 结束不到这个时长，唤起面板时接着上一个 Conversation（SPEC §2.3）。
    nonisolated static let continuationWindow: TimeInterval = 10 * 60

    let connections: ConnectionStore
    let apiKeys: APIKeyStore
    let history: HistoryStore
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
    /// 发送前的问题，显示在消息区底部。目前都和 API key 有关（没有 key、读不出 key），旁边给「打开设置」。
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
    /// 历史有变化（新消息、回答结束、生成了标题）时加一，Main Window 据此刷新列表。
    private(set) var historyRevision = 0
    /// 还没收尾的 Turn，包括已经取消、正在把 Interrupted 落库的，按所属的 Conversation 记下。
    /// 删除一个对话前只等它自己的 Turn；清空全部和退出前等全部。
    @ObservationIgnored private var pendingTurns: [ObjectIdentifier: PendingTurn] = [:]

    /// 由菜单栏的视图注入：在 SwiftUI 场景之外打开设置窗口。
    @ObservationIgnored var openSettings: @MainActor () -> Void = {}
    /// 由 QuickPanelController 注入：「+」打开文件面板（面板失焦时不隐藏 Quick Panel）。
    @ObservationIgnored var presentFilePicker: @MainActor () -> Void = {}
    /// 由菜单栏的视图注入：打开设置的 Connection 页并选中给定的 Connection（错误旁边的「打开设置」）。
    @ObservationIgnored var openConnectionSettings: @MainActor (UUID) -> Void = { _ in }
    /// 由菜单栏的视图注入：打开 Main Window，并选中给定的 Conversation。
    @ObservationIgnored var openMainWindow: @MainActor (UUID?) -> Void = { _ in }
    /// 由 AppDelegate 注入：弹出 Quick Panel。
    @ObservationIgnored var showQuickPanel: @MainActor () -> Void = {}

    init(history: HistoryStore, connections: ConnectionStore = ConnectionStore(), apiKeys: APIKeyStore = APIKeyStore()) {
        self.history = history
        self.connections = connections
        self.apiKeys = apiKeys
        let (titles, titleContinuation) = AsyncStream.makeStream(of: GeneratedTitle.self)
        runner = TurnRunner(
            store: history,
            titleGenerator: TitleGenerator(store: ForwardingTitleStore(base: history, continuation: titleContinuation))
        )
        conversation = makeConversation()
        Task { [weak self] in
            for await title in titles {
                self?.titleWasGenerated(title)
            }
        }
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

    /// Quick Panel 是否被固定住。固定时失焦、Esc、Hotkey 都不再收起面板，只有再点一次图钉才取消（SPEC §2.3，#59）。
    /// 只在本次运行内有效，不写进设置，重启 App 回到默认。
    var isPanelPinned = false

    func togglePanelPinned() {
        isPanelPinned.toggle()
    }

    /// 用户有没有拖过 Quick Panel。拖过之后，本次运行内再唤起就停在拖到的位置，不再重新定位（SPEC §2.2、#63）。
    /// 和 `isPanelPinned` 一样只在本次运行内有效，不写进设置。
    var hasMovedPanel = false

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

    /// 打开一个已保存的 Conversation，在 Quick Panel 里继续（Main Window 的「在 Quick Panel 中继续」）。
    /// 正在生成别的对话时，和 ⌘N 一样先停止；打开的正是正在生成的那个时，什么都不动。打开后 10 分钟规则从现在算起。
    func open(_ conversationID: UUID) async {
        if conversation?.id != conversationID {
            guard let stored = try? await history.conversation(conversationID) else { return }
            await load(stored)
        }
        lastTurnEndedAt = .now
    }

    /// 启动时调用：最近一个 Conversation 的最后一条消息不到 10 分钟，就把它装回来，
    /// 这样重启后马上唤起面板，仍然接着上一个对话（SPEC §2.3）。
    func restoreRecentConversation(now: Date = .now) async {
        guard messages.isEmpty, !isGenerating,
              let latest = try? await history.conversations().first,
              now.timeIntervalSince(latest.lastMessageAt) < Self.continuationWindow,
              // 读历史期间用户可能已经开始提问了
              messages.isEmpty, !isGenerating
        else { return }
        await load(latest)
        lastTurnEndedAt = latest.lastMessageAt
    }

    private func load(_ stored: Conversation) async {
        let storedMessages = (try? await history.messages(in: stored.id)) ?? []
        let storedAttachments = (try? await history.attachments(in: stored.id)) ?? []
        newConversation()
        conversation = stored
        messages = storedMessages
        rememberAttachments(storedAttachments)
    }

    /// 「在主窗口中打开」：只有已经发过消息（已经存进历史）的对话才能打开。
    var canOpenInMainWindow: Bool { !messages.isEmpty }

    func openInMainWindow() {
        openMainWindow(conversation?.id)
    }

    /// 删除一个 Conversation 之前调用。删的是当前对话时，先停止生成并换成新对话；
    /// 再等这个对话还在收尾的 Turn 落库，免得删除之后回答又写回去。
    /// 别的对话正在生成时不用等它：删除无关的对话会立即完成。
    func prepareToDelete(_ conversationID: UUID) async {
        if conversation?.id == conversationID { newConversation() }
        await waitForPendingTurns(of: conversationID)
    }

    /// 删除一个 Connection（连同它的 Conversation）之前调用。当前对话用的是它时，先停止生成并换成新对话。
    /// 这里等全部还在收尾的 Turn：删 Connection 很少见，不值得再记一份 Turn 和 Connection 的对应。
    func prepareToDeleteConnection(_ connectionID: UUID) async {
        if conversation?.connectionID == connectionID { newConversation() }
        await waitForPendingTurns()
    }

    /// 「清空全部历史」之前调用：停止生成，清掉当前对话，新开一个（SPEC §9）。
    func prepareToDeleteAll() async {
        newConversation()
        await waitForPendingTurns()
    }

    /// 退出 app 前调用：停止正在生成的回答，等它以 Interrupted 落库（SPEC §8），最多等 `timeout`。
    func stopForTermination(timeout: Duration = .seconds(3)) async {
        turn?.cancel()
        let deadline = ContinuousClock.now + timeout
        while !pendingTurns.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    var hasPendingTurns: Bool { !pendingTurns.isEmpty }

    /// 等还在收尾的 Turn 结束。给了 conversationID 时只等这个对话的。
    private func waitForPendingTurns(of conversationID: UUID? = nil) async {
        let tasks = pendingTurns.values
            .filter { conversationID == nil || $0.conversationID == conversationID }
            .map(\.task)
        for task in tasks {
            await task.value
        }
    }

    /// 历史在 ChatStore 之外变了（例如 30 天清理），让 Main Window 刷新。
    func historyDidChange() {
        historyRevision += 1
    }

    private func titleWasGenerated(_ generated: GeneratedTitle) {
        if conversation?.id == generated.conversationID {
            conversation?.title = generated.title
            conversation?.titleIsGenerated = true
        }
        historyRevision += 1
    }

    /// 地球按钮：只对当前 Conversation 开关 Web Search，新 Conversation 的初始状态由设置决定，默认关（SPEC §5）。
    /// 持久化：已经落库的 Conversation 立刻更新；还没落库的，第一次保存用户 Message 时会把这个字段一起写进去。
    func setWebSearchEnabled(_ enabled: Bool) {
        guard var conversation, conversation.webSearchEnabled != enabled else { return }
        conversation.webSearchEnabled = enabled
        self.conversation = conversation
        let id = conversation.id
        Task { try? await history.saveWebSearchEnabled(enabled, conversationID: id) }
    }

    /// 设置里保存或删除了 Connection 之后调用：之前没有可用的 Model 时，现在补一个 Conversation；
    /// 当前对话的 Connection 被删掉了，就新开一个。
    func connectionsDidChange() {
        if let conversation, connections.connection(id: conversation.connectionID) == nil {
            newConversation()
        } else if conversation == nil {
            conversation = makeConversation()
        }
    }

    private func makeConversation(model: ModelRef? = nil) -> Conversation? {
        guard let model = model ?? connections.defaultModel ?? firstAvailableModel() else { return nil }
        // 新 Conversation 默认不联网，除非用户在设置里改成默认开（SPEC §5、#68）
        return Conversation(connectionID: model.connectionID, modelID: model.modelID, webSearchEnabled: WebSearchDefault.isOn())
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
        guard canSend, var conversation, let connection = connections.connection(id: conversation.connectionID),
              let apiKey = readAPIKey(for: connection)
        else { return }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = takeDraftAttachments()
        rememberAttachments(attachments)
        let userMessage = Message.user(text, attachments: attachments)
        if conversation.title.isEmpty {
            // 后台生成标题之前，先用第一条用户消息的第一行（SPEC §8）；只有附件时用第一个附件的文件名
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

        start(TurnInput(
            conversation: conversation,
            connection: connection,
            apiKey: apiKey,
            systemPrompt: SystemPrompt.forRequest(),
            history: history,
            userMessage: userMessage,
            attachments: attachments
        ))
    }

    /// 最后一条回答是 Interrupted 或 Failed，并且没有在生成时，回答下面才显示操作按钮（SPEC §7）。
    /// Retry 只能对最后一条使用（CONTEXT.md）。
    var lastAnswerNeedsAction: Bool {
        guard !isGenerating, messages.count >= 2, let last = messages.last, last.role == .assistant,
              messages[messages.count - 2].role == .user
        else { return false }
        switch last.status {
        case .interrupted, .failed: return true
        case .streaming, .complete: return false
        }
    }

    /// Retry：用同一条用户 Message 重新执行一次 Turn，新回答沿用旧回答的 id，落库时原地替换（CONTEXT.md）。
    func retry() {
        guard lastAnswerNeedsAction, let conversation,
              let connection = connections.connection(id: conversation.connectionID),
              let apiKey = readAPIKey(for: connection)
        else { return }
        let oldAnswer = messages[messages.count - 1]
        let question = messages[messages.count - 2]
        let history = Array(messages.dropLast(2))
        // 旧回答先换成空的、生成中的回答，显示打字指示
        messages[messages.count - 1] = Message(id: oldAnswer.id, role: .assistant, status: .streaming, content: [])
        notice = nil

        start(TurnInput(
            conversation: conversation,
            connection: connection,
            apiKey: apiKey,
            systemPrompt: SystemPrompt.forRequest(),
            history: history,
            userMessage: question,
            attachments: question.attachmentIDs.compactMap { attachmentsByID[$0] },
            replacingAnswerID: oldAnswer.id
        ))
    }

    /// 错误旁边的「打开设置」：打开这个对话所用的 Connection。
    func openSettingsForCurrentConnection() {
        if let connectionID = conversation?.connectionID {
            openConnectionSettings(connectionID)
        } else {
            openSettings()
        }
    }

    /// 读出 Connection 的 API key。没有或者读不出来时，在消息区底部说明，旁边给「打开设置」。
    private func readAPIKey(for connection: Connection) -> String? {
        do {
            guard let key = try apiKeys.apiKey(for: connection.id) else {
                notice = ChatError.authentication.displayText
                return nil
            }
            return key
        } catch {
            notice = String(localized: "Couldn't read the API key from the Keychain.")
            return nil
        }
    }

    private func start(_ input: TurnInput) {
        let turn = runner.run(input)
        self.turn = turn
        let key = ObjectIdentifier(turn)
        let conversationID = input.conversation.id
        let task = Task {
            await consume(turn, conversationID: conversationID)
            pendingTurns[key] = nil
        }
        pendingTurns[key] = PendingTurn(conversationID: conversationID, task: task)
    }

    /// 停止生成（⌘. 或停止按钮）。Esc 和失焦只隐藏面板，不调用它。
    func stop() {
        turn?.cancel()
    }

    /// 把 Turn 的更新合并进当前的消息列表。用户在生成中新开了对话的话，旧 Turn 的更新不再显示。
    private func consume(_ turn: TurnHandle, conversationID: UUID) async {
        var isFirstUpdate = true
        for await update in turn.updates {
            if isFirstUpdate {
                // 第一个更新到达时，用户消息已经落库，Main Window 可以显示这个对话了
                isFirstUpdate = false
                historyRevision += 1
            }
            guard conversation?.id == conversationID else { continue }
            switch update {
            case .updated(let answer), .finished(let answer):
                upsert(answer)
            }
        }
        historyRevision += 1
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

/// 一个还没收尾的 Turn。
private struct PendingTurn {
    let conversationID: UUID
    let task: Task<Void, Never>
}

/// 后台生成的一个标题。
struct GeneratedTitle: Sendable {
    let conversationID: UUID
    let title: String
}

/// 把标题存进历史，再通知 ChatStore：TitleGenerator 在后台运行，存完之后没有别的回调。
private struct ForwardingTitleStore: TitleStore {
    let base: any TitleStore
    let continuation: AsyncStream<GeneratedTitle>.Continuation

    func saveGeneratedTitle(_ title: String, conversationID: UUID) async throws {
        try await base.saveGeneratedTitle(title, conversationID: conversationID)
        continuation.yield(GeneratedTitle(conversationID: conversationID, title: title))
    }
}
