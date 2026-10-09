import ChatbotCore
// Swift Testing 自己也有一个 Attachment 类型。不加这一行时，Attachment 用在类型位置（例如参数类型）上会有歧义，
// 而编译器报出来的是一串看不出原因的类型推断错误（"type 'Any' has no member ..."）。
import struct ChatbotCore.Attachment
import Foundation
import Testing

/// Fixture 来源：
/// - gemini-grounding-response.json：https://ai.google.dev/gemini-api/docs/generate-content/google-search 「Understanding the grounding response」
///   一节的示例原文。注意这个示例本身不自洽：segment.text 被截断成 "..."，第二个 segment 的 endIndex（210）超出了正文长度，
///   所以只用它测结构解析和「数据不对时不崩溃」，精确的偏移用构造的数据测。
/// - 官方文档没有 streamGenerateContent 的 SSE 响应示例，其余的流都是按 GenerateContentResponse 的结构构造的，不是官方原文。
struct GeminiAdapterTests {
    private func model(_ id: String, imageInput: Bool = true) -> ModelInfo {
        ModelInfo(id: id, capabilities: ModelCapabilities(imageInput: imageInput, toolCalling: true, webSearch: true))
    }

    private func request(
        modelID: String = "gemini-2.5-flash",
        imageInput: Bool = true,
        systemPrompt: String = "",
        messages: [Message] = [.user("Hi")],
        webSearch: Bool = false,
        attachments: [UUID: Attachment] = [:]
    ) -> ModelRequest {
        var connection = Connection.gemini()
        connection.models = [model(modelID, imageInput: imageInput)]
        return ModelRequest(
            connection: connection, apiKey: "AIza-test", modelID: modelID, systemPrompt: systemPrompt,
            messages: messages, webSearch: webSearch, attachments: attachments
        )
    }

    private func collect(_ transport: StubTransport, _ request: ModelRequest? = nil) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in GeminiAdapter(transport: transport).stream(request ?? self.request()) {
            events.append(event)
        }
        return events
    }

    /// 构造的 SSE chunk：一个 GenerateContentResponse。
    private func chunk(parts: [String] = [], finishReason: String? = nil, grounding: String? = nil) -> String {
        var candidate: [String] = []
        if !parts.isEmpty { candidate.append("\"content\":{\"role\":\"model\",\"parts\":[\(parts.joined(separator: ","))]}") }
        if let finishReason { candidate.append("\"finishReason\":\"\(finishReason)\"") }
        if let grounding { candidate.append("\"groundingMetadata\":\(grounding)") }
        return "data: {\"candidates\":[{\(candidate.joined(separator: ","))}]}\n\n"
    }

    private func text(_ value: String) -> String {
        "{\"text\":\(jsonString(value))}"
    }

    private func jsonString(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: 流解码

    @Test func textChunksAreShownAndEveryPartIsKeptVerbatim() async throws {
        let body = chunk(parts: [text("Hello")]) + chunk(parts: [text(", world")], finishReason: "STOP")
        let events = try await collect(StubTransport(body: body))
        #expect(events == [
            .textDelta("Hello"),
            .providerData(blockIndex: 0, opaque: try json(#"{"text":"Hello"}"#)),
            .textDelta(", world"),
            .providerData(blockIndex: 1, opaque: try json(#"{"text":", world"}"#)),
            .finished(.stop),
        ])
    }

    @Test func signaturesOnEmptyPartsAndThoughtPartsAreKeptButNotShown() async throws {
        // thoughtSignature 可以落在空文本的 Part 上；thought: true 的 Part 不展示
        let body = chunk(parts: [#"{"text":"想一想","thought":true}"#])
            + chunk(parts: [text("答案")])
            + chunk(parts: [#"{"text":"","thoughtSignature":"c2lnbmF0dXJl"}"#], finishReason: "STOP")
        let events = try await collect(StubTransport(body: body))
        #expect(events == [
            .providerData(blockIndex: 0, opaque: try json(#"{"text":"想一想","thought":true}"#)),
            .textDelta("答案"),
            .providerData(blockIndex: 1, opaque: try json(#"{"text":"答案"}"#)),
            .providerData(blockIndex: 2, opaque: try json(#"{"text":"","thoughtSignature":"c2lnbmF0dXJl"}"#)),
            .finished(.stop),
        ])
    }

    @Test(arguments: [("STOP", FinishReason.stop), ("MAX_TOKENS", FinishReason.length)])
    func finishReasonsThatEndNormally(raw: String, expected: FinishReason) async throws {
        let events = try await collect(StubTransport(body: chunk(parts: [text("Hi")], finishReason: raw)))
        #expect(events.last == .finished(expected))
    }

    @Test(arguments: ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"])
    func blockedAnswersAreProviderErrors(raw: String) async throws {
        await #expect(throws: ChatError.providerError("回答被 Gemini 的安全过滤拦截了（finishReason: \(raw)）")) {
            try await collect(StubTransport(body: chunk(parts: [text("Hi")], finishReason: raw)))
        }
    }

    @Test func blockedPromptIsAProviderError() async throws {
        let body = "data: {\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}\n\n"
        await #expect(throws: ChatError.providerError("问题被 Gemini 的安全过滤拦截了（blockReason: SAFETY）")) {
            try await collect(StubTransport(body: body))
        }
    }

    @Test func errorObjectInsideTheStream() async throws {
        // 文档没写流中途出错的格式，按 Google API 通用的错误体宽松解码（需要真机核实）
        let body = chunk(parts: [text("Hi")])
            + "data: {\"error\":{\"code\":503,\"message\":\"The model is overloaded.\",\"status\":\"UNAVAILABLE\"}}\n\n"
        let adapter = GeminiAdapter(transport: StubTransport(body: body))
        var events: [ModelEvent] = []
        await #expect(throws: ChatError.overloaded) {
            for try await event in adapter.stream(request()) { events.append(event) }
        }
        #expect(events.first == .textDelta("Hi"))
    }

    @Test func endingWithoutFinishReasonIsNetworkError() async throws {
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(body: chunk(parts: [text("Hi")])))
        }
    }

    @Test func disconnectAfterFinishReasonIsANormalEnd() async throws {
        let body = chunk(parts: [text("Hi")], finishReason: "STOP")
        let events = try await collect(StubTransport(.truncated(body: Array(body.utf8), error: .network)))
        #expect(events.last == .finished(.stop))
    }

    // MARK: Google Search 和 Citation

    @Test func officialGroundingExampleIsParsedWithoutTrustingItsBrokenOffsets() async throws {
        // 官方示例原文作为一个 chunk；后面补一个构造的结束 chunk
        let official = try Fixture.string("gemini-grounding-response.json")
        let data = String(decoding: try JSONEncoder().encode(try json(official)), as: UTF8.self)
        let body = "data: \(data)\n\n" + chunk(finishReason: "STOP")
        let events = try await collect(StubTransport(body: body))

        #expect(events.first == .textDelta("Spain won Euro 2024, defeating England 2-1 in the final. This victory marks Spain's record fourth European Championship title."))
        #expect(events.contains(.webSearchStarted(query: "UEFA Euro 2024 winner")))
        #expect(events.contains(.webSearchStarted(query: "who won euro 2024")))
        let citations = events.compactMap { event -> (Citation, Range<Int>?)? in
            if case .citation(let citation, let range) = event { (citation, range) } else { nil }
        }
        #expect(citations.map(\.0.title) == ["aljazeera.com", "aljazeera.com", "uefa.com"])
        // 第一个 segment 的偏移在正文范围内，按字节换算；第二个超出正文长度，不给范围
        #expect(citations[0].1 == 0..<85)
        #expect(citations[1].1 == nil)
        // 搜索建议的 HTML 存进不透明数据，供 App 渲染
        let grounding = events.compactMap { event -> JSONValue? in
            if case .providerData(_, let json) = event, json["groundingMetadata"] != nil { json } else { nil }
        }
        #expect(grounding.first?["groundingMetadata"]?["searchEntryPoint"]?["renderedContent"] == .string("<!-- HTML and CSS for the search widget -->"))
        #expect(events.last == .finished(.stop))
    }

    @Test func citationsAreLocatedByUTF8OffsetsOrByTheirTextForChineseAndEmoji() async throws {
        // 构造的数据：正文分两个 chunk 到达，含中文和 emoji（emoji 在 UTF-8 是 4 字节、UTF-16 是 2 个单元）
        let first = "今天东京晴，气温 20 度。"
        let second = "🌤️ 明天有雨。注意带伞。"
        let full = first + second
        func bytes(_ s: Substring) -> Int { s.utf8.count }
        let rain = full.range(of: "明天有雨。")!
        let umbrella = full.range(of: "注意带伞。")!
        // 第一段：UTF-8 字节偏移，和 segment.text 一致
        // 第二段：UTF-8 字节偏移，前面隔着 emoji
        // 第三段：偏移是错的（模拟按字符计数），只能靠 segment.text 在正文里找
        let supports = """
            [
              {"segment":{"startIndex":0,"endIndex":\(bytes(full[..<full.index(full.startIndex, offsetBy: first.count)])),"text":\(jsonString(first))},"groundingChunkIndices":[0]},
              {"segment":{"startIndex":\(bytes(full[..<rain.lowerBound])),"endIndex":\(bytes(full[..<rain.upperBound])),"text":"明天有雨。"},"groundingChunkIndices":[1]},
              {"segment":{"startIndex":\(full.distance(from: full.startIndex, to: umbrella.lowerBound)),"endIndex":\(full.distance(from: full.startIndex, to: umbrella.upperBound)),"text":"注意带伞。"},"groundingChunkIndices":[0,1]}
            ]
            """
        let grounding = """
            {"webSearchQueries":["东京天气"],"groundingChunks":[{"web":{"uri":"https://a.example","title":"a.example"}},{"web":{"uri":"https://b.example","title":"b.example"}}],"groundingSupports":\(supports)}
            """
        // SSE 的 data 必须在一行里
        let oneLine = grounding.replacingOccurrences(of: "\n", with: "")
        let body = chunk(parts: [text(first)]) + chunk(parts: [text(second)], finishReason: "STOP", grounding: oneLine)
        let events = try await collect(StubTransport(body: body))

        let ns = full as NSString
        func utf16(_ needle: String) -> Range<Int> {
            let r = ns.range(of: needle)
            return r.location..<(r.location + r.length)
        }
        let a = Citation(title: "a.example", url: URL(string: "https://a.example")!)
        let b = Citation(title: "b.example", url: URL(string: "https://b.example")!)
        let citations = events.filter { if case .citation = $0 { true } else { false } }
        #expect(citations == [
            .citation(a, textRange: utf16(first)),
            .citation(b, textRange: utf16("明天有雨。")),
            .citation(a, textRange: utf16("注意带伞。")),
            .citation(b, textRange: utf16("注意带伞。")),
        ])
        // 正文已经开始之后才拿到的搜索词，放到最后发，不打断正文块
        let lastCitation = try #require(events.lastIndex { if case .citation = $0 { true } else { false } })
        let search = try #require(events.firstIndex(of: .webSearchStarted(query: "东京天气")))
        #expect(search > lastCitation)
    }

    @Test func searchQueriesThatArriveBeforeAnyTextAreShownImmediately() async throws {
        // 构造的数据：搜索词在第一个 chunk 里，正文还没开始
        let grounding = #"{"webSearchQueries":["东京天气"]}"#
        let body = chunk(grounding: grounding) + chunk(parts: [text("晴")], finishReason: "STOP")
        let events = try await collect(StubTransport(body: body))
        #expect(events.first == .webSearchStarted(query: "东京天气"))
        #expect(events.filter { $0 == .webSearchStarted(query: "东京天气") }.count == 1)
    }

    // MARK: 请求

    private func sent(_ request: ModelRequest) async throws -> (HTTPRequest, [String: JSONValue]) {
        let transport = StubTransport(body: chunk(parts: [text("Hi")], finishReason: "STOP"))
        _ = try await collect(transport, request)
        let sent = try #require(transport.requests.first)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.body)) else {
            Issue.record("body 不是对象")
            return (sent, [:])
        }
        return (sent, fields)
    }

    @Test func requestShape() async throws {
        let (sent, fields) = try await sent(request(systemPrompt: "简短回答"))
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        #expect(sent.headers["x-goog-api-key"] == "AIza-test")
        #expect(sent.headers["content-type"] == "application/json")
        let system: JSONValue = .object(["parts": .array([.object(["text": .string("简短回答")])])])
        let contents: JSONValue = .array([.object(["role": .string("user"), "parts": .array([.object(["text": .string("Hi")])])])])
        #expect(fields["systemInstruction"] == system)
        #expect(fields["contents"] == contents)
        #expect(fields["tools"] == nil)
    }

    @Test(arguments: [
        ("gemini-2.5-flash", #"{"thinkingBudget":0}"#),
        ("gemini-2.5-flash-lite", #"{"thinkingBudget":0}"#),
        ("gemini-2.5-pro", #"{"thinkingBudget":128}"#),
        ("gemini-3.1-pro-preview", #"{"thinkingLevel":"low"}"#),
        ("gemini-3-flash-preview", #"{"thinkingLevel":"minimal"}"#),
        ("gemini-3.5-flash", #"{"thinkingLevel":"minimal"}"#),
        ("gemini-3.6-flash", #"{"thinkingLevel":"minimal"}"#),
        ("gemini-3.7-flash", #"{"thinkingLevel":"low"}"#),
        ("gemini-3.8-flash", #"{"thinkingLevel":"low"}"#),
        ("gemini-3.5-flash-lite", #"{"thinkingLevel":"minimal"}"#),
        ("gemini-3.1-flash-lite", #"{"thinkingLevel":"minimal"}"#),
        ("gemini-2.0-flash", nil),
        ("some-future-model", nil),
    ] as [(String, String?)])
    func lowestThinkingSettingComesFromTheBuiltInTable(modelID: String, expected: String?) async throws {
        // ADR-0002：能关就关（2.5 Flash 系列 budget 0），关不掉的用它支持的最低档；不认识的 Model 什么都不发
        let (_, fields) = try await sent(request(modelID: modelID))
        let thinking = fields["generationConfig"]?["thinkingConfig"]
        if let expected {
            #expect(thinking == (try json(expected)))
        } else {
            #expect(thinking == nil)
        }
    }

    @Test func googleSearchToolIsAddedWhenRequested() async throws {
        let (_, fields) = try await sent(request(webSearch: true))
        let tools: JSONValue = .array([.object(["google_search": .object([:])])])
        #expect(fields["tools"] == tools)
    }

    @Test func completeAnswersAreSentBackPartByPartAndInterruptedOnesAsText() async throws {
        // 带签名的 Part 不能和别的 Part 合并，所以逐个原样发回；groundingMetadata 不是 Part，不发回
        let raw: JSONValue = .array([
            .object(["text": .string("答")]),
            .object(["text": .string("案"), "thoughtSignature": .string("c2ln")]),
            .object(["groundingMetadata": .object(["webSearchQueries": .array([.string("q")])])]),
        ])
        let complete = Message(role: .assistant, content: [ContentBlock(.opaque(provider: .gemini, raw)), ContentBlock(.text("答案"))])
        let interrupted = Message(role: .assistant, status: .interrupted, content: [ContentBlock(.opaque(provider: .gemini, raw)), ContentBlock(.text("答到"))])
        let (_, fields) = try await sent(request(messages: [.user("一"), complete, .user("二"), interrupted, .user("三")]))
        func turn(_ role: String, _ parts: [JSONValue]) -> JSONValue { .object(["role": .string(role), "parts": .array(parts)]) }
        let expected: JSONValue = .array([
            turn("user", [.object(["text": .string("一")])]),
            turn("model", [.object(["text": .string("答")]), .object(["text": .string("案"), "thoughtSignature": .string("c2ln")])]),
            turn("user", [.object(["text": .string("二")])]),
            turn("model", [.object(["text": .string("答到")])]),
            turn("user", [.object(["text": .string("三")])]),
        ])
        #expect(fields["contents"] == expected)
    }

    @Test func imagesAndTextAttachments() async throws {
        let image = Attachment(kind: .image, originalName: "截图.png", content: .image(Data([1, 2, 3]), mediaType: "image/png"))
        let code = Attachment(kind: .text, originalName: "main.swift", content: .text("print(1)"))
        let message = Message.user("看看", attachments: [image, code])
        func parts(_ fields: [String: JSONValue]) -> JSONValue? { fields["contents"]?.firstElement?["parts"] }

        let (_, withImages) = try await sent(request(messages: [message], attachments: [image.id: image, code.id: code]))
        let expectedWith: JSONValue = .array([
            .object(["inlineData": .object(["mimeType": .string("image/png"), "data": .string("AQID")])]),
            .object(["text": .string("附件 main.swift：\nprint(1)")]),
            .object(["text": .string("看看")]),
        ])
        #expect(parts(withImages) == expectedWith)

        let (_, withoutImages) = try await sent(request(imageInput: false, messages: [message], attachments: [image.id: image, code.id: code]))
        let expectedWithout: JSONValue = .array([
            .object(["text": .string("[图片已省略：当前模型不支持图片]")]),
            .object(["text": .string("附件 main.swift：\nprint(1)")]),
            .object(["text": .string("看看")]),
        ])
        #expect(parts(withoutImages) == expectedWithout)
    }

    // MARK: HTTP 错误映射

    /// Google API 通用的错误体形状；内容是构造的。
    private static func errorBody(_ code: Int, _ status: String, _ message: String, details: String = "") -> String {
        "{\"error\":{\"code\":\(code),\"message\":\"\(message)\",\"status\":\"\(status)\"\(details.isEmpty ? "" : ",\"details\":[\(details)]")}}"
    }

    @Test(arguments: [
        (400, errorBody(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.",
                        details: #"{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}"#), ChatError.authentication),
        (400, errorBody(400, "INVALID_ARGUMENT", "The input token count (1200000) exceeds the maximum number of tokens allowed (1048576)."), ChatError.contextTooLong),
        (400, errorBody(400, "INVALID_ARGUMENT", "Invalid value at 'contents'"), ChatError.invalidRequest("Invalid value at 'contents'")),
        (403, errorBody(403, "PERMISSION_DENIED", "Permission denied"), ChatError.authentication),
        (404, errorBody(404, "NOT_FOUND", "models/x is not found"), ChatError.invalidRequest("models/x is not found")),
        (429, errorBody(429, "RESOURCE_EXHAUSTED", "Quota exceeded",
                        details: #"{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"17s"}"#), ChatError.rateLimited(retryAfter: 17)),
        (500, errorBody(500, "INTERNAL", "Internal error"), ChatError.overloaded),
        (503, errorBody(503, "UNAVAILABLE", "The model is overloaded."), ChatError.overloaded),
    ] as [(Int, String, ChatError)])
    func httpErrorsAreMapped(statusCode: Int, body: String, expected: ChatError) async throws {
        let transport = StubTransport(statusCode: statusCode, body: body)
        await #expect(throws: expected) { try await collect(transport) }
        await #expect(throws: expected) {
            try await GeminiAdapter(transport: transport).listModels(.gemini(), apiKey: "k")
        }
    }

    // MARK: Model 列表

    @Test func listModelsKeepsChatModelsAndUsesTheBuiltInCapabilityTable() async throws {
        // 构造的两页数据（字段按 https://ai.google.dev/api/models 的 Model 结构）
        func model(_ name: String, methods: [String] = ["generateContent", "countTokens"]) -> String {
            let list = methods.map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"name\":\"models/\(name)\",\"displayName\":\"\(name)\",\"inputTokenLimit\":1048576,\"outputTokenLimit\":65536,\"supportedGenerationMethods\":[\(list)]}"
        }
        let page1 = "{\"models\":[\(model("gemini-2.5-flash")),\(model("text-embedding-004", methods: ["embedContent"])),\(model("gemini-2.5-flash-preview-tts"))],\"nextPageToken\":\"p2\"}"
        let page2 = "{\"models\":[\(model("gemini-1.5-flash")),\(model("gemini-3.5-flash"))]}"
        let transport = StubTransport(sequence: [
            .response(statusCode: 200, headers: [:], body: Array(page1.utf8)),
            .response(statusCode: 200, headers: [:], body: Array(page2.utf8)),
        ])
        let models = try await GeminiAdapter(transport: transport).listModels(.gemini(), apiKey: "k")

        #expect(models.map(\.id) == ["gemini-2.5-flash", "gemini-1.5-flash", "gemini-3.5-flash"])
        #expect(models[0].contextWindow == 1_048_576)
        #expect(models[0].maxOutputTokens == 65_536)
        #expect(models[0].capabilities == ModelCapabilities(imageInput: true, toolCalling: true, webSearch: true))
        // 不在 google_search 支持表里的旧 Model 不开搜索
        #expect(models[1].capabilities.webSearch == false)
        #expect(transport.requests.first?.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
        #expect(transport.requests.last?.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&pageToken=p2")
        #expect(transport.requests.first?.headers["x-goog-api-key"] == "k")
    }
}

private extension JSONValue {
    var firstElement: JSONValue? {
        if case .array(let items) = self { return items.first }
        return nil
    }
}
