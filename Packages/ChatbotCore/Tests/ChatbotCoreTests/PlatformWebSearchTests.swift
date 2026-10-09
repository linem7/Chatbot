@testable import ChatbotCore
import Foundation
import Testing

/// OpenRouter 和百炼的平台联网（ADR-0003，#54）。
///
/// 流里的 annotation 按 research 附录 A.1、A.2 的形状构造（官方只给了非流式示例，和官方 SDK 测试里只带 url 的流式 chunk），
/// 不是真实响应的原文；偏移的单位和开闭区间要在真机上核对。
struct PlatformWebSearchTests {
    private func connection(_ baseURL: String, provider: Provider = .openAICompatible, models: [ModelInfo] = []) -> Connection {
        Connection(name: "平台", provider: provider, baseURL: URL(string: baseURL)!, models: models)
    }

    private func request(_ connection: Connection, webSearch: Bool, modelID: String = "deepseek/deepseek-v4.1-flash") -> ModelRequest {
        ModelRequest(
            connection: connection,
            apiKey: "sk-test",
            modelID: modelID,
            systemPrompt: "",
            messages: [.user("今天的新闻")],
            webSearch: webSearch
        )
    }

    private func chunk(_ delta: String, finishReason: String? = nil) -> String {
        let finish = finishReason.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\": [{\"index\": 0, \"delta\": \(delta), \"finish_reason\": \(finish)}]}\n\n"
    }

    private func content(_ text: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return chunk("{\"content\": \(escaped)}")
    }

    private func sentFields(_ request: ModelRequest) async throws -> [String: JSONValue] {
        let transport = StubTransport(body: chunk("{}", finishReason: "stop"))
        for try await _ in OpenAICompatibleAdapter(transport: transport).stream(request) {}
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return [:] }
        return fields
    }

    private func events(_ body: String) async throws -> [ModelEvent] {
        let adapter = OpenAICompatibleAdapter(transport: StubTransport(body: body))
        var events: [ModelEvent] = []
        for try await event in adapter.stream(request(connection("https://openrouter.ai/api/v1"), webSearch: true)) {
            events.append(event)
        }
        return events
    }

    private func citations(_ events: [ModelEvent]) -> [(Citation, Range<Int>?)] {
        events.compactMap {
            if case .citation(let citation, let range) = $0 { return (citation, range) }
            return nil
        }
    }

    // MARK: 请求体

    @Test func openRouterAddsTheWebSearchServerTool() async throws {
        let fields = try await sentFields(request(connection("https://openrouter.ai/api/v1"), webSearch: true))
        #expect(fields["tools"] == .array([.object(["type": .string("openrouter:web_search")])]))
        #expect(fields["enable_search"] == nil)
        // 关闭思考照常发（#53）
        #expect(fields["reasoning"] == .object(["enabled": .bool(false)]))
    }

    @Test func bailianSendsEnableSearch() async throws {
        let fields = try await sentFields(request(
            connection("https://dashscope.aliyuncs.com/compatible-mode/v1"), webSearch: true, modelID: "deepseek-v4-flash"
        ))
        #expect(fields["enable_search"] == .bool(true))
        #expect(fields["tools"] == nil)
        #expect(fields["enable_thinking"] == .bool(false))
    }

    @Test(arguments: [
        "https://openrouter.ai/api/v1",
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
    ])
    func searchSwitchedOffSendsNoSearchFields(baseURL: String) async throws {
        let fields = try await sentFields(request(connection(baseURL), webSearch: false))
        #expect(fields["tools"] == nil)
        #expect(fields["enable_search"] == nil)
    }

    @Test(arguments: [
        "https://eu.openrouter.ai/api/v1",
        "https://api.deepseek.com",
        "https://api.openai.com/v1",
        "https://relay.example.com/v1",
    ])
    func platformsWithoutServerSearchNeverSendSearchFields(baseURL: String) async throws {
        // request.webSearch 正常不会是 true（能力是 false），这里确认 adapter 自己也不会发
        let fields = try await sentFields(request(connection(baseURL), webSearch: true))
        #expect(fields["tools"] == nil)
        #expect(fields["enable_search"] == nil)
    }

    // MARK: 能力

    @Test func everyModelOnASearchingPlatformCanSearch() {
        // #54 之前保存的 Connection：缓存的能力里没有搜索，也不用重新拉取
        let old = [ModelInfo(id: "deepseek/deepseek-v4.1-flash", capabilities: .conservative)]
        #expect(connection("https://openrouter.ai/api/v1", models: old).capabilities(ofModel: "deepseek/deepseek-v4.1-flash").webSearch)
        #expect(connection("https://openrouter.ai/api/v1").capabilities(ofModel: "any/model").webSearch)
        #expect(connection("https://us.openrouter.ai/api/v1").capabilities(ofModel: "any/model").webSearch)
        #expect(connection("https://dashscope.aliyuncs.com/compatible-mode/v1").capabilities(ofModel: "deepseek-v4-flash").webSearch)

        #expect(!connection("https://eu.openrouter.ai/api/v1").capabilities(ofModel: "any/model").webSearch)
        #expect(!connection("https://api.deepseek.com").capabilities(ofModel: "deepseek-flash").webSearch)
        #expect(!connection("https://relay.example.com/v1").capabilities(ofModel: "gpt-x").webSearch)
        // 走 Anthropic 原生格式的 OpenRouter Connection 由 Anthropic adapter 自己判断，这里不改
        #expect(!connection("https://openrouter.ai/api", provider: .anthropic).capabilities(ofModel: "anthropic/claude").webSearch)
    }

    @Test func openRouterModelListReportsImagesContextAndSearch() async throws {
        // Fixtures/openrouter-models.json：2026-10-09 无鉴权请求 https://openrouter.ai/api/v1/models 的结果，只留了三个模型和几个字段
        let models = try await OpenAICompatibleAdapter(transport: StubTransport(body: try Fixture.string("openrouter-models.json")))
            .listModels(connection("https://openrouter.ai/api/v1"), apiKey: "sk-test")
        let flash = try #require(models.first { $0.id == "deepseek/deepseek-v4.1-flash" })
        #expect(flash.capabilities.imageInput)
        #expect(flash.capabilities.webSearch)
        #expect(flash.contextWindow == 1_048_576)
        let v32 = try #require(models.first { $0.id == "deepseek/deepseek-v3.2" })
        #expect(!v32.capabilities.imageInput)
        #expect(v32.contextWindow == 163_840)

        let eu = try await OpenAICompatibleAdapter(transport: StubTransport(body: try Fixture.string("openrouter-models.json")))
            .listModels(connection("https://eu.openrouter.ai/api/v1"), apiKey: "sk-test")
        #expect(eu.allSatisfy { !$0.capabilities.webSearch })
    }

    // MARK: 流里的 annotations

    @Test func citationArrivingAfterTheTextPointsAtTheWholeMarkdownLink() async throws {
        let before = "据报道，"
        let link = "[新华网](https://www.example.cn/news/1)"
        let after = "今天北京下雨。"
        let text = before + link + after
        // 偏移按 Unicode 标量、闭区间给（单位故意和 UTF-16 不同）
        let start = before.unicodeScalars.count
        let end = start + link.unicodeScalars.count - 1
        let annotation = """
            {"annotations": [{"type": "url_citation", "url_citation": {"url": "https://www.example.cn/news/1", \
            "title": "北京今天下雨", "content": "摘录 [...] 摘录", "start_index": \(start), "end_index": \(end)}}]}
            """
        let body = content(before) + content(link + after) + chunk(annotation) + chunk("{}", finishReason: "stop")
        let events = try await events(body)

        let found = citations(events)
        #expect(found.count == 1)
        #expect(found.first?.0 == Citation(title: "北京今天下雨", url: URL(string: "https://www.example.cn/news/1")!))
        let range = try #require(found.first?.1)
        #expect(String(decoding: Array(text.utf16)[range], as: UTF16.self) == link)
        // 引用排在正文之后、finished 之前
        #expect(events.last == .finished(.stop))
        #expect(events.dropLast().last.map { if case .citation = $0 { true } else { false } } == true)
    }

    @Test func annotationInTheSameChunkAsTextIsCollected() async throws {
        let link = "[example.com](https://example.com/page)"
        let delta = """
            {"content": "See \(link).", "annotations": [{"type": "url_citation", \
            "url_citation": {"url": "https://example.com/page", "title": "Example", "start_index": 4, "end_index": \(4 + link.utf16.count)}}]}
            """
        let found = citations(try await events(chunk(delta) + chunk("{}", finishReason: "stop")))
        #expect(found.map { $0.1 } == [4..<(4 + link.utf16.count)])
    }

    @Test func urlOnlyAnnotationIsLocatedByItsURL() async throws {
        // research 附录 A.2：官方 SDK 测试里只带 url 的流式 chunk
        let text = "结果见 [来源](https://example.com/page)。"
        let body = content(text)
            + chunk(#"{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/page"}}]}"#)
            + chunk("{}", finishReason: "stop")
        let found = citations(try await events(body))
        #expect(found.count == 1)
        #expect(found.first?.0.title == "example.com")
        let range = try #require(found.first?.1)
        #expect(range.upperBound == text.utf16.count - 1)  // 到链接的 ) 为止，不含句号
    }

    @Test func repeatedAnnotationsAreKeptOnce() async throws {
        let annotation = #"{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"A"}}]}"#
        let body = content("见 https://example.com/a") + chunk(annotation) + chunk(annotation) + chunk("{}", finishReason: "stop")
        #expect(citations(try await events(body)).count == 1)
    }

    @Test func malformedAnnotationsDoNotDropTheText() async throws {
        let body = chunk(#"{"content": "你好", "annotations": [{"type": "url_citation"}, {"type": "file_citation", "x": 1}, 42]}"#)
            + chunk("{}", finishReason: "stop")
        let events = try await events(body)
        #expect(events.first == .textDelta("你好"))
        #expect(citations(events).isEmpty)
    }

    // MARK: URLCitationLocator

    @Test func sourceNotInTheTextIsLocatedByItsDomain() {
        let text = "据 example.com 报道，今天下雨。"
        let start = "据 ".utf16.count
        let end = start + "example.com".utf16.count - 1  // 闭区间
        let range = URLCitationLocator.range(start: start, end: end, url: "https://www.example.com/a", in: text)
        #expect(range == start..<(end + 1))
    }

    @Test func noRangeWhenNeitherURLNorDomainMatches() {
        let range = URLCitationLocator.range(start: 0, end: 3, url: "https://example.com/a", in: "今天下雨。")
        #expect(range == nil)
        #expect(URLCitationLocator.range(start: nil, end: nil, url: "https://example.com/a", in: "今天下雨。") == nil)
    }

    @Test func nearestOccurrenceWinsWhenTheURLAppearsTwice() {
        let link = "[a](https://example.com/a)"
        let text = link + " 中间的文字 " + link
        let second = text.utf16.count - link.utf16.count
        #expect(URLCitationLocator.range(start: second, end: text.utf16.count - 1, url: "https://example.com/a", in: text)
            == second..<text.utf16.count)
    }

    /// 中文回答里常见「来源：URL。」：URL 后面直接跟中文标点，GFM 的扩展自动链接会把后面的字符一起吞进链接，
    /// 角标插在这里会变成链接的一部分。所以裸 URL 不标角标。
    @Test func bareURLFollowedByChinesePunctuationGetsNoMarker() {
        let text = "今天北京下雨（来源：https://example.com/a。）"
        let start = "今天北京下雨（来源：".utf16.count
        let end = start + "https://example.com/a".utf16.count - 1
        #expect(URLCitationLocator.range(start: start, end: end, url: "https://example.com/a", in: text) == nil)
        #expect(URLCitationLocator.range(start: nil, end: nil, url: "https://example.com/a", in: text) == nil)
    }

    /// 来源是 /x、正文里的链接是 /x/y：不能当成命中，更不能把角标插到 URL 中间。
    @Test func longerURLInTheTextIsNotAMatch() {
        let text = "参考 [文档](https://example.com/x/y) 。"
        let start = "参考 ".utf16.count
        let close = text.utf16.count - 3  // ) 的位置
        #expect(URLCitationLocator.range(start: nil, end: nil, url: "https://example.com/x", in: text) == nil)
        // 有偏移时只可能停在整个链接之后，不会停在 URL 中间
        let range = URLCitationLocator.range(start: start, end: close, url: "https://example.com/x", in: text)
        #expect(range == nil || range?.upperBound == close + 1)
    }

    @Test func angleBracketDestinationEndsAfterTheClosingParenthesis() {
        let link = "[文档](<https://example.com/a b>)"
        let text = "参考 " + link + "。"
        let range = URLCitationLocator.range(start: nil, end: nil, url: "https://example.com/a b", in: text)
        #expect(range == "参考 ".utf16.count..<("参考 " + link).utf16.count)
    }

    @Test func autolinkEndsAfterTheClosingBracket() {
        let text = "见 <https://example.com/a> 。"
        let range = URLCitationLocator.range(start: nil, end: nil, url: "https://example.com/a", in: text)
        #expect(range?.upperBound == "见 <https://example.com/a>".utf16.count)
    }
}
