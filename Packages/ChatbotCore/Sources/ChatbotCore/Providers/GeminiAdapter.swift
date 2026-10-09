import Foundation

/// Gemini `generateContent` 的 adapter（ARCHITECTURE §3.2）。
///
/// - 端点是 `POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse`，key 放在 `x-goog-api-key` 头里。
///   文档已标为 Legacy，但截至 2026-10-09 没有停用计划（ARCHITECTURE §8 第 2 条）。
/// - 思考（ADR-0002）：按内置表发最低档（`GeminiModelTable`），`thought: true` 的 Part 不展示。
/// - 每个 SSE 事件是一个完整的 `GenerateContentResponse`。收到的每个 Part 都原样交出去：
///   `thoughtSignature` 可能落在任何 Part 上（包括空文本的 Part），带签名的 Part 不能合并，所以回传时逐个发回。
/// - Google Search：`tools: [{google_search: {}}]`。`groundingMetadata` 以 `{"groundingMetadata": …}` 的形式
///   放进不透明数据（App 用它渲染搜索建议），回传时跳过；Citation 由 groundingSupports 换算。
public struct GeminiAdapter: ProviderAdapter {
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
            var pageToken: String?
            // 最多翻 20 页
            for _ in 0..<20 {
                var components = URLComponents(url: connection.baseURL.appendingPathComponent("v1beta/models"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                let response = try await transport.send(HTTPRequest(method: "GET", url: components.url!, headers: ["x-goog-api-key": apiKey]))
                try await Self.throwIfNotSuccess(response)
                let data = try await response.collectBody(limit: 4 * 1024 * 1024)
                guard let page = try? JSONDecoder().decode(ModelPage.self, from: data) else {
                    throw ChatError.providerError("无法解析 Model 列表")
                }
                models += (page.models ?? []).compactMap(\.modelInfo)
                // 中转常常只返回 OpenAI 风格的列表（`{"data": [{"id": …}]}`），能力同样来自内置表
                models += (page.data ?? []).compactMap { ModelPage.Entry(name: $0.id).modelInfo }
                guard let next = page.nextPageToken, !next.isEmpty, next != pageToken else { break }
                pageToken = next
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

        var decoder = GeminiStreamDecoder()
        do {
            for try await event in response.body.sseEvents() {
                for modelEvent in try decoder.consume(event) { continuation.yield(modelEvent) }
            }
        } catch where decoder.finishReason != nil && !(error is CancellationError) {
            // finishReason 已经到了，之后连接断开：回答是完整的，按正常结束处理
        }
        try Task.checkCancellation()

        guard let finishReason = decoder.finishReason else {
            // 没有 finishReason：连接在中途断了
            throw ChatError.network
        }
        for event in decoder.finish() { continuation.yield(event) }
        continuation.yield(.finished(try Self.finishReason(finishReason)))
    }

    private static func finishReason(_ raw: String) throws -> FinishReason {
        switch raw {
        case "MAX_TOKENS": return .length
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "LANGUAGE":
            throw ChatError.providerError("回答被 Gemini 的安全过滤拦截了（finishReason: \(raw)）")
        // OTHER 是异常结束，回答可能不完整
        case "OTHER":
            throw ChatError.providerError("Gemini 异常结束了回答（finishReason: OTHER）")
        default:
            // STOP，以及没见过的值
            return .stop
        }
    }

    // MARK: 请求编码

    static func httpRequest(for request: ModelRequest) throws -> HTTPRequest {
        var body: [String: JSONValue] = ["contents": .array(contents(for: request))]
        if !request.systemPrompt.isEmpty {
            body["systemInstruction"] = .object(["parts": .array([.object(["text": .string(request.systemPrompt)])])])
        }
        switch GeminiModelTable.lowestThinking(for: request.modelID) {
        case .budget(let budget):
            body["generationConfig"] = .object(["thinkingConfig": .object(["thinkingBudget": .number(Double(budget))])])
        case .level(let level):
            body["generationConfig"] = .object(["thinkingConfig": .object(["thinkingLevel": .string(level)])])
        case nil:
            break
        }
        if request.webSearch {
            body["tools"] = .array([.object(["google_search": .object([:])])])
        }

        let path = "v1beta/models/\(request.modelID):streamGenerateContent"
        var components = URLComponents(url: request.connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        return HTTPRequest(
            method: "POST",
            url: components.url!,
            headers: ["x-goog-api-key": request.apiKey, "content-type": "application/json", "accept": "text/event-stream"],
            body: try JSONEncoder().encode(JSONValue.object(body))
        )
    }

    private static func contents(for request: ModelRequest) -> [JSONValue] {
        let acceptsImages = request.capabilities.imageInput
        return request.messages.compactMap { message in
            switch message.role {
            case .user:
                let parts = userParts(message, attachments: request.attachments, acceptsImages: acceptsImages)
                if parts.isEmpty { return nil }
                return .object(["role": .string("user"), "parts": .array(parts)])
            case .assistant:
                // 完整的回答逐个原样发回收到的 Part（不合并，thoughtSignature 留在原来的 Part 上）；
                // 被取消或出错的回答只发文字
                if message.status == .complete || message.status == .streaming, let raw = rawParts(of: message) {
                    let parts = raw.filter { $0["groundingMetadata"] == nil }
                    if !parts.isEmpty { return .object(["role": .string("model"), "parts": .array(parts)]) }
                }
                let text = message.markdownText
                if text.isEmpty { return nil }
                return .object(["role": .string("model"), "parts": .array([.object(["text": .string(text)])])])
            }
        }
    }

    private static func rawParts(of message: Message) -> [JSONValue]? {
        for block in message.content {
            if case .opaque(.gemini, .array(let raw)) = block.kind { return raw }
        }
        return nil
    }

    /// 用户 Message 按内容块的顺序编码，规则和另外两个 adapter 一致（ARCHITECTURE §6）。
    private static func userParts(_ message: Message, attachments: [UUID: Attachment], acceptsImages: Bool) -> [JSONValue] {
        func text(_ value: String) -> JSONValue { .object(["text": .string(value)]) }
        return message.content.compactMap { block in
            switch block.kind {
            case .text(let value, _):
                return value.isEmpty ? nil : text(value)
            case .attachmentRef(let id):
                guard let attachment = attachments[id] else { return nil }
                switch attachment.content {
                case .image(let data, let mediaType):
                    guard acceptsImages else { return text(OpenAICompatibleAdapter.omittedImageNote) }
                    return .object(["inlineData": .object(["mimeType": .string(mediaType), "data": .string(data.base64EncodedString())])])
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
        let detail = try? JSONDecoder().decode(JSONValue.self, from: data)
        let rawText = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail?["error"]?["message"]?.stringValue ?? (rawText.isEmpty ? "HTTP \(response.statusCode)" : rawText)
        throw chatError(statusCode: response.statusCode, error: detail?["error"], message: message)
    }

    /// Google API 的错误：`{"error": {"code", "message", "status", "details": [...]}}`。HTTP 错误和流中途的错误共用。
    static func chatError(statusCode: Int?, error: JSONValue?, message: String) -> ChatError {
        let message = String(message.prefix(OpenAICompatibleAdapter.errorMessageLimit))
        let status = error?["status"]?.stringValue
        let code = statusCode ?? error?["code"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } }
        let details: [JSONValue] = if case .array(let items)? = error?["details"] { items } else { [] }

        // key 无效时返回的是 400 INVALID_ARGUMENT，靠 ErrorInfo 的 reason 或 message 识别
        if details.contains(where: { $0["reason"]?.stringValue == "API_KEY_INVALID" })
            || message.localizedCaseInsensitiveContains("API key not valid") {
            return .authentication
        }
        switch (code, status) {
        case (401, _), (403, _), (_, "UNAUTHENTICATED"), (_, "PERMISSION_DENIED"):
            return .authentication
        case (429, _), (_, "RESOURCE_EXHAUSTED"):
            // RetryInfo 的 retryDelay 形如 "17s"
            let delay = details.lazy.compactMap { $0["retryDelay"]?.stringValue }.first
                .flatMap { TimeInterval($0.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) }
            return .rateLimited(retryAfter: delay)
        case (400, _), (_, "INVALID_ARGUMENT"):
            // "The input token count (N) exceeds the maximum number of tokens allowed (M)."
            if message.localizedCaseInsensitiveContains("exceeds the maximum number of tokens") { return .contextTooLong }
            return .invalidRequest(message)
        case (404, _), (_, "NOT_FOUND"):
            return .invalidRequest(message)
        case (.some(500..<600), _), (_, "UNAVAILABLE"), (_, "INTERNAL"):
            return .overloaded
        default:
            return .providerError(message)
        }
    }

    private static func normalize(_ error: any Error) -> any Error {
        if error is ChatError || error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        return ChatError.providerError(String(describing: error))
    }
}

// MARK: - 流解码

/// 把 `streamGenerateContent` 的 SSE 解码成 ModelEvent。
struct GeminiStreamDecoder {
    private var partIndex = 0
    /// 这次调用输出的全部正文，换算 Citation 的位置时用
    private var text = ""
    private var grounding: JSONValue?
    private var shownQueries: Set<String> = []
    private(set) var finishReason: String?

    mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
        // 宽松解码：看不懂的 chunk 直接跳过
        guard let data = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else { return [] }
        if let error = data["error"] {
            throw GeminiAdapter.chatError(statusCode: nil, error: error, message: error["message"]?.stringValue ?? event.data)
        }
        if let reason = data["promptFeedback"]?["blockReason"]?.stringValue {
            throw ChatError.providerError("问题被 Gemini 的安全过滤拦截了（blockReason: \(reason)）")
        }
        guard case .array(let candidates)? = data["candidates"], let candidate = candidates.first else { return [] }

        var events: [ModelEvent] = []
        if case .array(let parts)? = candidate["content"]?["parts"] {
            for part in parts {
                // thought: true 的 Part 是思考摘要，不展示；但和其他 Part 一样原样保存
                if part["thought"]?.boolValue != true, let value = part["text"]?.stringValue, !value.isEmpty {
                    events.append(.textDelta(value))
                    text += value
                }
                events.append(.providerData(blockIndex: partIndex, opaque: part))
                partIndex += 1
            }
        }
        if let metadata = candidate["groundingMetadata"] {
            grounding = metadata
            // 正文还没开始时立刻显示「正在搜索」；正文开始之后才拿到的搜索词放到最后，避免打断正文块
            if text.isEmpty { events += newQueries(in: metadata) }
        }
        if let reason = candidate["finishReason"]?.stringValue { finishReason = reason }
        return events
    }

    /// 流结束时：Citation、剩下的搜索词、groundingMetadata（供 App 渲染搜索建议）。
    mutating func finish() -> [ModelEvent] {
        guard let grounding else { return [] }
        var events = citations(in: grounding)
        events += newQueries(in: grounding)
        events.append(.providerData(blockIndex: partIndex, opaque: .object(["groundingMetadata": grounding])))
        return events
    }

    private mutating func newQueries(in metadata: JSONValue) -> [ModelEvent] {
        guard case .array(let queries)? = metadata["webSearchQueries"] else { return [] }
        return queries.compactMap(\.stringValue).filter { shownQueries.insert($0).inserted }.map { .webSearchStarted(query: $0) }
    }

    private func citations(in metadata: JSONValue) -> [ModelEvent] {
        guard case .array(let chunks)? = metadata["groundingChunks"], case .array(let supports)? = metadata["groundingSupports"] else { return [] }
        var events: [ModelEvent] = []
        for support in supports {
            let range = GroundingLocator.range(of: support["segment"], in: text)
            guard case .array(let indices)? = support["groundingChunkIndices"] else { continue }
            for index in indices {
                guard case .number(let n) = index, Int(n) >= 0, Int(n) < chunks.count,
                      let web = chunks[Int(n)]["web"], let uri = web["uri"]?.stringValue, let url = URL(string: uri)
                else { continue }
                events.append(.citation(Citation(title: web["title"]?.stringValue ?? uri, url: url), textRange: range))
            }
        }
        return events
    }
}

/// 把 groundingSupports 的 segment 换算成正文里的 UTF-16 范围（ARCHITECTURE §8 第 2 条）。
///
/// 文档没说 startIndex/endIndex 是字节还是字符，官方示例本身也对不上。这里不依赖单位：
/// 1. 先按 UTF-8 字节偏移换算，切出来的文字和 segment.text 一致就用它；
/// 2. 否则在正文里找 segment.text，有多处时取离给定偏移最近的；
/// 3. 都不行时，字节换算出的范围合法就退而用它（中文也不会切到半个字），否则不给范围。
enum GroundingLocator {
    static func range(of segment: JSONValue?, in text: String) -> Range<Int>? {
        guard let segment else { return nil }
        let start = segment["startIndex"].flatMap(int) ?? 0
        guard let end = segment["endIndex"].flatMap(int), start <= end else { return nil }
        let segmentText = segment["text"]?.stringValue ?? ""

        let byteRange = utf16Range(fromUTF8: start..<end, in: text)
        if let byteRange, substring(text, byteRange) == segmentText { return byteRange }

        if !segmentText.isEmpty {
            let utf16 = Array(text.utf16)
            let needle = Array(segmentText.utf16)
            let hint = byteRange?.lowerBound ?? start
            var best: Int?
            if needle.count <= utf16.count {
                for offset in 0...(utf16.count - needle.count) where utf16[offset..<(offset + needle.count)].elementsEqual(needle) {
                    if best.map({ abs($0 - hint) > abs(offset - hint) }) ?? true { best = offset }
                }
            }
            if let best { return best..<(best + needle.count) }
        }
        return byteRange
    }

    private static func int(_ value: JSONValue) -> Int? {
        if case .number(let n) = value { return Int(n) }
        return nil
    }

    /// UTF-8 字节偏移换算成 UTF-16 偏移；越界或者落在一个字符中间时返回 nil。
    private static func utf16Range(fromUTF8 range: Range<Int>, in text: String) -> Range<Int>? {
        let utf8 = text.utf8
        guard range.upperBound <= utf8.count else { return nil }
        let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let upper = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
        guard let lowerUTF16 = lower.samePosition(in: text.utf16), let upperUTF16 = upper.samePosition(in: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: lowerUTF16)..<text.utf16.distance(from: text.utf16.startIndex, to: upperUTF16)
    }

    private static func substring(_ text: String, _ range: Range<Int>) -> String {
        let utf16 = Array(text.utf16)
        return String(decoding: utf16[range], as: UTF16.self)
    }
}

// MARK: - 线上格式

private struct ModelPage: Decodable {
    struct Entry: Decodable {
        var name: String
        var displayName: String?
        var inputTokenLimit: Int?
        var outputTokenLimit: Int?
        var supportedGenerationMethods: [String]?

        /// 只保留能 generateContent 的聊天模型；能力来自内置表。
        var modelInfo: ModelInfo? {
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            guard supportedGenerationMethods?.contains("generateContent") ?? true, GeminiModelTable.isChatModel(id) else { return nil }
            return ModelInfo(
                id: id,
                displayName: displayName,
                contextWindow: inputTokenLimit,
                maxOutputTokens: outputTokenLimit,
                capabilities: ModelCapabilities(
                    imageInput: GeminiModelTable.acceptsImages(id),
                    toolCalling: true,
                    webSearch: GeminiModelTable.supportsWebSearch(id)
                )
            )
        }
    }

    struct OpenAIStyleEntry: Decodable {
        var id: String
    }

    var models: [Entry]?
    var nextPageToken: String?
    var data: [OpenAIStyleEntry]?
}
