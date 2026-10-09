import Foundation

/// OpenAI 兼容 Provider 的 adapter（DeepSeek 等），ARCHITECTURE §3.2。
///
/// - 端点是 `POST {base}/chat/completions`，DeepSeek 的 base URL 不带 `/v1`。
/// - 对 DeepSeek 发 `thinking: {type: "disabled"}` 关闭思考（ADR-0002）；
///   不发它不支持的 OpenAI 字段（`n`、`seed`、`parallel_tool_calls`、`max_completion_tokens`、`logit_bias`），
///   也不用 `developer` role。
/// - v1 只解码正文和 `finish_reason`；tool call 的增量暂不解码（v1 没有 app 侧工具）。
public struct OpenAICompatibleAdapter: ProviderAdapter {
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
            let request = HTTPRequest(
                method: "GET",
                url: connection.baseURL.appendingPathComponent("models"),
                headers: ["Authorization": "Bearer \(apiKey)"]
            )
            let response = try await transport.send(request)
            try await Self.throwIfNotSuccess(response)
            let data = try await response.collectBody(limit: Self.modelListLimit)
            guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
                throw ChatError.providerError("无法解析 Model 列表")
            }
            return list.data.map(\.modelInfo)
        } catch {
            throw Self.normalize(error)
        }
    }

    // MARK: 一次模型调用

    private func run(_ request: ModelRequest, continuation: AsyncThrowingStream<ModelEvent, any Error>.Continuation) async throws {
        let response = try await transport.send(try Self.httpRequest(for: request))
        try await Self.throwIfNotSuccess(response)

        var finishReason: FinishReason?
        var sawDone = false
        do {
            for try await event in response.body.sseEvents() {
                if event.data == "[DONE]" {
                    sawDone = true
                    break
                }
                // 宽松解码：看不懂的 chunk 直接跳过
                guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(event.data.utf8)) else { continue }
                if let error = chunk.error {
                    throw ChatError.providerError(error.message ?? event.data)
                }
                guard let choice = chunk.choices?.first(where: { ($0.index ?? 0) == 0 }) else { continue }
                if let content = choice.delta?.content, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
                if let raw = choice.finishReason {
                    finishReason = try Self.finishReason(raw)
                }
            }
        } catch where finishReason != nil && !(error is CancellationError) {
            // finish_reason 已经到了，之后（[DONE] 之前）连接断开：回答是完整的，按正常结束处理
        }
        try Task.checkCancellation()

        if let finishReason {
            continuation.yield(.finished(finishReason))
        } else if sawDone {
            continuation.yield(.finished(.stop))
        } else {
            // 没有 finish_reason 也没有 [DONE]：连接在中途断了
            throw ChatError.network
        }
    }

    private static func finishReason(_ raw: String) throws -> FinishReason {
        switch raw {
        case "stop": return .stop
        case "length": return .length
        case "tool_calls": return .toolUse
        case "insufficient_system_resource": throw ChatError.overloaded
        case "aborted": throw ChatError.providerError("DeepSeek 中途中止了生成（finish_reason: aborted）")
        case "content_filter": throw ChatError.providerError("回答被内容过滤拦截了（finish_reason: content_filter）")
        default: return .stop
        }
    }

    // MARK: 请求编码

    static func httpRequest(for request: ModelRequest) throws -> HTTPRequest {
        var messages: [ChatMessage] = []
        if !request.systemPrompt.isEmpty {
            messages.append(ChatMessage(role: "system", content: request.systemPrompt))
        }
        for message in request.messages {
            // 附件的编码在 #21 里做；这里只发文字
            let text = message.markdownText
            if text.isEmpty { continue }
            messages.append(ChatMessage(role: message.role.rawValue, content: text))
        }
        let body = ChatRequestBody(
            model: request.modelID,
            messages: messages,
            stream: true,
            thinking: request.connection.isDeepSeek ? .init(type: "disabled") : nil
        )
        return HTTPRequest(
            method: "POST",
            url: request.connection.baseURL.appendingPathComponent("chat/completions"),
            headers: [
                "Authorization": "Bearer \(request.apiKey)",
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            ],
            body: try JSONEncoder().encode(body)
        )
    }

    // MARK: 错误映射（ARCHITECTURE §3.4）

    /// 错误体只读这么多字节。
    static let errorBodyLimit = 64 * 1024
    /// 显示给用户的原始错误信息最多这么多字符。
    static let errorMessageLimit = 2_000
    static let modelListLimit = 4 * 1024 * 1024

    private static func throwIfNotSuccess(_ response: HTTPResponse) async throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let data = try await response.collectBody(limit: errorBodyLimit)
        throw chatError(statusCode: response.statusCode, headers: response.headers, body: data)
    }

    static func chatError(statusCode: Int, headers: [String: String], body: Data) -> ChatError {
        let detail = try? JSONDecoder().decode(ErrorEnvelope.self, from: body).error
        let rawText = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var message = detail?.message ?? (rawText.isEmpty ? "HTTP \(statusCode)" : rawText)
        if message.count > errorMessageLimit { message = String(message.prefix(errorMessageLimit)) }

        // 启发式判断：DeepSeek 文档没写上下文超长时返回什么，这里按 OpenAI 的惯例
        // （code 是 context_length_exceeded，或者 message 里有 "maximum context length"）识别。
        // 还没有用真实 key 验证过。
        if statusCode == 400,
           detail?.code?.stringValue == "context_length_exceeded"
            || message.localizedCaseInsensitiveContains("maximum context length") {
            return .contextTooLong
        }

        switch statusCode {
        case 401: return .authentication
        // 402 是 DeepSeek 的余额不足；SPEC §7 把「额度用完」归到 rateLimited
        case 402: return .rateLimited(retryAfter: nil)
        case 429: return .rateLimited(retryAfter: headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 400, 422: return .invalidRequest(message)
        case 500..<600: return .overloaded
        default: return .providerError(message)
        }
    }

    /// 把其他错误统一成 ChatError；取消原样往外传。
    private static func normalize(_ error: any Error) -> any Error {
        if error is ChatError || error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        return ChatError.providerError(String(describing: error))
    }
}

// MARK: - 线上格式

private struct ChatRequestBody: Encodable {
    struct Thinking: Encodable { var type: String }

    var model: String
    var messages: [ChatMessage]
    var stream: Bool
    var thinking: Thinking?
}

private struct ChatMessage: Encodable {
    var role: String
    var content: String
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { var content: String? }
        var index: Int?
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]?
    var error: ErrorDetail?
}

private struct ErrorEnvelope: Decodable {
    var error: ErrorDetail
}

private struct ErrorDetail: Decodable {
    var message: String?
    var type: String?
    /// 有的服务是字符串，有的是数字
    var code: JSONValue?
}

private struct ModelList: Decodable {
    struct Entry: Decodable {
        var id: String
        var name: String?
        var contextWindow: Int?
        var inputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case id, name
            case contextWindow = "context_window"
            case inputModalities = "input_modalities"
        }

        /// 图片能力看 `input_modalities`，tools 视为支持，搜索一律不支持（ARCHITECTURE §3.2）。
        /// 接口没报告 `input_modalities` 时用保守默认。
        var modelInfo: ModelInfo {
            var capabilities = ModelCapabilities.conservative
            if let inputModalities { capabilities.imageInput = inputModalities.contains("image") }
            return ModelInfo(id: id, displayName: name, contextWindow: contextWindow, capabilities: capabilities)
        }
    }

    var data: [Entry]
}
