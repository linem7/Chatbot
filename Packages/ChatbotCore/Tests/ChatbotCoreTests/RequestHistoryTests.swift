import ChatbotCore
import Foundation
import Testing

/// 没有得到回答的用户 Message 不会进入请求，避免连续两条 user。
struct RequestHistoryTests {
    private let connection = Connection.deepSeek()

    private func requestMessages(history: [Message], user: Message = .user("再试一次")) async throws -> [Message] {
        let adapter = ScriptedAdapter([[.event(.textDelta("好")), .event(.finished(.stop))]])
        let runner = TurnRunner(store: InMemoryMessageStore(), makeAdapter: { _ in adapter })
        let handle = runner.run(TurnInput(
            conversation: Conversation(connectionID: connection.id, modelID: "deepseek-flash"),
            connection: connection,
            apiKey: "sk-test",
            systemPrompt: "",
            history: history,
            userMessage: user
        ))
        for await _ in handle.updates {}
        return try #require(adapter.requests.first).messages
    }

    private func answer(_ text: String?, status: MessageStatus = .complete) -> Message {
        Message(role: .assistant, status: status, content: text.map { [ContentBlock(.text($0))] } ?? [])
    }

    @Test func failedEmptyAnswerIsDroppedTogetherWithItsQuestion() async throws {
        let first = Message.user("你好")
        let firstAnswer = answer("你好！")
        let failed = Message.user("这个问题失败了")
        let user = Message.user("再试一次")
        let messages = try await requestMessages(
            history: [first, firstAnswer, failed, answer(nil, status: .failed(.network))],
            user: user
        )
        #expect(messages == [first, firstAnswer, user])
    }

    @Test func interruptedEmptyAnswerIsDroppedToo() async throws {
        let user = Message.user("再试一次")
        let messages = try await requestMessages(history: [.user("刚发就停了"), answer(nil, status: .interrupted)], user: user)
        #expect(messages == [user])
    }

    /// 还没出正文就取消了，回答里只有 provider 的原生块。
    @Test func interruptedAnswerWithOnlyOpaqueBlocksIsDropped() async throws {
        let opaqueOnly = Message(
            role: .assistant,
            status: .interrupted,
            content: [ContentBlock(.opaque(provider: .anthropic, .object(["type": .string("thinking")])))]
        )
        let user = Message.user("再试一次")
        let messages = try await requestMessages(history: [.user("问题"), opaqueOnly], user: user)
        #expect(messages == [user])
    }

    /// 搜索之后出错，回答里只有 webSearch 块。
    @Test func failedAnswerWithOnlyWebSearchIsDropped() async throws {
        let searchOnly = Message(
            role: .assistant,
            status: .failed(.overloaded),
            content: [ContentBlock(.webSearch(query: "今天的天气"))]
        )
        let user = Message.user("再试一次")
        let messages = try await requestMessages(history: [.user("今天天气怎么样"), searchOnly], user: user)
        #expect(messages == [user])
    }

    @Test func partialAnswerIsKept() async throws {
        let question = Message.user("写一段代码")
        let partial = answer("先这样", status: .failed(.overloaded))
        let user = Message.user("继续")
        let messages = try await requestMessages(history: [question, partial], user: user)
        #expect(messages == [question, partial, user])
    }

    @Test func trailingQuestionWithoutAnswerIsDropped() async throws {
        let user = Message.user("再试一次")
        let messages = try await requestMessages(history: [.user("没有回答")], user: user)
        #expect(messages == [user])
    }
}
