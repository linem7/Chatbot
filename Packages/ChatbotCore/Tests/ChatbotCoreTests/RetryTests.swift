import ChatbotCore
import Foundation
import Testing

/// Retry：用同一条用户 Message 重新执行一次 Turn，新回答替换旧回答（CONTEXT.md）。
struct RetryTests {
    private let connection = Connection.deepSeek()
    private let store = InMemoryMessageStore()

    private func run(_ adapter: ScriptedAdapter, _ input: TurnInput) async -> Message? {
        let runner = TurnRunner(store: store, makeAdapter: { _ in adapter })
        var last: Message?
        for await update in runner.run(input).updates {
            if case .finished(let message) = update { last = message }
        }
        return last
    }

    @Test func retryReplacesTheFailedAnswerInPlace() async throws {
        let conversation = Conversation(connectionID: connection.id, modelID: "deepseek-flash")
        let earlierQuestion = Message.user("早")
        let earlierAnswer = Message(role: .assistant, content: [ContentBlock(.text("早上好"))])
        let question = Message.user("今天天气怎么样")
        func input(replacing answerID: UUID? = nil) -> TurnInput {
            TurnInput(
                conversation: conversation,
                connection: connection,
                apiKey: "sk-test",
                systemPrompt: "",
                history: [earlierQuestion, earlierAnswer],
                userMessage: question,
                replacingAnswerID: answerID
            )
        }
        try await store.saveUserMessage(earlierQuestion, in: conversation)
        await store.saveAssistantMessage(earlierAnswer, conversationID: conversation.id)

        // 第一次：收到一部分之后出错
        let failing = ScriptedAdapter([[.event(.textDelta("晴")), .fail(ChatError.overloaded)]])
        let failed = try #require(await run(failing, input()))
        #expect(failed.status == .failed(.overloaded))

        // Retry：同一条用户 Message，沿用旧回答的 id
        let retrying = ScriptedAdapter([[.event(.textDelta("晴天")), .event(.finished(.stop))]])
        let retried = try #require(await run(retrying, input(replacing: failed.id)))
        #expect(retried.id == failed.id)
        #expect(retried.status == .complete)
        #expect(retried.markdownText == "晴天")

        // 库里只有一条回答，在原来的位置，内容是新的；用户 Message 也没有重复
        let saved = await store.messages(in: conversation.id)
        #expect(saved.map(\.id) == [earlierQuestion.id, earlierAnswer.id, question.id, failed.id])
        #expect(saved.last?.markdownText == "晴天")
        // 和 HistoryStore 一样保留第一次保存时的 createdAt
        #expect(saved.last?.createdAt == failed.createdAt)

        // 请求里不含旧回答
        let request = try #require(retrying.requests.first)
        #expect(request.messages == [earlierQuestion, earlierAnswer, question])
    }

    @Test func withoutReplacingAnswerIDEachTurnGetsANewAnswer() async throws {
        let conversation = Conversation(connectionID: connection.id, modelID: "deepseek-flash")
        let question = Message.user("你好")
        let input = TurnInput(
            conversation: conversation,
            connection: connection,
            apiKey: "sk-test",
            systemPrompt: "",
            history: [],
            userMessage: question
        )
        let first = try #require(await run(ScriptedAdapter([[.event(.textDelta("a")), .event(.finished(.stop))]]), input))
        let second = try #require(await run(ScriptedAdapter([[.event(.textDelta("b")), .event(.finished(.stop))]]), input))
        #expect(first.id != second.id)
    }
}
