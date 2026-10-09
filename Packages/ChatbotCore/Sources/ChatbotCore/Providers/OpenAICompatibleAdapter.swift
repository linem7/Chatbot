import Foundation

/// OpenAI 兼容 Provider 的 adapter（DeepSeek 等），ARCHITECTURE §3.2。
///
/// - 端点是 `POST {base}/chat/completions`，DeepSeek 的 base URL 不带 `/v1`。
/// - 按平台关闭思考（ADR-0002，平台见 `Platform`）：DeepSeek 发 `thinking: {type: "disabled"}`，
///   OpenRouter 发 `reasoning: {enabled: false}`，百炼发 `enable_thinking: false`；其他服务什么都不发。
/// - 不发 DeepSeek 不支持的 OpenAI 字段（`n`、`seed`、`parallel_tool_calls`、`max_completion_tokens`、`logit_bias`），
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
            messages.append(ChatMessage(role: "system", content: .text(request.systemPrompt)))
        }
        let acceptsImages = request.capabilities.imageInput
        for message in request.messages {
            switch message.role {
            case .assistant:
                let text = message.markdownText
                if text.isEmpty { continue }
                messages.append(ChatMessage(role: "assistant", content: .text(text)))
            case .user:
                let parts = userParts(message, attachments: request.attachments, acceptsImages: acceptsImages)
                if parts.isEmpty { continue }
                messages.append(ChatMessage(role: "user", content: .init(parts)))
            }
        }
        var body = ChatRequestBody(model: request.modelID, messages: messages, stream: true)
        switch request.connection.platform {
        case .deepSeek:
            body.thinking = .init(type: "disabled")
        case .openRouter:
            body.reasoning = openRouterReasoning(for: request)
        case .bailian:
            // 只会思考的模型（deepseek-r1、QwQ、QVQ、*-thinking）不接受关闭，发了可能报错
            let id = request.modelID.lowercased()
            let thinkingOnly = ["deepseek-r1", "qwq", "qvq"].contains { id.hasPrefix($0) } || id.contains("thinking")
            body.enableThinking = thinkingOnly ? nil : false
        case nil:
            break
        }
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

    static let omittedImageNote = "[图片已省略：当前模型不支持图片]"

    /// 用户 Message 按内容块的顺序编码。图片用 base64 data URL；Model 不接受图片时换成占位文字（SPEC §4，
    /// 界面另有提示）。文本和 PDF 附件作为文字块，前面加上文件名（ARCHITECTURE §6）。
    private static func userParts(_ message: Message, attachments: [UUID: Attachment], acceptsImages: Bool) -> [ContentPart] {
        message.content.compactMap { block in
            switch block.kind {
            case .text(let text, _):
                return text.isEmpty ? nil : .text(text)
            case .attachmentRef(let id):
                // 附件副本找不到（例如被手动删了）时略过
                guard let attachment = attachments[id] else { return nil }
                switch attachment.content {
                case .image(let data, let mediaType):
                    // 不接受图片时留一段占位文字：模型知道这里本来有图，只有图片的 Message 也不会整条消失
                    return acceptsImages ? .imageURL("data:\(mediaType);base64,\(data.base64EncodedString())") : .text(Self.omittedImageNote)
                case .text(let text):
                    return .text("附件 \(attachment.originalName)：\n\(text)")
                }
            default:
                return nil
            }
        }
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

    /// OpenRouter 的统一 `reasoning` 参数，按 `/models` 报告的 `reasoning` 对象（存在 providerData 里）决定：
    /// - `mandatory` 的模型关不掉思考，发 `enabled: false` 会被拒绝，改发它支持的最低档 effort；没有档位可选就什么都不发。
    /// - 其他模型发 `enabled: false`。
    /// - 没有 `reasoning` 信息（#53 之前保存的 Connection，或者这个模型不会思考）：只给 DeepSeek 发 `enabled: false`
    ///   （OpenRouter 上的 DeepSeek 都能关），其他模型什么都不发，免得关不掉思考的模型被拒；重新拉取 Model 列表后按上面处理。
    private static func openRouterReasoning(for request: ModelRequest) -> ChatRequestBody.Reasoning? {
        guard let reasoning = request.connection.models.first(where: { $0.id == request.modelID })?.providerData?["reasoning"] else {
            return request.modelID.lowercased().hasPrefix("deepseek/") ? .init(enabled: false) : nil
        }
        guard reasoning["mandatory"]?.boolValue == true else { return .init(enabled: false) }
        guard case .array(let efforts)? = reasoning["supported_efforts"] else { return nil }
        let supported = Set(efforts.compactMap(\.stringValue))
        return openRouterEffortsFromLowest.first(where: supported.contains).map { .init(effort: $0) }
    }

    /// OpenRouter 的 effort 档位，从低到高（`none` 是关闭，关不掉思考的模型不接受）。接口没有承诺 `supported_efforts` 的顺序。
    private static let openRouterEffortsFromLowest = ["minimal", "low", "medium", "high", "xhigh", "max"]

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
    struct Reasoning: Encodable {
        var enabled: Bool?
        var effort: String?
    }

    var model: String
    var messages: [ChatMessage]
    var stream: Bool
    /// DeepSeek 官方
    var thinking: Thinking?
    /// OpenRouter
    var reasoning: Reasoning?
    /// 百炼
    var enableThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, thinking, reasoning
        case enableThinking = "enable_thinking"
    }
}

private struct ChatMessage: Encodable {
    var role: String
    var content: Content

    /// 只有文字时发字符串，有图片时发 content parts 数组。
    enum Content: Encodable {
        case text(String)
        case parts([ContentPart])

        init(_ parts: [ContentPart]) {
            let texts = parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            self = texts.count == parts.count ? .text(texts.joined(separator: "\n\n")) : .parts(parts)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }
}

private enum ContentPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageURL: Encodable { var url: String }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }
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
        /// OpenRouter 报告的思考选项（`mandatory`、`supported_efforts` 等），存进 providerData，关闭思考时用
        var reasoning: JSONValue?

        enum CodingKeys: String, CodingKey {
            case id, name, reasoning
            case contextWindow = "context_window"
            case inputModalities = "input_modalities"
        }

        /// 图片能力看 `input_modalities`，tools 视为支持，搜索一律不支持（ARCHITECTURE §3.2）。
        /// 接口没报告 `input_modalities` 时用保守默认。
        var modelInfo: ModelInfo {
            var capabilities = ModelCapabilities.conservative
            if let inputModalities { capabilities.imageInput = inputModalities.contains("image") }
            let providerData: JSONValue? = reasoning.flatMap { $0 == .null ? nil : .object(["reasoning": $0]) }
            return ModelInfo(id: id, displayName: name, contextWindow: contextWindow, capabilities: capabilities, providerData: providerData)
        }
    }

    var data: [Entry]
}
