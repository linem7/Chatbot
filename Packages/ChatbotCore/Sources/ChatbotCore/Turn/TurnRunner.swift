import Foundation

/// 执行一次 Turn 所需的输入。
public struct TurnInput: Sendable {
    public var conversation: Conversation
    public var connection: Connection
    /// 由 App 从 Keychain 读好再传进来。
    public var apiKey: String
    public var systemPrompt: String
    /// userMessage 之前的消息，不含 userMessage。
    public var history: [Message]
    public var userMessage: Message

    public init(
        conversation: Conversation,
        connection: Connection,
        apiKey: String,
        systemPrompt: String,
        history: [Message],
        userMessage: Message
    ) {
        self.conversation = conversation
        self.connection = connection
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.history = history
        self.userMessage = userMessage
    }
}

public enum TurnUpdate: Sendable, Hashable {
    /// 当前累积的完整 assistant Message，状态是 streaming。
    case updated(Message)
    /// 最后一个更新：状态是 complete / interrupted / failed，此时已经落库。
    case finished(Message)
}

/// 一次正在执行的 Turn。
public final class TurnHandle: Sendable {
    public let updates: AsyncStream<TurnUpdate>
    private let task: Task<Void, Never>

    init(updates: AsyncStream<TurnUpdate>, task: Task<Void, Never>) {
        self.updates = updates
        self.task = task
    }

    /// 取消这次 Turn。已经收到的部分保留，`updates` 里还会收到一个 interrupted 的 `finished`。
    public func cancel() {
        task.cancel()
    }
}

/// 执行一次 Turn（ARCHITECTURE §4，ADR-0001）：把一次回答需要的多次模型调用串起来，
/// 累积成一条 assistant Message，处理续接和取消，最后落库。
///
/// Turn 跑在自己的 Task 里，界面消失不会打断它。取消有两种方式，内部都是 `Task.cancel()`：
/// 调 `TurnHandle.cancel()`，或者取消正在迭代 `updates` 的 Task。两种方式都会以 interrupted 状态落库。
public struct TurnRunner: Sendable {
    /// `pause_turn` 最多续接这么多次，防止服务端一直要求续接。
    static let maxContinuations = 5

    private let store: any MessageStore
    private let makeAdapter: @Sendable (Connection) -> any ProviderAdapter

    public init(
        store: any MessageStore,
        makeAdapter: @escaping @Sendable (Connection) -> any ProviderAdapter = { $0.provider.makeAdapter() }
    ) {
        self.store = store
        self.makeAdapter = makeAdapter
    }

    public func run(_ input: TurnInput) -> TurnHandle {
        let (updates, continuation) = AsyncStream.makeStream(of: TurnUpdate.self)
        let task = Task {
            let final = await execute(input) { continuation.yield(.updated($0)) }
            continuation.yield(.finished(final))
            continuation.finish()
        }
        continuation.onTermination = { termination in
            // 调用方不再迭代（例如它的 Task 被取消了）：Turn 也取消，以 interrupted 状态落库
            if case .cancelled = termination { task.cancel() }
        }
        return TurnHandle(updates: updates, task: task)
    }

    private func execute(_ input: TurnInput, onUpdate: (Message) -> Void) async -> Message {
        var answer = Message(role: .assistant, status: .streaming, content: [])
        let adapter = makeAdapter(input.connection)
        let model = input.connection.models.first { $0.id == input.conversation.modelID }
        let webSearch = input.conversation.webSearchEnabled && (model?.capabilities.webSearch ?? false)

        do {
            let store = self.store
            try await Self.ignoringCancellation {
                try await store.saveUserMessage(input.userMessage, in: input.conversation)
            }

            var continuations = 0
            while true {
                var messages = input.history + [input.userMessage]
                // 续接时把当前内容原样发回去
                if !answer.content.isEmpty { messages.append(answer) }
                let request = ModelRequest(
                    connection: input.connection,
                    apiKey: input.apiKey,
                    modelID: input.conversation.modelID,
                    systemPrompt: input.systemPrompt,
                    messages: messages,
                    webSearch: webSearch
                )

                var finishReason: FinishReason?
                for try await event in adapter.stream(request) {
                    if case .finished(let reason) = event {
                        finishReason = reason
                    } else {
                        Self.apply(event, to: &answer)
                        onUpdate(answer)
                    }
                }
                try Task.checkCancellation()

                // .toolUse 时要执行 app 侧工具；v1 没有 app 侧工具，按结束处理
                guard finishReason == .pauseTurn, continuations < Self.maxContinuations else { break }
                continuations += 1
            }
            answer.status = .complete
        } catch {
            if error is CancellationError || Task.isCancelled {
                answer.status = .interrupted
            } else {
                answer.status = .failed(error as? ChatError ?? .providerError(String(describing: error)))
            }
        }

        // 落库失败不影响界面上已经显示的回答
        let store = self.store
        let finalAnswer = answer
        try? await Self.ignoringCancellation {
            try await store.saveAssistantMessage(finalAnswer, conversationID: input.conversation.id)
        }
        return answer
    }

    /// 取消之后仍然要落库（MessageStore 的约定）：放进非结构化的 Task 里执行，不继承当前 Task 的取消状态。
    /// GRDB 的异步 `write` 在已取消的 Task 里会直接抛 `CancellationError`。
    private static func ignoringCancellation(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await Task { try await operation() }.value
    }

    private static func apply(_ event: ModelEvent, to answer: inout Message) {
        switch event {
        case .textDelta(let delta):
            if let last = answer.content.indices.last, case .text(let text, let citations) = answer.content[last].kind {
                answer.content[last].kind = .text(text + delta, citations: citations)
            } else {
                answer.content.append(ContentBlock(.text(delta)))
            }
        case .toolCallStarted, .toolCallArgumentsDelta, .toolCallCompleted,
             .webSearchStarted, .citation, .providerData:
            // Web Search、Citation 和不透明数据在 #23、#24 里接入；v1 没有 app 侧工具
            break
        case .finished:
            break
        }
    }
}
