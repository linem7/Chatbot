import ChatbotCore
import Foundation
import Testing

struct TitleGeneratorTests {
    private let connection = Connection.deepSeek()
    private let store = InMemoryMessageStore()

    private func firstTurn() async throws -> (Conversation, Message, Message) {
        let conversation = Conversation(connectionID: connection.id, modelID: "deepseek-flash")
        let question = Message.user("Swift 里 actor 和 class 有什么区别？")
        let answer = Message(role: .assistant, content: [ContentBlock(.text("actor 会隔离可变状态……"))])
        try await store.saveUserMessage(question, in: conversation)
        try await store.saveAssistantMessage(answer, conversationID: conversation.id)
        return (conversation, question, answer)
    }

    private func generate(_ adapter: ScriptedAdapter) async throws -> Conversation? {
        let (conversation, question, answer) = try await firstTurn()
        await TitleGenerator(store: store, makeAdapter: { _ in adapter }).generateTitle(
            for: conversation, connection: connection, apiKey: "sk-test", question: question, answer: answer
        )
        return await store.conversation(conversation.id)
    }

    @Test func savesTheModelsTitleWithoutQuotesOrTrailingPunctuation() async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta("“Swift actor 与 class")), .event(.textDelta(" 的区别”。\n多余的行")), .event(.finished(.stop))]])
        let conversation = try #require(try await generate(adapter))
        #expect(conversation.title == "Swift actor 与 class 的区别")
        #expect(conversation.titleIsGenerated)

        // 用这个 Conversation 的 Model，不开搜索，把问题和回答都发过去
        let request = try #require(adapter.requests.first)
        #expect(request.modelID == "deepseek-flash")
        #expect(request.apiKey == "sk-test")
        #expect(request.webSearch == false)
        let prompt = request.messages.map(\.markdownText).joined()
        #expect(prompt.contains("actor 和 class 有什么区别"))
        #expect(prompt.contains("actor 会隔离可变状态"))
    }

    @Test(arguments: ["标题：Swift 并发", "Title: Swift 并发", "《Swift 并发》"])
    func labelsAndBracketsAreStripped(raw: String) async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta(raw)), .event(.finished(.stop))]])
        #expect(try await generate(adapter)?.title == "Swift 并发")
    }

    @Test func failureLeavesTheTitleUntouched() async throws {
        let adapter = ScriptedAdapter([[.fail(ChatError.overloaded)]])
        let conversation = try #require(try await generate(adapter))
        #expect(conversation.title.isEmpty)
        #expect(!conversation.titleIsGenerated)
    }

    @Test func blankOutputLeavesTheTitleUntouched() async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta(" \n「」")), .event(.finished(.stop))]])
        #expect(try await generate(adapter)?.titleIsGenerated == false)
    }

    @Test func veryLongTitlesAreCut() async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta(String(repeating: "长", count: 100))), .event(.finished(.stop))]])
        #expect(try await generate(adapter)?.title.count == TitleGenerator.maxLength)
    }
}

struct TurnRunnerTitleTests {
    private let connection = Connection.deepSeek()
    private let store = InMemoryMessageStore()

    private func run(history: [Message], adapter: ScriptedAdapter) async -> TurnInput {
        let input = TurnInput(
            conversation: Conversation(connectionID: connection.id, modelID: "deepseek-flash"),
            connection: connection,
            apiKey: "sk-test",
            systemPrompt: "",
            history: history,
            userMessage: .user("问题")
        )
        let runner = TurnRunner(
            store: store,
            makeAdapter: { _ in adapter },
            titleGenerator: TitleGenerator(store: store, makeAdapter: { _ in adapter })
        )
        for await _ in runner.run(input).updates {}
        return input
    }

    @Test func firstTurnGeneratesATitleInTheBackground() async throws {
        let adapter = ScriptedAdapter([
            [.event(.textDelta("回答")), .event(.finished(.stop))],
            [.event(.textDelta("生成的标题")), .event(.finished(.stop))],
        ])
        let input = await run(history: [], adapter: adapter)

        for _ in 0..<200 where await store.conversation(input.conversation.id)?.titleIsGenerated != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.conversation(input.conversation.id)?.title == "生成的标题")
    }

    @Test func laterTurnsDoNotGenerateTitles() async throws {
        let adapter = ScriptedAdapter([
            [.event(.textDelta("回答")), .event(.finished(.stop))],
            [.event(.textDelta("不该出现的标题")), .event(.finished(.stop))],
        ])
        _ = await run(history: [.user("之前的问题"), Message(role: .assistant, content: [ContentBlock(.text("之前的回答"))])], adapter: adapter)
        try await Task.sleep(for: .milliseconds(50))
        #expect(adapter.requests.count == 1)
    }

    @Test func failedFirstTurnDoesNotGenerateATitle() async throws {
        let adapter = ScriptedAdapter([[.fail(ChatError.network)], [.event(.textDelta("标题")), .event(.finished(.stop))]])
        _ = await run(history: [], adapter: adapter)
        try await Task.sleep(for: .milliseconds(50))
        #expect(adapter.requests.count == 1)
    }
}
