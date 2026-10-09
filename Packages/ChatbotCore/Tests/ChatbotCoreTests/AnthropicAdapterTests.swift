import ChatbotCore
// Swift Testing 自己也有一个 Attachment 类型。不加这一行时，Attachment 用在类型位置（例如参数类型）上会有歧义，
// 而编译器报出来的是一串看不出原因的类型推断错误（"type 'Any' has no member ..."）。
import struct ChatbotCore.Attachment
import Foundation
import Testing

/// Fixture 来源（https://platform.claude.com/docs/en/build-with-claude/streaming ）：
/// - anthropic-basic-stream.sse、anthropic-thinking-stream.sse：官方文档原文。
/// - anthropic-web-search-stream.sse：改自官方的 web search 流示例。原文有两处省略号，不是合法 JSON，所以做了两处改动：
///   1. 搜索结果数组末尾的 `,...` 去掉；
///   2. 省略了 index 3 其余内容和 index 4–17 的那一行 `...`，换成一个 `citations_delta`（构造的引用）加 index 3 的结束。
/// - anthropic-models.json：https://platform.claude.com/docs/en/api/models/list 的 Response 示例原文。
/// 其余的流和错误体是按文档描述构造的，不是官方原文；构造的地方都有注明。
struct AnthropicAdapterTests {
    /// 一个 Anthropic Model。capabilities 用 `/v1/models` 的形状。
    private func model(
        _ id: String = "claude-opus-5",
        thinkingCanBeDisabled: Bool = true,
        betweenTools: Bool? = nil,
        lowEffort: Bool = true,
        imageInput: Bool = true,
        maxOutputTokens: Int? = 128_000
    ) -> ModelInfo {
        var thinkingTypes: [String: JSONValue] = [
            "adaptive": .object(["supported": .bool(true)]),
            "disabled": .object(["supported": .bool(thinkingCanBeDisabled)]),
        ]
        // between_tools 这一项在 /v1/models 里还没有官方示例，nil 表示接口不报告这一项
        if let betweenTools { thinkingTypes["between_tools"] = .object(["supported": .bool(betweenTools)]) }
        let providerData: JSONValue = .object([
            "effort": .object(["supported": .bool(lowEffort), "low": .object(["supported": .bool(lowEffort)])]),
            "thinking": .object(["supported": .bool(true), "types": .object(thinkingTypes)]),
        ])
        return ModelInfo(
            id: id,
            maxOutputTokens: maxOutputTokens,
            capabilities: ModelCapabilities(imageInput: imageInput, toolCalling: true, webSearch: true),
            providerData: providerData
        )
    }

    private func request(
        models: [ModelInfo]? = nil,
        modelID: String = "claude-opus-5",
        systemPrompt: String = "",
        messages: [Message] = [.user("Hi")],
        webSearch: Bool = false,
        attachments: [UUID: Attachment] = [:]
    ) -> ModelRequest {
        var connection = Connection.anthropic()
        connection.models = models ?? [model()]
        return ModelRequest(
            connection: connection, apiKey: "sk-ant-test", modelID: modelID, systemPrompt: systemPrompt,
            messages: messages, webSearch: webSearch, attachments: attachments
        )
    }

    private func collect(_ transport: StubTransport, _ request: ModelRequest? = nil) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in AnthropicAdapter(transport: transport).stream(request ?? self.request()) {
            events.append(event)
        }
        return events
    }

    private func sse(_ events: [String]) -> String {
        events.joined()
    }

    private func event(_ name: String, _ json: String) -> String {
        "event: \(name)\ndata: \(json)\n\n"
    }

    private func messageDelta(_ stopReason: String) -> String {
        event("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":1}}")
    }

    private var textBlock: String {
        event("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
            + event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}")
            + event("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
    }

    private var messageStop: String {
        event("message_stop", "{\"type\":\"message_stop\"}")
    }

    private func jsonObject(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: 流解码

    @Test func decodesOfficialBasicStream() async throws {
        let events = try await collect(StubTransport(body: try Fixture.string("anthropic-basic-stream.sse")))
        #expect(events == [
            .textDelta("Hello"), .textDelta("!"),
            .providerData(blockIndex: 0, opaque: try jsonObject(#"{"type":"text","text":"Hello!"}"#)),
            .finished(.stop),
        ])
    }

    @Test func thinkingIsNotShownButKeptVerbatim() async throws {
        let events = try await collect(StubTransport(body: try Fixture.string("anthropic-thinking-stream.sse")))
        let thinking = "I need to find the GCD of 1071 and 462 using the Euclidean algorithm.\n\n1071 = 2 × 462 + 147"
            + "\n462 = 3 × 147 + 21\n147 = 7 × 21 + 0\nThe remainder is 0, so GCD(1071, 462) = 21."
        #expect(events == [
            .providerData(blockIndex: 0, opaque: .object([
                "type": .string("thinking"),
                "thinking": .string(thinking),
                "signature": .string("EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."),
            ])),
            .textDelta("The greatest common divisor of 1071 and 462 is **21**."),
            .providerData(blockIndex: 1, opaque: .object([
                "type": .string("text"),
                "text": .string("The greatest common divisor of 1071 and 462 is **21**."),
            ])),
            .finished(.stop),
        ])
    }

    @Test func webSearchBlocksAreKeptVerbatimAndCitationsCarryTheirRange() async throws {
        let events = try await collect(StubTransport(body: try Fixture.string("anthropic-web-search-stream.sse")))

        let firstText = "I'll check the current weather in New York City for you."
        let secondText = "Here's the current weather information for New York City:\n\n# Weather in New York City\n\n"
        #expect(events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() == firstText + secondText)
        #expect(events.contains(.webSearchStarted(query: "weather NYC today")))

        let raw = events.compactMap { event -> (Int, JSONValue)? in
            if case .providerData(let index, let json) = event { (index, json) } else { nil }
        }
        #expect(raw.map(\.0) == [0, 1, 2, 3])
        #expect(raw[1].1 == .object([
            "type": .string("server_tool_use"),
            "id": .string("srvtoolu_014hJH82Qum7Td6UV8gDXThB"),
            "name": .string("web_search"),
            "input": .object(["query": .string("weather NYC today")]),
        ]))
        // web_search_tool_result 原样保留，包括 encrypted_content
        guard case .object(let result) = raw[2].1, case .array(let results) = result["content"],
              case .object(let first) = results.first
        else { Issue.record("搜索结果的形状不对"); return }
        #expect(first["encrypted_content"] == .string("Ev0DCioIAxgCIiQ3NmU4ZmI4OC1k..."))
        // 带引用的 text 块里保留 citations（含 encrypted_index），回传时要用
        guard case .object(let cited) = raw[3].1, case .array(let citations) = cited["citations"],
              case .object(let citation) = citations.first
        else { Issue.record("引用的形状不对"); return }
        #expect(citation["encrypted_index"] == .string("Eo8BCioIAhgBIiQyYjQ0OWJmZi1lNm.."))

        let start = firstText.utf16.count
        #expect(events.contains(.citation(
            Citation(
                title: "Weather in New York City in May 2025 (New York) - detailed Weather Forecast for a month",
                url: URL(string: "https://world-weather.info/forecast/usa/new_york/may-2025/")!
            ),
            textRange: start..<(start + secondText.utf16.count)
        )))
        #expect(events.last == .finished(.stop))
    }

    @Test(arguments: [
        ("end_turn", FinishReason.stop),
        ("stop_sequence", FinishReason.stop),
        ("max_tokens", FinishReason.length),
        ("model_context_window_exceeded", FinishReason.length),
        ("pause_turn", FinishReason.pauseTurn),
        ("tool_use", FinishReason.toolUse),
    ])
    func stopReasons(raw: String, expected: FinishReason) async throws {
        // 构造的流
        let events = try await collect(StubTransport(body: textBlock + messageDelta(raw) + messageStop))
        #expect(events.last == .finished(expected))
    }

    @Test func refusalIsAProviderError() async throws {
        // 构造的流：安全分类器拒答，HTTP 200，stop_reason 是 refusal
        await #expect(throws: ChatError.providerError("模型拒绝回答这个问题（stop_reason: refusal）")) {
            try await collect(StubTransport(body: textBlock + messageDelta("refusal") + messageStop))
        }
    }

    @Test func errorEventInsideTheStream() async throws {
        // error 事件的原文取自官方文档；前面的文字块是构造的
        let body = textBlock + "event: error\ndata: {\"type\": \"error\", \"error\": {\"type\": \"overloaded_error\", \"message\": \"Overloaded\"}}\n\n"
        let adapter = AnthropicAdapter(transport: StubTransport(body: body))
        var events: [ModelEvent] = []
        await #expect(throws: ChatError.overloaded) {
            for try await event in adapter.stream(request()) { events.append(event) }
        }
        #expect(events.first == .textDelta("Hi"))
    }

    @Test func disconnectBeforeStopReasonIsNetworkError() async throws {
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(.truncated(body: Array(textBlock.utf8), error: .network)))
        }
    }

    @Test func disconnectAfterStopReasonIsANormalEnd() async throws {
        let body = textBlock + messageDelta("end_turn")
        let events = try await collect(StubTransport(.truncated(body: Array(body.utf8), error: .network)))
        #expect(events.last == .finished(.stop))
    }

    @Test func unknownEventsAndDeltasAreIgnored() async throws {
        // 构造的流：以后可能出现新的事件类型和 delta 类型
        let body = event("brand_new_event", "{\"type\":\"brand_new_event\"}")
            + event("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
            + event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"future_delta\",\"x\":1}}")
            + event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}")
            + event("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
            + messageDelta("end_turn") + messageStop
        let events = try await collect(StubTransport(body: body))
        #expect(events.first == .textDelta("Hi"))
        #expect(events.last == .finished(.stop))
    }

    // MARK: HTTP 错误映射

    /// 错误体的形状取自官方文档（api/errors），内容是构造的。
    private static func errorBody(_ type: String, _ message: String) -> String {
        "{\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"\(message)\"},\"request_id\":\"req_1\"}"
    }

    @Test(arguments: [
        (401, [:], errorBody("authentication_error", "invalid x-api-key"), ChatError.authentication),
        (402, [:], errorBody("billing_error", "credit balance too low"), ChatError.rateLimited(retryAfter: nil)),
        (403, [:], errorBody("permission_error", "not allowed"), ChatError.providerError("not allowed")),
        (404, [:], errorBody("not_found_error", "model: claude-x"), ChatError.invalidRequest("model: claude-x")),
        (413, [:], errorBody("request_too_large", "Request exceeds the maximum allowed size"), ChatError.contextTooLong),
        (429, ["retry-after": "12"], errorBody("rate_limit_error", "slow down"), ChatError.rateLimited(retryAfter: 12)),
        (400, [:], errorBody("invalid_request_error", "prompt is too long: 1000123 tokens > 1000000 maximum"), ChatError.contextTooLong),
        (400, [:], errorBody("invalid_request_error", "messages: roles must alternate"), ChatError.invalidRequest("messages: roles must alternate")),
        (500, [:], errorBody("api_error", "internal"), ChatError.overloaded),
        (529, [:], errorBody("overloaded_error", "Overloaded"), ChatError.overloaded),
    ] as [(Int, [String: String], String, ChatError)])
    func httpErrorsAreMapped(statusCode: Int, headers: [String: String], body: String, expected: ChatError) async throws {
        let transport = StubTransport(statusCode: statusCode, headers: headers, body: body)
        await #expect(throws: expected) { try await collect(transport) }
        await #expect(throws: expected) {
            try await AnthropicAdapter(transport: transport).listModels(.anthropic(), apiKey: "sk-ant-test")
        }
    }

    // MARK: 请求

    private func sentBody(_ request: ModelRequest) async throws -> [String: JSONValue] {
        let transport = StubTransport(body: textBlock + messageDelta("end_turn") + messageStop)
        _ = try await collect(transport, request)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return [:] }
        return fields
    }

    @Test func requestShape() async throws {
        let transport = StubTransport(body: textBlock + messageDelta("end_turn") + messageStop)
        _ = try await collect(transport, request(systemPrompt: "简短回答"))
        let sent = try #require(transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
        #expect(sent.headers["anthropic-version"] == "2023-06-01")
        #expect(sent.headers["content-type"] == "application/json")
        // 整数要编码成整数（JSONValue 里存的是 Double）
        #expect(String(decoding: try #require(sent.body), as: UTF8.self).contains("\"max_tokens\":64000"))

        let fields = try await sentBody(request(systemPrompt: "简短回答"))
        #expect(fields["model"] == JSONValue.string("claude-opus-5"))
        #expect(fields["stream"] == JSONValue.bool(true))
        #expect(fields["system"] == JSONValue.string("简短回答"))
        #expect(fields["max_tokens"] == JSONValue.number(64_000))
        #expect(fields["messages"] == JSONValue.array([.object(["role": .string("user"), "content": .string("Hi")])]))
        #expect(fields["tools"] == nil)
    }

    @Test func thinkingIsDisabledWhereTheModelAllowsIt() async throws {
        // ADR-0002：能关的就关；effort 用 low，延迟最低
        let fields = try await sentBody(request())
        let disabled: JSONValue = .object(["type": .string("disabled")])
        let lowEffort: JSONValue = .object(["effort": .string("low")])
        #expect(fields["thinking"] == disabled)
        #expect(fields["output_config"] == lowEffort)
    }

    @Test func modelsThatCannotDisableThinkingOnlyGetLowEffort() async throws {
        // Opus 5.5、Sonnet 5.5、Fable：发 disabled 会 400，只能把 effort 压到 low
        let fields = try await sentBody(request(models: [model("claude-opus-5-5", thinkingCanBeDisabled: false)], modelID: "claude-opus-5-5"))
        let lowEffort: JSONValue = .object(["effort": .string("low")])
        #expect(fields["thinking"] == nil)
        #expect(fields["output_config"] == lowEffort)
    }

    /// 一轮已经完成的回答，原生块里有一个思考块。
    private var answerWithThinking: Message {
        let raw: JSONValue = .array([
            .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig")]),
            .object(["type": .string("text"), "text": .string("答案")]),
        ])
        return Message(role: .assistant, content: [ContentBlock(.opaque(provider: .anthropic, raw)), ContentBlock(.text("答案"))])
    }

    private func sent(_ request: ModelRequest) async throws -> (headers: [String: String], body: [String: JSONValue]) {
        let transport = StubTransport(body: textBlock + messageDelta("end_turn") + messageStop)
        _ = try await collect(transport, request)
        let sent = try #require(transport.requests.first)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.body)) else {
            Issue.record("body 不是对象")
            return (sent.headers, [:])
        }
        return (sent.headers, fields)
    }

    @Test(arguments: [
        ("", false),
        ("今天是 2026-10-09", false),
        ("今天是 2026-10-10", true),
    ])
    func replayedThinkingBlocksAreDroppedInsteadOfFailingWhenThePrefixChanged(systemPrompt: String, webSearch: Bool) async throws {
        // 思考块的签名绑定了 system、tools 和之前的消息。system 里的日期变了、地球按钮切换了 tools 时，
        // 关不掉思考的 Model 会一直 400；所以回传思考块时声明 drop_block，让服务端丢掉对不上的块
        let opus55 = model("claude-opus-5-5", thinkingCanBeDisabled: false)
        let (headers, fields) = try await sent(request(
            models: [opus55], modelID: "claude-opus-5-5", systemPrompt: systemPrompt,
            messages: [.user("一"), answerWithThinking, .user("二")], webSearch: webSearch
        ))
        let adaptive: JSONValue = .object([
            "type": .string("adaptive"),
            "block_binding": .object(["prefix_mismatch_behavior": .string("drop_block")]),
        ])
        #expect(fields["thinking"] == adaptive)
        #expect(headers["anthropic-beta"] == "thinking-binding-controls-2026-08-01")
        #expect((fields["tools"] != nil) == webSearch)
    }

    @Test func unknownModelsThatReplayThinkingBlocksAlsoGetDropBlock() async throws {
        // 能力未知时本来什么都不发；但回传了思考块，说明这个 Model 支持思考，用 drop_block 兜底
        let (headers, fields) = try await sent(request(
            models: [], modelID: "claude-unknown", messages: [.user("一"), answerWithThinking, .user("二")]
        ))
        let adaptive: JSONValue = .object([
            "type": .string("adaptive"),
            "block_binding": .object(["prefix_mismatch_behavior": .string("drop_block")]),
        ])
        #expect(fields["thinking"] == adaptive)
        #expect(headers["anthropic-beta"] == "thinking-binding-controls-2026-08-01")
        #expect(fields["output_config"] == nil)
    }

    @Test func noBindingControlsWhenNoThinkingBlockIsReplayed() async throws {
        let opus55 = model("claude-opus-5-5", thinkingCanBeDisabled: false)
        let (headers, fields) = try await sent(request(models: [opus55], modelID: "claude-opus-5-5"))
        #expect(fields["thinking"] == nil)
        #expect(headers["anthropic-beta"] == nil)
    }

    @Test func disabledThinkingNeverCarriesBindingControls() async throws {
        // block_binding 只能和 adaptive 一起发，和 disabled 一起发会 400
        let (headers, fields) = try await sent(request(messages: [.user("一"), answerWithThinking, .user("二")]))
        let disabled: JSONValue = .object(["type": .string("disabled")])
        #expect(fields["thinking"] == disabled)
        #expect(headers["anthropic-beta"] == nil)
    }

    @Test func sonnet55TurnsThinkingOffWithBetweenToolsAndDoesNotReplayThinkingBlocks() async throws {
        // Sonnet 5.5：disabled 会 400，用 between_tools 关闭；between_tools 不接受 block_binding，
        // 它在工具调用之间写的进度思考块就不回传，history 前缀因此始终一致
        let sonnet55 = model("claude-sonnet-5-5", thinkingCanBeDisabled: false, betweenTools: true)
        let (headers, fields) = try await sent(request(
            models: [sonnet55], modelID: "claude-sonnet-5-5",
            messages: [.user("一"), answerWithThinking, .user("二")]
        ))
        let betweenTools: JSONValue = .object(["type": .string("between_tools")])
        let lowEffort: JSONValue = .object(["effort": .string("low")])
        #expect(fields["thinking"] == betweenTools)
        #expect(fields["output_config"] == lowEffort)
        #expect(headers["anthropic-beta"] == nil)
        let expected: JSONValue = .array([
            turn("user", .string("一")),
            turn("assistant", .array([.object(["type": .string("text"), "text": .string("答案")])])),
            turn("user", .string("二")),
        ])
        #expect(fields["messages"] == expected)
    }

    @Test func pausedAnswersKeepTheirThinkingBlocksEvenWithBetweenTools() async throws {
        // 同一个 Turn 里续接时 system 和 tools 都没变，进行中的回答要原样发回
        let sonnet55 = model("claude-sonnet-5-5", thinkingCanBeDisabled: false, betweenTools: true)
        let raw: JSONValue = .array([.object(["type": .string("thinking"), "thinking": .string("搜一下"), "signature": .string("s")])])
        let paused = Message(role: .assistant, status: .streaming, content: [ContentBlock(.opaque(provider: .anthropic, raw))])
        let (_, fields) = try await sent(request(models: [sonnet55], modelID: "claude-sonnet-5-5", messages: [.user("一"), paused]))
        let expected: JSONValue = .array([turn("user", .string("一")), turn("assistant", raw)])
        #expect(fields["messages"] == expected)
    }

    @Test func unknownModelsGetNeitherThinkingNorEffort() async throws {
        // 能力未知时什么都不发，避免 400
        let fields = try await sentBody(request(models: [], modelID: "claude-unknown"))
        #expect(fields["thinking"] == nil)
        #expect(fields["output_config"] == nil)
        let fallback: JSONValue = .number(16_000)
        #expect(fields["max_tokens"] == fallback)
    }

    @Test func maxTokensNeverExceedsTheModelsLimit() async throws {
        let fields = try await sentBody(request(models: [model(maxOutputTokens: 8_192)]))
        let limit: JSONValue = .number(8_192)
        #expect(fields["max_tokens"] == limit)
    }

    @Test func webSearchToolIsAddedWhenRequested() async throws {
        let fields = try await sentBody(request(webSearch: true))
        let tool: JSONValue = .object([
            "type": .string("web_search_20250305"),
            "name": .string("web_search"),
            "max_uses": .number(3),
        ])
        let expectedTools: JSONValue = .array([tool])
        #expect(fields["tools"] == expectedTools)
    }

    private func turn(_ role: String, _ content: JSONValue) -> JSONValue {
        .object(["role": .string(role), "content": content])
    }

    @Test func completeAnswersAreSentBackVerbatimAndInterruptedOnesAsText() async throws {
        let raw: JSONValue = .array([
            .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig")]),
            .object(["type": .string("text"), "text": .string("答案")]),
        ])
        let complete = Message(role: .assistant, content: [ContentBlock(.opaque(provider: .anthropic, raw)), ContentBlock(.text("答案"))])
        let interrupted = Message(
            role: .assistant, status: .interrupted,
            content: [ContentBlock(.opaque(provider: .anthropic, raw)), ContentBlock(.text("答到一半"))]
        )
        let fields = try await sentBody(request(messages: [.user("一"), complete, .user("二"), interrupted, .user("三")]))
        let expected: [JSONValue] = [
            turn("user", .string("一")),
            turn("assistant", raw),
            turn("user", .string("二")),
            turn("assistant", .string("答到一半")),
            turn("user", .string("三")),
        ]
        let expectedMessages: JSONValue = .array(expected)
        #expect(fields["messages"] == expectedMessages)
    }

    @Test func pausedAnswerIsSentBackVerbatimToContinue() async throws {
        // pause_turn：TurnRunner 把还在进行中的回答原样发回去
        let raw: JSONValue = .array([.object(["type": .string("server_tool_use"), "id": .string("srvtoolu_1"), "name": .string("web_search"), "input": .object([:])])])
        let paused = Message(role: .assistant, status: .streaming, content: [ContentBlock(.opaque(provider: .anthropic, raw))])
        let fields = try await sentBody(request(messages: [.user("搜一下"), paused]))
        let expected: [JSONValue] = [turn("user", .string("搜一下")), turn("assistant", raw)]
        let expectedMessages: JSONValue = .array(expected)
        #expect(fields["messages"] == expectedMessages)
    }

    @Test func imagesAndTextAttachments() async throws {
        let image = Attachment(kind: .image, originalName: "截图.png", content: .image(Data([1, 2, 3]), mediaType: "image/png"))
        let code = Attachment(kind: .text, originalName: "main.swift", content: .text("print(1)"))
        let message = Message.user("看看", attachments: [image, code])

        let imageBlock: JSONValue = .object([
            "type": .string("image"),
            "source": .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string("AQID")]),
        ])
        let codeBlock: JSONValue = .object(["type": .string("text"), "text": .string("附件 main.swift：\nprint(1)")])
        let textBlock: JSONValue = .object(["type": .string("text"), "text": .string("看看")])
        let expectedWithImages: JSONValue = .array([.object([
            "role": .string("user"), "content": .array([imageBlock, codeBlock, textBlock]),
        ])])
        let withImages = try await sentBody(request(messages: [message], attachments: [image.id: image, code.id: code]))
        #expect(withImages["messages"] == expectedWithImages)

        let expectedWithoutImages: JSONValue = .array([.object([
            "role": .string("user"),
            "content": .string("[图片已省略：当前模型不支持图片]\n\n附件 main.swift：\nprint(1)\n\n看看"),
        ])])
        let withoutImages = try await sentBody(request(
            models: [model(imageInput: false)], messages: [message], attachments: [image.id: image, code.id: code]
        ))
        #expect(withoutImages["messages"] == expectedWithoutImages)
    }

    // MARK: Model 列表

    @Test func listModelsReadsCapabilitiesFromTheOfficialExample() async throws {
        // 官方示例里 has_more 是 true，last_id 是占位的 "last_id"；再请求一次拿到同样的数据时要停下，不能死循环
        let transport = StubTransport(body: try Fixture.string("anthropic-models.json"))
        let models = try await AnthropicAdapter(transport: transport).listModels(.anthropic(), apiKey: "sk-ant-test")

        #expect(models.map(\.id) == ["claude-opus-5"])
        let opus = try #require(models.first)
        #expect(opus.displayName == "Claude Opus 5")
        // 示例里的 0 是占位值，当作未知
        #expect(opus.contextWindow == nil)
        #expect(opus.maxOutputTokens == nil)
        #expect(opus.capabilities == ModelCapabilities(imageInput: true, toolCalling: true, webSearch: true))

        let first = try #require(transport.requests.first)
        #expect(first.method == "GET")
        #expect(first.url.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(first.headers["x-api-key"] == "sk-ant-test")
        #expect(transport.requests.count <= 2)
    }

    @Test func listModelsFollowsPagination() async throws {
        // 构造的两页数据
        func page(_ ids: [String], hasMore: Bool) -> StubTransport.Reply {
            let data = ids.map {
                "{\"id\":\"\($0)\",\"display_name\":\"\($0)\",\"max_input_tokens\":200000,\"max_tokens\":64000,\"type\":\"model\",\"capabilities\":{\"image_input\":{\"supported\":false},\"server_tools\":{\"supported\":false,\"web_search\":{\"supported\":false}}}}"
            }.joined(separator: ",")
            let body = "{\"data\":[\(data)],\"has_more\":\(hasMore),\"first_id\":\"\(ids[0])\",\"last_id\":\"\(ids.last!)\"}"
            return .response(statusCode: 200, headers: [:], body: Array(body.utf8))
        }
        let transport = StubTransport(sequence: [page(["a", "b"], hasMore: true), page(["c"], hasMore: false)])
        let models = try await AnthropicAdapter(transport: transport).listModels(.anthropic(), apiKey: "k")

        #expect(models.map(\.id) == ["a", "b", "c"])
        #expect(models.first?.contextWindow == 200_000)
        #expect(models.first?.maxOutputTokens == 64_000)
        #expect(models.first?.capabilities == ModelCapabilities(imageInput: false, toolCalling: true, webSearch: false))
        #expect(transport.requests.last?.url.absoluteString == "https://api.anthropic.com/v1/models?limit=1000&after_id=b")
    }
}
