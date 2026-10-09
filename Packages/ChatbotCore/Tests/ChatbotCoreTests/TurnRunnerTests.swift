import ChatbotCore
import Foundation
import Testing

struct TurnRunnerTests {
    private let connection = Connection.deepSeek()
    private let store = InMemoryMessageStore()

    private func input(history: [Message] = [], user: Message = .user("Hi")) -> TurnInput {
        TurnInput(
            conversation: Conversation(connectionID: connection.id, modelID: "deepseek-flash"),
            connection: connection,
            apiKey: "sk-test",
            systemPrompt: "简短回答",
            history: history,
            userMessage: user
        )
    }

    private func runner(_ adapter: ScriptedAdapter) -> TurnRunner {
        TurnRunner(store: store, makeAdapter: { _ in adapter })
    }

    private func collect(_ handle: TurnHandle) async -> [TurnUpdate] {
        var updates: [TurnUpdate] = []
        for await update in handle.updates { updates.append(update) }
        return updates
    }

    private func texts(_ updates: [TurnUpdate]) -> [String] {
        updates.map {
            switch $0 {
            case .updated(let message), .finished(let message): message.markdownText
            }
        }
    }

    private func finalMessage(_ updates: [TurnUpdate]) throws -> Message {
        guard case .finished(let message) = try #require(updates.last) else {
            Issue.record("最后一个更新不是 finished")
            throw CancellationError()
        }
        return message
    }

    @Test func textDeltasAccumulateIntoOneAssistantMessage() async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta("Hel")), .event(.textDelta("lo")), .event(.finished(.stop))]])
        let input = input(history: [.user("早"), Message(role: .assistant, content: [ContentBlock(.text("早上好"))])])
        let updates = await collect(runner(adapter).run(input))

        #expect(texts(updates) == ["Hel", "Hello", "Hello"])
        let final = try finalMessage(updates)
        #expect(final.role == .assistant)
        #expect(final.status == .complete)
        #expect(final.content == [ContentBlock(.text("Hello"))])
        // 中间的更新都是同一条 Message
        #expect(updates.allSatisfy {
            switch $0 { case .updated(let m), .finished(let m): m.id == final.id }
        })

        let request = try #require(adapter.requests.first)
        #expect(request.messages == input.history + [input.userMessage])
        #expect(request.systemPrompt == "简短回答")
        #expect(request.modelID == "deepseek-flash")
        #expect(request.apiKey == "sk-test")

        // 用户 Message 先落库，回答结束后 assistant Message 落库
        #expect(await store.messages(in: input.conversation.id) == [input.userMessage, final])
    }

    @Test func inMemoryStoreTreatsTheSameUserMessageAsAnUpsert() async throws {
        let question = Message.user("q")
        let conversation = Conversation(connectionID: connection.id, modelID: "deepseek-flash")
        try await store.saveUserMessage(question, in: conversation)
        try await store.saveUserMessage(question, in: conversation)
        #expect(await store.messages(in: conversation.id) == [question])
    }

    @Test func attachmentsOfThisAndEarlierMessagesArePassedToTheAdapter() async throws {
        let earlier = Attachment(kind: .text, originalName: "a.txt", content: .text("早先的附件"))
        let now = Attachment(kind: .image, originalName: "b.png", content: .image(Data([9]), mediaType: "image/png"))
        let first = Message.user("第一个问题", attachments: [earlier])
        let conversation = Conversation(connectionID: connection.id, modelID: "deepseek-flash")
        await store.saveUserMessage(first, attachments: [earlier], in: conversation)

        let adapter = ScriptedAdapter([[.event(.textDelta("好")), .event(.finished(.stop))]])
        let input = TurnInput(
            conversation: conversation,
            connection: connection,
            apiKey: "sk-test",
            systemPrompt: "",
            history: [first, Message(role: .assistant, content: [ContentBlock(.text("答"))])],
            userMessage: .user("再看这个", attachments: [now]),
            attachments: [now]
        )
        _ = await collect(runner(adapter).run(input))

        let request = try #require(adapter.requests.first)
        #expect(request.attachments == [earlier.id: earlier, now.id: now])
        #expect(await store.attachments(in: conversation.id) == [earlier, now])
    }

    @Test func pauseTurnSendsTheAnswerSoFarBackAndContinues() async throws {
        let adapter = ScriptedAdapter([
            [.event(.textDelta("A")), .event(.finished(.pauseTurn))],
            [.event(.textDelta("B")), .event(.finished(.stop))],
        ])
        let input = input()
        let updates = await collect(runner(adapter).run(input))

        let final = try finalMessage(updates)
        #expect(final.status == .complete)
        #expect(final.markdownText == "AB")
        #expect(adapter.requests.count == 2)
        let continued = try #require(adapter.requests.last?.messages)
        #expect(continued.count == 2)
        #expect(continued.last?.role == .assistant)
        #expect(continued.last?.markdownText == "A")
    }

    @Test func providerBlocksSearchesAndCitationsAccumulateAcrossPauseTurn() async throws {
        // Anthropic 风格的事件：原生块原样累积成一个 opaque 块；citation 的范围从「这次调用的正文偏移」换算成「所在 text 块的偏移」
        let source = Citation(title: "气象台", url: URL(string: "https://example.com/a")!)
        let other = Citation(title: "新闻", url: URL(string: "https://example.com/b")!)
        let rawText: JSONValue = .object(["type": .string("text"), "text": .string("先说")])
        let rawSearch: JSONValue = .object(["type": .string("server_tool_use"), "id": .string("srvtoolu_1")])
        let rawCited: JSONValue = .object(["type": .string("text"), "text": .string("晴")])
        let rawMore: JSONValue = .object(["type": .string("text"), "text": .string("。")])
        let adapter = ScriptedAdapter([
            [
                .event(.textDelta("先说")),
                .event(.providerData(blockIndex: 0, opaque: rawText)),
                .event(.webSearchStarted(query: "天气")),
                .event(.providerData(blockIndex: 1, opaque: rawSearch)),
                .event(.textDelta("晴")),
                // 这次调用里「晴」的偏移是 2..<3（前面有「先说」）
                .event(.citation(source, textRange: 2..<3)),
                .event(.providerData(blockIndex: 2, opaque: rawCited)),
                .event(.finished(.pauseTurn)),
            ],
            [
                // 续接的调用从 0 开始计偏移；「。」接在上一个 text 块后面
                .event(.textDelta("。")),
                .event(.citation(other, textRange: 0..<1)),
                .event(.providerData(blockIndex: 0, opaque: rawMore)),
                .event(.finished(.stop)),
            ],
        ])
        let connection = Connection.anthropic()
        let input = TurnInput(
            conversation: Conversation(connectionID: connection.id, modelID: "claude-opus-5"),
            connection: connection, apiKey: "k", systemPrompt: "", history: [], userMessage: .user("天气怎样")
        )
        let final = try finalMessage(await collect(TurnRunner(store: store, makeAdapter: { _ in adapter }).run(input)))

        #expect(final.status == .complete)
        #expect(final.content == [
            ContentBlock(.opaque(provider: .anthropic, .array([rawText, rawSearch, rawCited, rawMore]))),
            ContentBlock(.text("先说")),
            ContentBlock(.webSearch(query: "天气")),
            ContentBlock(.text("晴。", citations: [
                CitationSpan(citation: source, textRange: 0..<1),
                CitationSpan(citation: other, textRange: 1..<2),
            ])),
        ])
        #expect(final.markdownText == "先说晴。")
        // 续接时发回去的回答带着到目前为止的原生块
        let continued = try #require(adapter.requests.last?.messages.last)
        #expect(continued.content.first == ContentBlock(.opaque(provider: .anthropic, .array([rawText, rawSearch, rawCited]))))
    }

    @Test func errorKeepsPartialAnswerAndFails() async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta("Hi")), .fail(ChatError.overloaded)]])
        let input = input()
        let updates = await collect(runner(adapter).run(input))

        let final = try finalMessage(updates)
        #expect(final.status == .failed(.overloaded))
        #expect(final.markdownText == "Hi")
        #expect(await store.messages(in: input.conversation.id).last == final)
    }

    @Test func nonChatErrorBecomesProviderError() async throws {
        struct Weird: Error {}
        let adapter = ScriptedAdapter([[.fail(Weird())]])
        let final = try finalMessage(await collect(runner(adapter).run(input())))
        guard case .failed(.providerError) = final.status else {
            Issue.record("应该是 providerError，实际是 \(final.status)")
            return
        }
    }

    // MARK: 取消

    @Test func cancelViaHandleFinishesAsInterruptedWithPartialAnswer() async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta("Hi")), .hang]])
        let input = input()
        let handle = runner(adapter).run(input)

        var updates: [TurnUpdate] = []
        for await update in handle.updates {
            updates.append(update)
            if updates.count == 1 { handle.cancel() }
        }

        let final = try finalMessage(updates)
        #expect(final.status == .interrupted)
        #expect(final.markdownText == "Hi")
        #expect(await store.messages(in: input.conversation.id) == [input.userMessage, final])
    }

    @Test func cancellingTheConsumingTaskStillSavesInterruptedAnswer() async throws {
        let adapter = ScriptedAdapter([[.event(.textDelta("Hi")), .hang]])
        let input = input()
        let handle = runner(adapter).run(input)

        let consumer = Task {
            for await _ in handle.updates {}
        }
        // 等第一段文字到达后再取消调用方的 Task
        try await waitUntil { adapter.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()

        try await waitUntil { await store.messages(in: input.conversation.id).count == 2 }
        let saved = try #require(await store.messages(in: input.conversation.id).last)
        #expect(saved.status == .interrupted)
        #expect(saved.markdownText == "Hi")
    }

    @Test func cancelledTurnIsStillSavedByAStoreThatRejectsCancelledTasks() async throws {
        let store = CancellationCheckingStore()
        let adapter = ScriptedAdapter([[.event(.textDelta("Hi")), .hang]])
        let input = input()
        let handle = TurnRunner(store: store, makeAdapter: { _ in adapter }).run(input)

        var updates: [TurnUpdate] = []
        for await update in handle.updates {
            updates.append(update)
            if updates.count == 1 { handle.cancel() }
        }

        let final = try finalMessage(updates)
        #expect(final.status == .interrupted)
        #expect(store.messages == [input.userMessage, final])
    }

    @Test func userMessageIsSavedEvenIfTheTurnIsCancelledImmediately() async throws {
        let store = CancellationCheckingStore()
        let adapter = ScriptedAdapter([[.hang]])
        let input = input()
        let handle = TurnRunner(store: store, makeAdapter: { _ in adapter }).run(input)
        handle.cancel()

        let final = try finalMessage(await collect(handle))
        #expect(final.status == .interrupted)
        #expect(store.messages == [input.userMessage, final])
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待超时")
    }
}
