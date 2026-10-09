import ChatbotCore
import Foundation
import Testing

/// Fixtures/deepseek-chat-stream.sse 和 Fixtures/deepseek-models.json 是 DeepSeek 官方文档里的原文：
/// https://api-docs.deepseek.com/api/create-chat-completion （Response 的 stream 示例）
/// https://api-docs.deepseek.com/api/list-models （Response 示例）
/// 其余的流和错误体是按文档描述自己构造的，不是官方原文；构造的地方都有注明。
struct OpenAICompatibleAdapterTests {
    private let connection = Connection.deepSeek()

    private func request(
        connection: Connection? = nil,
        systemPrompt: String = "",
        messages: [Message] = [.user("Hi")]
    ) -> ModelRequest {
        ModelRequest(
            connection: connection ?? self.connection,
            apiKey: "sk-test",
            modelID: "deepseek-flash",
            systemPrompt: systemPrompt,
            messages: messages,
            webSearch: false
        )
    }

    private func collect(_ transport: StubTransport, _ request: ModelRequest? = nil) async throws -> [ModelEvent] {
        let adapter = OpenAICompatibleAdapter(transport: transport)
        var events: [ModelEvent] = []
        for try await event in adapter.stream(request ?? self.request()) { events.append(event) }
        return events
    }

    /// 构造的流：每个 chunk 只保留解码用到的字段。
    private func chunk(_ content: String?, finishReason: String? = nil) -> String {
        let contentJSON = content.map { "\"content\": \"\($0)\"" } ?? "\"content\": null"
        let finishJSON = finishReason.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\": [{\"index\": 0, \"delta\": {\(contentJSON)}, \"finish_reason\": \(finishJSON)}]}\n\n"
    }

    // MARK: 流解码

    @Test func decodesOfficialStreamExample() async throws {
        let transport = StubTransport(body: try Fixture.string("deepseek-chat-stream.sse"))
        let events = try await collect(transport)
        #expect(events == [
            .textDelta("Hello"), .textDelta("!"), .textDelta(" How"), .textDelta(" can"), .textDelta(" I"),
            .textDelta(" assist"), .textDelta(" you"), .textDelta(" today"), .textDelta("?"),
            .finished(.stop),
        ])
    }

    @Test func keepAliveCommentsAndDoneMarkerAreHandled() async throws {
        // 构造的流：排队时的 keep-alive，加上以空行结尾的 [DONE]
        let body = ": keep-alive\n\n" + chunk("Hi") + ": keep-alive\n\n" + chunk(nil, finishReason: "stop") + "data: [DONE]\n\n"
        let events = try await collect(StubTransport(body: body))
        #expect(events == [.textDelta("Hi"), .finished(.stop)])
    }

    @Test func doneWithoutFinishReasonStillFinishes() async throws {
        // 构造的流
        let events = try await collect(StubTransport(body: chunk("Hi") + "data: [DONE]\n\n"))
        #expect(events == [.textDelta("Hi"), .finished(.stop)])
    }

    @Test(arguments: [
        ("length", FinishReason.length),
        ("tool_calls", FinishReason.toolUse),
    ])
    func finishReasonsThatEndNormally(raw: String, expected: FinishReason) async throws {
        let events = try await collect(StubTransport(body: chunk("Hi") + chunk(nil, finishReason: raw)))
        #expect(events == [.textDelta("Hi"), .finished(expected)])
    }

    @Test(arguments: [
        ("insufficient_system_resource", ChatError.overloaded),
        ("aborted", ChatError.providerError("DeepSeek 中途中止了生成（finish_reason: aborted）")),
        ("content_filter", ChatError.providerError("回答被内容过滤拦截了（finish_reason: content_filter）")),
    ])
    func finishReasonsThatAreErrors(raw: String, expected: ChatError) async throws {
        let transport = StubTransport(body: chunk("Hi") + chunk(nil, finishReason: raw))
        let adapter = OpenAICompatibleAdapter(transport: transport)
        var events: [ModelEvent] = []
        await #expect(throws: expected) {
            for try await event in adapter.stream(request()) { events.append(event) }
        }
        #expect(events == [.textDelta("Hi")])
    }

    @Test func streamEndingWithoutFinishIsNetworkError() async throws {
        // 构造的流：连接在中途断开
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(body: chunk("Hi")))
        }
    }

    @Test func disconnectAfterFinishReasonIsANormalEnd() async throws {
        // 构造的流：finish_reason 已经到了，[DONE] 之前连接断开，回答是完整的
        let body = chunk("Hi") + chunk(nil, finishReason: "stop")
        let events = try await collect(StubTransport(.truncated(body: Array(body.utf8), error: .network)))
        #expect(events == [.textDelta("Hi"), .finished(.stop)])
    }

    @Test func disconnectBeforeFinishReasonIsNetworkError() async throws {
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(.truncated(body: Array(chunk("Hi").utf8), error: .network)))
        }
    }

    @Test func errorObjectInsideStreamIsProviderError() async throws {
        // 构造的流：OpenAI 兼容服务有时在流中途发一个 error 对象
        let body = chunk("Hi") + "data: {\"error\": {\"message\": \"boom\", \"type\": \"server_error\"}}\n\n"
        await #expect(throws: ChatError.providerError("boom")) {
            try await collect(StubTransport(body: body))
        }
    }

    @Test func unknownChunksAreIgnored() async throws {
        // 构造的流：宽松解码，看不懂的 chunk 跳过
        let body = "data: not json\n\n" + "data: {\"foo\": 1}\n\n" + chunk("Hi") + chunk(nil, finishReason: "stop")
        let events = try await collect(StubTransport(body: body))
        #expect(events == [.textDelta("Hi"), .finished(.stop)])
    }

    @Test func transportNetworkErrorIsPassedThrough() async throws {
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(.failure(.network)))
        }
    }

    // MARK: 请求

    @Test func deepSeekRequestDisablesThinkingAndSendsOnlySupportedFields() async throws {
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        let history: [Message] = [
            .user("1+1?"),
            Message(role: .assistant, content: [ContentBlock(.text("2"))]),
            .user("再加 1？"),
        ]
        _ = try await collect(transport, request(systemPrompt: "简短回答", messages: history))

        let sent = try #require(transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
        #expect(sent.headers["Content-Type"] == "application/json")

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return }
        #expect(fields["model"] == .string("deepseek-flash"))
        #expect(fields["stream"] == .bool(true))
        #expect(fields["thinking"] == .object(["type": .string("disabled")]))
        for unsupported in ["n", "seed", "parallel_tool_calls", "max_completion_tokens", "logit_bias"] {
            #expect(fields[unsupported] == nil, "不应该发送 \(unsupported)")
        }
        #expect(fields["messages"] == .array([
            .object(["role": .string("system"), "content": .string("简短回答")]),
            .object(["role": .string("user"), "content": .string("1+1?")]),
            .object(["role": .string("assistant"), "content": .string("2")]),
            .object(["role": .string("user"), "content": .string("再加 1？")]),
        ]))
    }

    @Test func emptySystemPromptAndEmptyAssistantMessagesAreOmitted() async throws {
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        let history: [Message] = [
            .user("a"),
            Message(role: .assistant, status: .failed(.network), content: []),
            .user("b"),
        ]
        _ = try await collect(transport, request(messages: history))

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return }
        #expect(fields["messages"] == .array([
            .object(["role": .string("user"), "content": .string("a")]),
            .object(["role": .string("user"), "content": .string("b")]),
        ]))
    }

    @Test func otherOpenAICompatibleServicesDoNotGetThinkingField() async throws {
        let ollama = Connection(name: "Ollama", provider: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!)
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(transport, request(connection: ollama))

        let sent = try #require(transport.requests.first)
        #expect(sent.url.absoluteString == "http://localhost:11434/v1/chat/completions")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return }
        #expect(fields["thinking"] == nil)
        #expect(fields["reasoning"] == nil)
        #expect(fields["enable_thinking"] == nil)
    }

    // MARK: 按平台关闭思考（ADR-0002）

    private func sentFields(_ request: ModelRequest) async throws -> [String: JSONValue] {
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(transport, request)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return [:] }
        return fields
    }

    private func connection(_ baseURL: String, models: [ModelInfo] = []) -> Connection {
        Connection(name: "平台", provider: .openAICompatible, baseURL: URL(string: baseURL)!, models: models)
    }

    @Test func openRouterRequestDisablesReasoning() async throws {
        var request = request(connection: connection("https://openrouter.ai/api/v1"))
        request.modelID = "deepseek/deepseek-v4.1-flash"
        let fields = try await sentFields(request)
        #expect(fields["reasoning"] == .object(["enabled": .bool(false)]))
        #expect(fields["thinking"] == nil)
        #expect(fields["enable_thinking"] == nil)
    }

    @Test func openRouterModelsThatMustReasonGetTheirLowestEffort() async throws {
        // Fixtures/openrouter-models.json：2026-10-09 无鉴权请求 https://openrouter.ai/api/v1/models 的结果，
        // 只留了三个模型和几个字段
        let models = try await OpenAICompatibleAdapter(transport: StubTransport(body: try Fixture.string("openrouter-models.json")))
            .listModels(connection("https://openrouter.ai/api/v1"), apiKey: "sk-test")
        let openRouter = connection("https://openrouter.ai/api/v1", models: models)

        var mandatory = request(connection: openRouter)
        mandatory.modelID = "google/gemini-3.8-flash"
        #expect(try await sentFields(mandatory)["reasoning"] == .object(["effort": .string("low")]))

        var optional = request(connection: openRouter)
        optional.modelID = "deepseek/deepseek-v4.1-flash"
        #expect(try await sentFields(optional)["reasoning"] == .object(["enabled": .bool(false)]))
    }

    @Test func openRouterConnectionsSavedBeforeReasoningInfoOnlyDisableDeepSeek() async throws {
        // #53 之前保存的 Connection：缓存的 Model 没有 providerData
        let old = connection("https://openrouter.ai/api/v1", models: [
            ModelInfo(id: "deepseek/deepseek-v4.1-flash", capabilities: .conservative),
            ModelInfo(id: "google/gemini-3.8-flash", capabilities: .conservative),
        ])
        var deepSeek = request(connection: old)
        deepSeek.modelID = "deepseek/deepseek-v4.1-flash"
        #expect(try await sentFields(deepSeek)["reasoning"] == .object(["enabled": .bool(false)]))

        var gemini = request(connection: old)
        gemini.modelID = "google/gemini-3.8-flash"
        #expect(try await sentFields(gemini)["reasoning"] == nil)
    }

    @Test func lowestEffortDoesNotDependOnListOrder() async throws {
        // 构造的 reasoning 对象：档位故意按从低到高排列
        let model = ModelInfo(
            id: "vendor/must-reason", capabilities: .conservative,
            providerData: .object(["reasoning": .object([
                "mandatory": .bool(true),
                "supported_efforts": .array([.string("medium"), .string("high"), .string("max")]),
            ])])
        )
        var request = request(connection: connection("https://openrouter.ai/api/v1", models: [model]))
        request.modelID = "vendor/must-reason"
        #expect(try await sentFields(request)["reasoning"] == .object(["effort": .string("medium")]))
    }

    @Test(arguments: [
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "https://llm-abc123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
    ])
    func bailianRequestDisablesThinking(baseURL: String) async throws {
        var request = request(connection: connection(baseURL))
        request.modelID = "deepseek-v4-flash"
        let fields = try await sentFields(request)
        #expect(fields["enable_thinking"] == .bool(false))
        #expect(fields["thinking"] == nil)
        #expect(fields["reasoning"] == nil)
    }

    @Test(arguments: ["deepseek-r1", "deepseek-r1-0528", "qwq-plus", "qvq-max", "qwen3-235b-a22b-thinking-2507"])
    func bailianThinkingOnlyModelsGetNoThinkingField(modelID: String) async throws {
        var request = request(connection: connection("https://dashscope.aliyuncs.com/compatible-mode/v1"))
        request.modelID = modelID
        #expect(try await sentFields(request)["enable_thinking"] == nil)
    }

    @Test func platformIsRecognizedByHost() {
        #expect(Platform(host: "api.deepseek.com") == .deepSeek)
        #expect(Platform(host: "openrouter.ai") == .openRouter(.global))
        #expect(Platform(host: "us.openrouter.ai") == .openRouter(.us))
        #expect(Platform(host: "eu.openrouter.ai") == .openRouter(.eu))
        #expect(Platform(host: "dashscope.aliyuncs.com") == .bailian(.beijing))
        #expect(Platform(host: "dashscope-intl.aliyuncs.com") == .bailian(.singapore))
        #expect(Platform(host: "dashscope-us.aliyuncs.com") == .bailian(.global))
        #expect(Platform(host: "cn-hongkong.dashscope.aliyuncs.com") == .bailian(.global))
        #expect(Platform(host: "trial.cn-beijing.maas.aliyuncs.com") == .bailian(.beijing))
        #expect(Platform(host: "LLM-X.AP-SOUTHEAST-1.MAAS.ALIYUNCS.COM") == .bailian(.singapore))
        #expect(Platform(host: "oss-cn-beijing.aliyuncs.com") == nil)
        #expect(Platform(host: "notopenrouter.ai") == nil)
        #expect(Platform(host: "localhost") == nil)
        #expect(Platform(host: nil) == nil)
    }

    @Test func serverWebSearchSupportFollowsPlatformAndEndpoint() {
        #expect(Platform.deepSeek.supportsServerWebSearch == false)
        #expect(Platform.openRouter(.global).supportsServerWebSearch)
        #expect(Platform.openRouter(.us).supportsServerWebSearch)
        #expect(Platform.openRouter(.eu).supportsServerWebSearch == false)
        #expect(Platform.bailian(.beijing).supportsServerWebSearch)
    }

    @Test func euEndpointStillDisablesReasoning() async throws {
        var request = request(connection: connection("https://eu.openrouter.ai/api/v1"))
        request.modelID = "deepseek/deepseek-v4.1-flash"
        #expect(try await sentFields(request)["reasoning"] == .object(["enabled": .bool(false)]))
    }

    // MARK: 附件

    private func sentMessages(_ request: ModelRequest) async throws -> JSONValue? {
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(transport, request)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.body))
        guard case .object(let fields) = body else { return nil }
        return fields["messages"]
    }

    private func requestWithAttachments(imageInput: Bool) -> ModelRequest {
        let image = Attachment(kind: .image, originalName: "截图.png", content: .image(Data([1, 2, 3]), mediaType: "image/png"))
        let code = Attachment(kind: .text, originalName: "main.swift", content: .text("print(1)"))
        var connection = Connection.deepSeek()
        connection.models = [ModelInfo(
            id: "deepseek-flash",
            capabilities: ModelCapabilities(imageInput: imageInput, toolCalling: true, webSearch: false)
        )]
        var request = request(connection: connection, messages: [.user("看看这个", attachments: [image, code])])
        request.attachments = [image.id: image, code.id: code]
        return request
    }

    @Test func imagesAreSentAsDataURLsWhenTheModelAcceptsThem() async throws {
        let messages = try await sentMessages(requestWithAttachments(imageInput: true))
        #expect(messages == .array([
            .object(["role": .string("user"), "content": .array([
                .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/png;base64,AQID")])]),
                .object(["type": .string("text"), "text": .string("附件 main.swift：\nprint(1)")]),
                .object(["type": .string("text"), "text": .string("看看这个")]),
            ])]),
        ]))
    }

    @Test func imagesAreReplacedByANoteWhenTheModelCannotTakeThem() async throws {
        // SPEC §4：当前 Model 不支持图片时忽略图片（界面另有提示）；留一段占位文字，模型知道这里本来有图
        let messages = try await sentMessages(requestWithAttachments(imageInput: false))
        #expect(messages == .array([
            .object(["role": .string("user"), "content": .string("[图片已省略：当前模型不支持图片]\n\n附件 main.swift：\nprint(1)\n\n看看这个")]),
        ]))
    }

    @Test func modelsWithUnknownCapabilitiesGetNoImages() async throws {
        var request = requestWithAttachments(imageInput: true)
        request.connection.models = []
        let messages = try await sentMessages(request)
        #expect(messages == .array([
            .object(["role": .string("user"), "content": .string("[图片已省略：当前模型不支持图片]\n\n附件 main.swift：\nprint(1)\n\n看看这个")]),
        ]))
    }

    @Test func imageOnlyMessagesKeepUserAndAssistantAlternating() async throws {
        // 只有图片的用户 Message 不能整条消失，否则会出现连续两条 assistant
        let image = Attachment(kind: .image, originalName: "截图.png", content: .image(Data([1]), mediaType: "image/png"))
        var request = request(messages: [
            .user("", attachments: [image]),
            Message(role: .assistant, content: [ContentBlock(.text("我看不到图片"))]),
            .user("那算了"),
        ])
        request.attachments = [image.id: image]
        let messages = try await sentMessages(request)
        #expect(messages == .array([
            .object(["role": .string("user"), "content": .string("[图片已省略：当前模型不支持图片]")]),
            .object(["role": .string("assistant"), "content": .string("我看不到图片")]),
            .object(["role": .string("user"), "content": .string("那算了")]),
        ]))
    }

    // MARK: HTTP 错误映射（ARCHITECTURE §3.4，SPEC §7）

    /// 错误体是构造的：DeepSeek 文档只有状态码表，没有错误体示例，这里按 OpenAI 的 `{"error": {...}}` 形状写。
    private static func errorBody(_ message: String, code: String? = nil) -> String {
        let codeJSON = code.map { ", \"code\": \"\($0)\"" } ?? ""
        return "{\"error\": {\"message\": \"\(message)\", \"type\": \"invalid_request_error\"\(codeJSON)}}"
    }

    @Test(arguments: [
        (401, [:], errorBody("Authentication Fails"), ChatError.authentication),
        (402, [:], errorBody("Insufficient Balance"), ChatError.rateLimited(retryAfter: nil)),
        (429, ["Retry-After": "7"], errorBody("Rate Limit Reached"), ChatError.rateLimited(retryAfter: 7)),
        (429, [:], errorBody("Rate Limit Reached"), ChatError.rateLimited(retryAfter: nil)),
        (400, [:], errorBody("Invalid Format"), ChatError.invalidRequest("Invalid Format")),
        (422, [:], errorBody("Invalid Parameters"), ChatError.invalidRequest("Invalid Parameters")),
        (400, [:], errorBody("This model's maximum context length is 1048576 tokens."), ChatError.contextTooLong),
        (400, [:], errorBody("too long", code: "context_length_exceeded"), ChatError.contextTooLong),
        (500, [:], errorBody("Server Error"), ChatError.overloaded),
        (503, [:], errorBody("Server Overloaded"), ChatError.overloaded),
        (418, [:], errorBody("teapot"), ChatError.providerError("teapot")),
        (418, [:], "plain text body", ChatError.providerError("plain text body")),
        (418, [:], "", ChatError.providerError("HTTP 418")),
    ] as [(Int, [String: String], String, ChatError)])
    func httpErrorsAreMapped(statusCode: Int, headers: [String: String], body: String, expected: ChatError) async throws {
        let transport = StubTransport(statusCode: statusCode, headers: headers, body: body)
        await #expect(throws: expected) {
            try await collect(transport)
        }
        let adapter = OpenAICompatibleAdapter(transport: transport)
        await #expect(throws: expected) {
            try await adapter.listModels(connection, apiKey: "sk-test")
        }
    }

    @Test func hugeErrorBodyIsTruncated() async throws {
        let transport = StubTransport(statusCode: 418, body: String(repeating: "x", count: 1_000_000))
        do {
            _ = try await collect(transport)
            Issue.record("应该抛错")
        } catch ChatError.providerError(let message) {
            #expect(message.count <= 2_000)
        }
    }

    // MARK: Model 列表

    @Test func listModelsReadsCapabilitiesFromOfficialExample() async throws {
        let transport = StubTransport(body: try Fixture.string("deepseek-models.json"))
        let models = try await OpenAICompatibleAdapter(transport: transport).listModels(connection, apiKey: "sk-test")

        #expect(models == [
            ModelInfo(
                id: "deepseek-flash", displayName: "DeepSeek-V4.1-Flash", contextWindow: 1_048_576,
                capabilities: ModelCapabilities(imageInput: true, toolCalling: true, webSearch: false)
            ),
            ModelInfo(
                id: "deepseek-v4-pro", displayName: "DeepSeek-V4-Pro", contextWindow: 1_048_576,
                capabilities: ModelCapabilities(imageInput: false, toolCalling: true, webSearch: false)
            ),
        ])
        let sent = try #require(transport.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.url.absoluteString == "https://api.deepseek.com/models")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
    }

    @Test func modelsWithoutModalitiesGetConservativeCapabilities() async throws {
        // 构造的响应：标准 OpenAI `/models` 没有能力字段
        let body = "{\"object\": \"list\", \"data\": [{\"id\": \"llama3\", \"object\": \"model\", \"owned_by\": \"library\"}]}"
        let models = try await OpenAICompatibleAdapter(transport: StubTransport(body: body)).listModels(connection, apiKey: "")
        #expect(models == [ModelInfo(id: "llama3", capabilities: .conservative)])
    }
}
