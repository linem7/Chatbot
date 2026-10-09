import ChatbotCore
import Foundation
import Testing

struct HistoryStoreTests {
    /// 每个测试一个临时目录：history.sqlite 和 attachments/ 都在里面。
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    private let connectionID = UUID()

    private func openStore() throws -> HistoryStore {
        try HistoryStore(directory: directory)
    }

    private func conversation(lastMessageAt: Date = Date(timeIntervalSince1970: 1_000)) -> Conversation {
        Conversation(
            connectionID: connectionID,
            modelID: "deepseek-flash",
            createdAt: lastMessageAt,
            lastMessageAt: lastMessageAt
        )
    }

    /// 保存一问一答，返回 Conversation。
    @discardableResult
    private func saveExchange(
        _ store: HistoryStore,
        question: String,
        answer: String,
        at date: Date = Date(timeIntervalSince1970: 1_000)
    ) async throws -> Conversation {
        let conversation = conversation(lastMessageAt: date)
        try await store.saveUserMessage(Message(role: .user, content: [ContentBlock(.text(question))], createdAt: date), in: conversation)
        try await store.saveAssistantMessage(
            Message(role: .assistant, content: [ContentBlock(.text(answer))], createdAt: date),
            conversationID: conversation.id
        )
        return conversation
    }

    // MARK: 保存和读取

    @Test func historySurvivesReopeningTheDatabase() async throws {
        let conversation = conversation()
        let user = Message(role: .user, content: [ContentBlock(.text("你好"))], createdAt: Date(timeIntervalSince1970: 1_000.123_456))
        let answer = Message(
            role: .assistant,
            status: .failed(.rateLimited(retryAfter: 7)),
            content: [
                ContentBlock(.webSearch(query: "天气")),
                ContentBlock(
                    .text("晴", citations: [CitationSpan(citation: Citation(title: "气象台", url: URL(string: "https://example.com")!), textRange: 0..<1)]),
                    providerData: .object(["signature": .string("abc"), "n": .number(1)])
                ),
            ],
            createdAt: Date(timeIntervalSince1970: 1_001.5)
        )

        do {
            let store = try openStore()
            try await store.saveUserMessage(user, in: conversation)
            try await store.saveAssistantMessage(answer, conversationID: conversation.id)
        }

        let reopened = try openStore()
        let conversations = try await reopened.conversations()
        #expect(conversations.map(\.id) == [conversation.id])
        #expect(try await reopened.messages(in: conversation.id) == [user, answer])
    }

    @Test(arguments: [
        MessageStatus.streaming, .complete, .interrupted,
        .failed(.authentication), .failed(.rateLimited(retryAfter: nil)), .failed(.rateLimited(retryAfter: 2.5)),
        .failed(.overloaded), .failed(.network), .failed(.contextTooLong), .failed(.unsupportedInput),
        .failed(.invalidRequest("bad")), .failed(.providerError("原始信息")),
    ])
    func everyStatusRoundTrips(status: MessageStatus) async throws {
        let store = try openStore()
        let conversation = conversation()
        let user = Message.user("q")
        let answer = Message(role: .assistant, status: status, content: [ContentBlock(.text("a"))])
        try await store.saveUserMessage(user, in: conversation)
        try await store.saveAssistantMessage(answer, conversationID: conversation.id)
        #expect(try await store.messages(in: conversation.id).last?.status == status)
    }

    @Test func firstUserMessageLineIsTheTitleUntilOneIsGenerated() async throws {
        let store = try openStore()
        let conversation = conversation()
        try await store.saveUserMessage(.user("\n  帮我看看这段代码  \n第二行"), in: conversation)
        let saved = try #require(try await store.conversations().first)
        #expect(saved.title == "帮我看看这段代码")
        #expect(saved.titleIsGenerated == false)

        try await store.saveGeneratedTitle("代码审查", conversationID: conversation.id)
        let renamed = try #require(try await store.conversations().first)
        #expect(renamed.title == "代码审查")
        #expect(renamed.titleIsGenerated == true)
    }

    @Test func savingTheSameMessageAgainReplacesIt() async throws {
        let store = try openStore()
        let conversation = conversation()
        let user = Message.user("q")
        var answer = Message(role: .assistant, status: .interrupted, content: [ContentBlock(.text("半"))])
        try await store.saveUserMessage(user, in: conversation)
        try await store.saveAssistantMessage(answer, conversationID: conversation.id)
        answer.status = .complete
        answer.content = [ContentBlock(.text("完整的回答"))]
        try await store.saveAssistantMessage(answer, conversationID: conversation.id)

        #expect(try await store.messages(in: conversation.id) == [user, answer])
    }

    @Test func savingTheSameUserMessageAgainIsAnUpsert() async throws {
        // Retry 会用同一条用户 Message 再执行一次 Turn
        let store = try openStore()
        let conversation = conversation()
        let question = Message.user("q")
        let answer = Message(role: .assistant, status: .failed(.network), content: [])
        try await store.saveUserMessage(question, in: conversation)
        try await store.saveAssistantMessage(answer, conversationID: conversation.id)
        try await store.saveUserMessage(question, in: conversation)

        #expect(try await store.messages(in: conversation.id) == [question, answer])
        #expect(try await store.conversations().count == 1)
    }

    @Test func conversationsAreSortedByLastMessageNewestFirst() async throws {
        let store = try openStore()
        let old = try await saveExchange(store, question: "旧", answer: "a", at: Date(timeIntervalSince1970: 1_000))
        let new = try await saveExchange(store, question: "新", answer: "b", at: Date(timeIntervalSince1970: 3_000))
        let middle = try await saveExchange(store, question: "中", answer: "c", at: Date(timeIntervalSince1970: 2_000))
        #expect(try await store.conversations().map(\.id) == [new.id, middle.id, old.id])
    }

    @Test func newMessagesMoveTheConversationToTheTop() async throws {
        let store = try openStore()
        let first = try await saveExchange(store, question: "一", answer: "a", at: Date(timeIntervalSince1970: 1_000))
        let second = try await saveExchange(store, question: "二", answer: "b", at: Date(timeIntervalSince1970: 2_000))
        try await store.saveUserMessage(Message(role: .user, content: [ContentBlock(.text("继续"))], createdAt: Date(timeIntervalSince1970: 3_000)), in: first)
        #expect(try await store.conversations().map(\.id) == [first.id, second.id])
    }

    // MARK: 全文搜索

    @Test func searchFindsWordsInsideAnswersIncludingShortChineseWords() async throws {
        let store = try openStore()
        let match = try await saveExchange(store, question: "怎么备份", answer: "可以用时间机器备份整个磁盘")
        try await saveExchange(store, question: "别的", answer: "无关内容")

        #expect(try await store.search("时间机器").map(\.id) == [match.id])
        // 中文两个字的词也要能搜到
        #expect(try await store.search("磁盘").map(\.id) == [match.id])
        #expect(try await store.search("盘").map(\.id) == [match.id])
    }

    @Test(arguments: [
        ("盘", true), ("磁盘", true), ("时间机器", true),
        ("ui", true), ("UI", true), ("SwiftUI", true),
        ("硬盘", false), ("xy", false),
    ])
    func shortAndLongQueriesBothWork(query: String, matches: Bool) async throws {
        // trigram 的 MATCH 对少于 3 个字符的查询什么都匹配不到，短查询要退回 LIKE
        let store = try openStore()
        let conversation = try await saveExchange(store, question: "q", answer: "用时间机器备份磁盘，界面是 SwiftUI 写的")
        #expect(try await store.search(query).map(\.id) == (matches ? [conversation.id] : []))
    }

    @Test func searchIsCaseInsensitiveAndCoversTitles() async throws {
        let store = try openStore()
        let conversation = try await saveExchange(store, question: "q", answer: "Use SwiftUI here")
        try await store.saveGeneratedTitle("Xcode 设置", conversationID: conversation.id)

        #expect(try await store.search("swiftui").map(\.id) == [conversation.id])
        #expect(try await store.search("xcode").map(\.id) == [conversation.id])
    }

    @Test func searchTreatsWildcardsLiterally() async throws {
        let store = try openStore()
        let match = try await saveExchange(store, question: "q", answer: "折扣 50% off")
        try await saveExchange(store, question: "q", answer: "50 percent")
        #expect(try await store.search("50%").map(\.id) == [match.id])
        #expect(try await store.search("_").isEmpty)
    }

    @Test func emptySearchReturnsEverything() async throws {
        let store = try openStore()
        try await saveExchange(store, question: "a", answer: "b")
        try await saveExchange(store, question: "c", answer: "d")
        #expect(try await store.search("  ").count == 2)
    }

    // MARK: 删除和清理

    @Test func deletingAConversationRemovesItsMessagesSearchEntriesAndAttachments() async throws {
        let store = try openStore()
        let gone = try await saveExchange(store, question: "要删掉的", answer: "独特词汇")
        let kept = try await saveExchange(store, question: "留下的", answer: "其他")
        let attachments = try makeAttachmentDirectory(for: gone.id)

        try await store.deleteConversation(gone.id)

        #expect(try await store.conversations().map(\.id) == [kept.id])
        #expect(try await store.messages(in: gone.id).isEmpty)
        #expect(try await store.search("独特").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: attachments.path))
    }

    @Test func deleteAllEmptiesTheHistory() async throws {
        let store = try openStore()
        let conversation = try await saveExchange(store, question: "a", answer: "b")
        let attachments = try makeAttachmentDirectory(for: conversation.id)
        try await store.deleteAll()
        #expect(try await store.conversations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: attachments.path))
    }

    @Test func deletingAConnectionDeletesItsConversations() async throws {
        let store = try openStore()
        let mine = try await saveExchange(store, question: "a", answer: "b")
        let other = Conversation(connectionID: UUID(), modelID: "m")
        try await store.saveUserMessage(.user("别的 Connection"), in: other)

        try await store.deleteConversations(connectionID: connectionID)
        #expect(try await store.conversations().map(\.id) == [other.id])
        #expect(try await store.messages(in: mine.id).isEmpty)
    }

    @Test func cleanupSilentlyDeletesConversationsQuietForMoreThan30Days() async throws {
        let store = try openStore()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let stale = try await saveExchange(store, question: "31 天前", answer: "a", at: now.addingTimeInterval(-31 * 86_400))
        let fresh = try await saveExchange(store, question: "29 天前", answer: "b", at: now.addingTimeInterval(-29 * 86_400))
        let attachments = try makeAttachmentDirectory(for: stale.id)

        let deleted = try await store.deleteExpiredConversations(now: now)

        #expect(deleted == 1)
        #expect(try await store.conversations().map(\.id) == [fresh.id])
        #expect(!FileManager.default.fileExists(atPath: attachments.path))
    }

    // MARK: 和 TurnRunner 一起

    @Test func cancelledTurnIsSavedAsInterruptedByTheRealStore() async throws {
        // GRDB 的 write 在已取消的 Task 里会直接抛 CancellationError；TurnRunner 要绕开它
        let store = try openStore()
        let adapter = ScriptedAdapter([[.event(.textDelta("一半")), .hang]])
        let input = TurnInput(
            conversation: conversation(),
            connection: .deepSeek(),
            apiKey: "sk-test",
            systemPrompt: "",
            history: [],
            userMessage: .user("问题")
        )
        let handle = TurnRunner(store: store, makeAdapter: { _ in adapter }).run(input)
        var received = 0
        for await _ in handle.updates {
            received += 1
            if received == 1 { handle.cancel() }
        }

        let saved = try await openStore().messages(in: input.conversation.id)
        #expect(saved.count == 2)
        #expect(saved.first == input.userMessage)
        #expect(saved.last?.status == .interrupted)
        #expect(saved.last?.markdownText == "一半")
    }

    private func makeAttachmentDirectory(for conversationID: UUID) throws -> URL {
        let url = directory.appendingPathComponent("attachments/\(conversationID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("a.png"))
        return url
    }
}
