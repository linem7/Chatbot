import Foundation

/// 保存后台生成的标题。
public protocol TitleStore: Sendable {
    func saveGeneratedTitle(_ title: String, conversationID: UUID) async throws
}

/// 第一次 Turn 结束后，用这个 Conversation 的 Model 在后台生成一次标题（SPEC §8）。
/// 失败时不提示，保留原来的标题（第一条用户消息的前一行）。
public struct TitleGenerator: Sendable {
    /// 标题最多这么多个字符。
    static let maxLength = 30

    static let systemPrompt = """
        根据下面这段对话，起一个简短的标题：不超过 15 个字（英文不超过 8 个词），\
        用对话所用的语言，只输出标题本身，不要引号、标点或任何解释。
        """

    private let store: any TitleStore
    private let makeAdapter: @Sendable (Connection) -> any ProviderAdapter

    public init(
        store: any TitleStore,
        makeAdapter: @escaping @Sendable (Connection) -> any ProviderAdapter = { $0.provider.makeAdapter() }
    ) {
        self.store = store
        self.makeAdapter = makeAdapter
    }

    public func generateTitle(
        for conversation: Conversation,
        connection: Connection,
        apiKey: String,
        question: Message,
        answer: Message
    ) async {
        let transcript = """
            用户：\(question.markdownText.prefix(2_000))

            助手：\(answer.markdownText.prefix(2_000))
            """
        let request = ModelRequest(
            connection: connection,
            apiKey: apiKey,
            modelID: conversation.modelID,
            systemPrompt: Self.systemPrompt,
            messages: [.user(transcript)],
            webSearch: false
        )

        var output = ""
        do {
            for try await event in makeAdapter(connection).stream(request) {
                if case .textDelta(let delta) = event { output += delta }
            }
        } catch {
            return
        }
        guard let title = Self.clean(output) else { return }
        try? await store.saveGeneratedTitle(title, conversationID: conversation.id)
    }

    /// 取第一行，去掉「标题：」前缀、引号、书名号和末尾的标点。什么都不剩时返回 nil。
    static func clean(_ raw: String) -> String? {
        guard var title = raw.split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        for label in ["标题：", "标题:", "title:"] where title.lowercased().hasPrefix(label) {
            title = String(title.dropFirst(label.count))
        }
        let wrappers = CharacterSet(charactersIn: "\"'“”‘’《》「」『』【】*")
        let trailingPunctuation = CharacterSet(charactersIn: "。.!！?？，,;；:：")
        var previous = ""
        while previous != title {
            previous = title
            title = title.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: wrappers)
            while let last = title.unicodeScalars.last, trailingPunctuation.contains(last) {
                title.unicodeScalars.removeLast()
            }
        }
        title = String(title.prefix(maxLength))
        return title.isEmpty ? nil : title
    }
}
