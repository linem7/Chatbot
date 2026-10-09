import Foundation

/// Anthropic Messages API 的 adapter（ARCHITECTURE §3.2）。没有官方 Swift SDK，直接用 HTTP。
///
/// - 端点是 `POST {base}/v1/messages`，Model 列表是 `GET {base}/v1/models`（分页）。
/// - 思考（ADR-0002）：Model 能关的就发 `thinking: disabled`；关不掉的（Opus 5.5、Sonnet 5.5、Fable）不发 thinking。
///   两种情况都在支持时发 `output_config.effort: "low"`，把思考和延迟压到最低。是否支持都看 `/v1/models` 的 capabilities。
/// - Web Search 用 `web_search_20250305`，`max_uses: 3`（ADR-0003）。
/// - 流里每个完整的内容块（thinking、server_tool_use、web_search_tool_result、带 citations 的 text）
///   都通过 `providerData` 原样交出去，由 TurnRunner 保存；继续对话时逐字发回（ADR-0001）。
public struct AnthropicAdapter: ProviderAdapter {
    static let apiVersion = "2023-06-01"
    static let webSearchTool: JSONValue = .object([
        "type": .string("web_search_20250305"),
        "name": .string("web_search"),
        "max_uses": .number(3),
    ])
    /// 流式请求的 max_tokens 上限；Model 报告的上限更小时用 Model 的。
    static let maxTokensCap = 64_000
    /// 不知道 Model 的上限时用这个（所有现役 Model 都支持）。
    static let fallbackMaxTokens = 16_000

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = defaultHTTPTransport()) {
        self.transport = transport
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels(_ connection: Connection, apiKey: String) async throws -> [ModelInfo] {
        do {
            var models: [ModelInfo] = []
            var seen: Set<String> = []
            var afterID: String?
            // 最多翻 20 页；某一页没有新 Model（例如服务端的 last_id 不变）时也停下
            for _ in 0..<20 {
                var components = URLComponents(url: connection.baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let afterID { components.queryItems?.append(URLQueryItem(name: "after_id", value: afterID)) }
                let response = try await transport.send(HTTPRequest(method: "GET", url: components.url!, headers: Self.headers(apiKey)))
                try await Self.throwIfNotSuccess(response)
                let data = try await response.collectBody(limit: 4 * 1024 * 1024)
                guard let page = try? JSONDecoder().decode(ModelPage.self, from: data) else {
                    throw ChatError.providerError("无法解析 Model 列表")
                }
                let fresh = page.data.filter { seen.insert($0.id).inserted }
                models += fresh.map(\.modelInfo)
                guard page.hasMore == true, let lastID = page.lastID, !fresh.isEmpty else { break }
                afterID = lastID
            }
            return models
        } catch {
            throw Self.normalize(error)
        }
    }

    // MARK: 一次模型调用

    private func run(_ request: ModelRequest, continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation) async throws {
        let response = try await transport.send(try Self.httpRequest(for: request))
        try await Self.throwIfNotSuccess(response)

        var decoder = AnthropicStreamDecoder()
        do {
            for try await event in response.body.sseEvents() {
                for modelEvent in try decoder.consume(event) { continuation.yield(modelEvent) }
                if decoder.isFinished { break }
            }
        } catch where decoder.stopReason != nil && !(error is CancellationError) {
            // stop_reason 已经到了，之后（message_stop 之前）连接断开：回答是完整的，按正常结束处理
        }
        try Task.checkCancellation()

        guard let stopReason = decoder.stopReason else {
            // 没有 stop_reason：连接在中途断了
            throw ChatError.network
        }
        continuation.yield(.finished(try Self.finishReason(stopReason)))
    }

    private static func finishReason(_ raw: String) throws -> FinishReason {
        switch raw {
        case "end_turn", "stop_sequence": return .stop
        // 输出到了上限，或者撑满了上下文窗口：正文可能被截断
        case "max_tokens", "model_context_window_exceeded": return .length
        case "pause_turn": return .pauseTurn
        case "tool_use": return .toolUse
        // 安全分类器拒答。不开服务端 fallback：Conversation 的 Model 创建后不换（CONTEXT.md）
        case "refusal": throw ChatError.providerError("模型拒绝回答这个问题（stop_reason: refusal）")
        default: return .stop
        }
    }

    // MARK: 请求编码

    static func httpRequest(for request: ModelRequest) throws -> HTTPRequest {
        let model = request.connection.models.first { $0.id == request.modelID }
        let capabilities = model?.providerData

        var body: [String: JSONValue] = [
            "model": .string(request.modelID),
            "max_tokens": .number(Double(model?.maxOutputTokens.map { min($0, maxTokensCap) } ?? fallbackMaxTokens)),
            "stream": .bool(true),
            "messages": .array(messages(for: request)),
        ]
        if !request.systemPrompt.isEmpty {
            body["system"] = .string(request.systemPrompt)
        }
        // ADR-0002：能关的就关；关不掉时不发（发了会 400）
        if capabilities?["thinking"]?["types"]?["disabled"]?["supported"]?.boolValue == true {
            body["thinking"] = .object(["type": .string("disabled")])
        }
        if capabilities?["effort"]?["low"]?["supported"]?.boolValue == true {
            body["output_config"] = .object(["effort": .string("low")])
        }
        if request.webSearch {
            body["tools"] = .array([webSearchTool])
        }

        return HTTPRequest(
            method: "POST",
            url: request.connection.baseURL.appendingPathComponent("v1/messages"),
            headers: headers(request.apiKey).merging(["content-type": "application/json", "accept": "text/event-stream"]) { _, new in new },
            body: try JSONEncoder().encode(JSONValue.object(body))
        )
    }

    private static func headers(_ apiKey: String) -> [String: String] {
        ["x-api-key": apiKey, "anthropic-version": apiVersion]
    }

    private static func messages(for request: ModelRequest) -> [JSONValue] {
        let acceptsImages = request.capabilities.imageInput
        return request.messages.compactMap { message in
            switch message.role {
            case .user:
                let blocks = userBlocks(message, attachments: request.attachments, acceptsImages: acceptsImages)
                if blocks.isEmpty { return nil }
                return .object(["role": .string("user"), "content": content(blocks)])
            case .assistant:
                // 完整的回答（以及 pause_turn 续接时还在进行中的回答）把原生块逐字发回：
                // 思考块的 signature、搜索结果的 encrypted_content、引用的 encrypted_index 都必须原样回传。
                // 被取消或出错的回答里可能有不完整的工具块，只发文字。
                if message.status == .complete || message.status == .streaming,
                   let raw = rawBlocks(of: message), !raw.isEmpty {
                    return .object(["role": .string("assistant"), "content": .array(raw)])
                }
                let text = message.markdownText
                if text.isEmpty { return nil }
                return .object(["role": .string("assistant"), "content": .string(text)])
            }
        }
    }

    /// Message 里 Anthropic 的原生块（TurnRunner 把它们累积在一个 opaque 块里）。
    private static func rawBlocks(of message: Message) -> [JSONValue]? {
        for block in message.content {
            if case .opaque(.anthropic, .array(let raw)) = block.kind { return raw }
        }
        return nil
    }

    /// 全是文字时发字符串，否则发内容块数组。
    private static func content(_ blocks: [JSONValue]) -> JSONValue {
        let texts = blocks.compactMap { $0["type"] == .string("text") ? $0["text"]?.stringValue : nil }
        return texts.count == blocks.count ? .string(texts.joined(separator: "\n\n")) : .array(blocks)
    }

    /// 用户 Message 按内容块的顺序编码，规则和 OpenAI 兼容 adapter 一致（ARCHITECTURE §6）。
    private static func userBlocks(_ message: Message, attachments: [UUID: Attachment], acceptsImages: Bool) -> [JSONValue] {
        func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }
        return message.content.compactMap { block in
            switch block.kind {
            case .text(let value, _):
                return value.isEmpty ? nil : text(value)
            case .attachmentRef(let id):
                guard let attachment = attachments[id] else { return nil }
                switch attachment.content {
                case .image(let data, let mediaType):
                    guard acceptsImages else { return text(OpenAICompatibleAdapter.omittedImageNote) }
                    return .object(["type": .string("image"), "source": .object([
                        "type": .string("base64"), "media_type": .string(mediaType), "data": .string(data.base64EncodedString()),
                    ])])
                case .text(let value):
                    return text("附件 \(attachment.originalName)：\n\(value)")
                }
            default:
                return nil
            }
        }
    }

    // MARK: 错误映射（ARCHITECTURE §3.4）

    private static func throwIfNotSuccess(_ response: HTTPResponse) async throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let data = try await response.collectBody(limit: OpenAICompatibleAdapter.errorBodyLimit)
        let detail = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error
        let rawText = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = String((detail?.message ?? (rawText.isEmpty ? "HTTP \(response.statusCode)" : rawText))
            .prefix(OpenAICompatibleAdapter.errorMessageLimit))

        switch response.statusCode {
        case 401: throw ChatError.authentication
        // billing_error：额度用完，SPEC §7 归到 rateLimited
        case 402: throw ChatError.rateLimited(retryAfter: nil)
        case 429: throw ChatError.rateLimited(retryAfter: response.headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 400: throw invalidRequest(message)
        case 404, 413: throw ChatError.invalidRequest(message)
        // 包括 529 overloaded_error
        case 500..<600: throw ChatError.overloaded
        default: throw ChatError.providerError(message)
        }
    }

    /// 400 里的上下文超长："prompt is too long: N tokens > M maximum"。
    static func invalidRequest(_ message: String) -> ChatError {
        message.localizedCaseInsensitiveContains("prompt is too long") ? .contextTooLong : .invalidRequest(message)
    }

    /// 流中途的 `event: error`。
    static func streamError(type: String?, message: String) -> ChatError {
        switch type {
        case "overloaded_error", "api_error": .overloaded
        case "rate_limit_error", "billing_error": .rateLimited(retryAfter: nil)
        case "authentication_error": .authentication
        case "invalid_request_error": invalidRequest(message)
        default: .providerError(message)
        }
    }

    private static func normalize(_ error: any Error) -> any Error {
        if error is ChatError || error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        return ChatError.providerError(String(describing: error))
    }
}

// MARK: - 流解码

/// 把 Messages API 的 SSE 事件解码成 ModelEvent，同时把每个内容块拼回完整的原生 JSON。
struct AnthropicStreamDecoder {
    private struct Block {
        var json: [String: JSONValue]
        /// tool_use / server_tool_use 的 input 是分片的 JSON 字符串，块结束时再解析
        var partialJSON = ""
        var citations: [JSONValue] = []
        /// 这个块的正文在这次调用的输出里从哪里开始（UTF-16 偏移）
        var textStart: Int
    }

    private var blocks: [Int: Block] = [:]
    /// 这次调用到目前为止输出的正文长度（UTF-16）
    private var emittedText = 0
    private(set) var stopReason: String?
    private(set) var isFinished = false

    mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
        // 宽松解码：看不懂的事件直接跳过（ping、以后新增的类型）
        guard let data = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else { return [] }
        switch data["type"]?.stringValue ?? event.event {
        case "content_block_start":
            guard let index = data["index"].flatMap(Self.int), case .object(let json)? = data["content_block"] else { return [] }
            blocks[index] = Block(json: json, textStart: emittedText)
            return []
        case "content_block_delta":
            guard let index = data["index"].flatMap(Self.int), let delta = data["delta"] else { return [] }
            return apply(delta, to: index)
        case "content_block_stop":
            guard let index = data["index"].flatMap(Self.int) else { return [] }
            return finish(index)
        case "message_delta":
            if let reason = data["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            return []
        case "message_stop":
            isFinished = true
            return []
        case "error":
            throw AnthropicAdapter.streamError(
                type: data["error"]?["type"]?.stringValue,
                message: data["error"]?["message"]?.stringValue ?? event.data
            )
        default:
            return []
        }
    }

    private mutating func apply(_ delta: JSONValue, to index: Int) -> [ModelEvent] {
        guard var block = blocks[index] else { return [] }
        defer { blocks[index] = block }
        switch delta["type"]?.stringValue {
        case "text_delta":
            guard let text = delta["text"]?.stringValue else { return [] }
            block.json["text"] = .string((block.json["text"]?.stringValue ?? "") + text)
            emittedText += text.utf16.count
            return text.isEmpty ? [] : [.textDelta(text)]
        case "citations_delta":
            if let citation = delta["citation"] { block.citations.append(citation) }
        case "thinking_delta":
            block.json["thinking"] = .string((block.json["thinking"]?.stringValue ?? "") + (delta["thinking"]?.stringValue ?? ""))
        case "signature_delta":
            if let signature = delta["signature"] { block.json["signature"] = signature }
        case "input_json_delta":
            block.partialJSON += delta["partial_json"]?.stringValue ?? ""
        default:
            break
        }
        return []
    }

    private mutating func finish(_ index: Int) -> [ModelEvent] {
        guard var block = blocks.removeValue(forKey: index) else { return [] }
        var events: [ModelEvent] = []

        if !block.partialJSON.isEmpty,
           let input = try? JSONDecoder().decode(JSONValue.self, from: Data(block.partialJSON.utf8)) {
            block.json["input"] = input
        }
        let type = block.json["type"]?.stringValue
        if type == "server_tool_use", block.json["name"]?.stringValue == "web_search" {
            events.append(.webSearchStarted(query: block.json["input"]?["query"]?.stringValue ?? ""))
        }
        if type == "text", !block.citations.isEmpty {
            block.json["citations"] = .array(block.citations)
            let range = block.textStart..<emittedText
            for citation in block.citations {
                guard let urlString = citation["url"]?.stringValue, let url = URL(string: urlString) else { continue }
                let title = citation["title"]?.stringValue ?? urlString
                events.append(.citation(Citation(title: title, url: url), textRange: range))
            }
        }
        events.append(.providerData(blockIndex: index, opaque: .object(block.json)))
        return events
    }

    private static func int(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { return Int(number) }
        return nil
    }
}

// MARK: - 线上格式

private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        var type: String?
        var message: String?
    }

    var error: Detail
}

private struct ModelPage: Decodable {
    struct Entry: Decodable {
        var id: String
        var displayName: String?
        var maxInputTokens: Int?
        var maxTokens: Int?
        var capabilities: JSONValue?

        enum CodingKeys: String, CodingKey {
            case id, capabilities
            case displayName = "display_name"
            case maxInputTokens = "max_input_tokens"
            case maxTokens = "max_tokens"
        }

        /// 图片看 `image_input`，搜索看 `server_tools.web_search`，tools 视为支持（ARCHITECTURE §3.2）。
        /// 能力原文存进 providerData，adapter 判断思考和 effort 时要用。
        var modelInfo: ModelInfo {
            var result = ModelCapabilities.conservative
            if let capabilities, capabilities != .null {
                result.imageInput = capabilities["image_input"]?["supported"]?.boolValue ?? false
                result.webSearch = capabilities["server_tools"]?["web_search"]?["supported"]?.boolValue ?? false
            }
            return ModelInfo(
                id: id,
                displayName: displayName,
                // 0 是未知（文档示例里就是占位的 0）
                contextWindow: maxInputTokens.flatMap { $0 > 0 ? $0 : nil },
                maxOutputTokens: maxTokens.flatMap { $0 > 0 ? $0 : nil },
                capabilities: result,
                providerData: capabilities
            )
        }
    }

    var data: [Entry]
    var hasMore: Bool?
    var lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}
