import ChatbotCore
import Foundation
import Testing

/// 回答的显示方式（SPEC §5）：角标、来源列表、搜索状态、Gemini 的搜索建议。
struct AnswerPresentationTests {
    private let wiki = Citation(title: "Claude Shannon - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Claude_Shannon")!)
    private let britannica = Citation(title: "Britannica", url: URL(string: "https://www.britannica.com/biography/Claude-Shannon")!)

    private func answer(_ blocks: [ContentBlock], status: MessageStatus = .complete) -> AnswerPresentation {
        AnswerPresentation(Message(role: .assistant, status: status, content: blocks))
    }

    @Test func citationMarkersAreInsertedAtTheEndOfTheCitedTextAndNumberedBySource() {
        let first = "Shannon was born in 1916."
        let second = " He founded information theory."
        let presentation = answer([
            ContentBlock(.text(first + second, citations: [
                CitationSpan(citation: wiki, textRange: 0..<first.utf16.count),
                CitationSpan(citation: britannica, textRange: 0..<first.utf16.count),
                CitationSpan(citation: wiki, textRange: first.utf16.count..<(first + second).utf16.count),
            ])),
        ])
        #expect(presentation.markdown ==
            "Shannon was born in 1916.[\\[1\\]](<https://en.wikipedia.org/wiki/Claude_Shannon>)[\\[2\\]](<https://www.britannica.com/biography/Claude-Shannon>)"
            + " He founded information theory.[\\[1\\]](<https://en.wikipedia.org/wiki/Claude_Shannon>)")
        #expect(presentation.sources == [
            .init(number: 1, title: "Claude Shannon - Wikipedia", domain: "en.wikipedia.org", url: wiki.url),
            .init(number: 2, title: "Britannica", domain: "britannica.com", url: britannica.url),
        ])
    }

    @Test func offsetsAreUTF16AndWorkWithChineseAndEmoji() {
        let cited = "🌤️ 东京今天晴。"
        let presentation = answer([
            ContentBlock(.text(cited + "明天有雨。", citations: [CitationSpan(citation: wiki, textRange: 0..<cited.utf16.count)])),
        ])
        #expect(presentation.markdown == cited + "[\\[1\\]](<https://en.wikipedia.org/wiki/Claude_Shannon>)明天有雨。")
    }

    @Test func citationsWithoutARangeOnlyAppearInTheSourceList() {
        let presentation = answer([ContentBlock(.text("答案", citations: [CitationSpan(citation: wiki, textRange: nil)]))])
        #expect(presentation.markdown == "答案")
        #expect(presentation.sources.map(\.number) == [1])
    }

    @Test func noMarkerInsideCodeBlocks() {
        let text = "看代码：\n```swift\nprint(1)\n```\n结束"
        let inside = text.utf16.count - "\n```\n结束".utf16.count
        let presentation = answer([
            ContentBlock(.text(text, citations: [CitationSpan(citation: wiki, textRange: 0..<inside)])),
        ])
        #expect(presentation.markdown == text)
        #expect(presentation.sources.count == 1)
    }

    @Test func markersStayOnTheCitedLineWhenTheRangeEndsWithANewline() {
        // 范围以换行结尾时，角标要插在换行之前，不能落到下一行行首、破坏「## 标题」「- 列表项」这类语法
        let text = "第一段的结论。\n\n## 下一节\n- 列表项"
        let cited = "第一段的结论。\n\n"
        let presentation = answer([ContentBlock(.text(text, citations: [CitationSpan(citation: wiki, textRange: 0..<cited.utf16.count)]))])
        #expect(presentation.markdown == "第一段的结论。[\\[1\\]](<https://en.wikipedia.org/wiki/Claude_Shannon>)\n\n## 下一节\n- 列表项")
    }

    @Test(arguments: [
        // ~~~ 围栏
        ("看代码：\n~~~\nlet x = 1\n~~~\n结束", "let x = 1"),
        // 行内代码
        ("运行 `swift build` 就行", "swift build"),
    ])
    func noMarkerInsideTildeFencesOrInlineCode(text: String, citedEnd: String) {
        let end = text.range(of: citedEnd)!.upperBound.utf16Offset(in: text)
        let presentation = answer([ContentBlock(.text(text, citations: [CitationSpan(citation: wiki, textRange: 0..<end)]))])
        #expect(presentation.markdown == text)
        #expect(presentation.sources.count == 1)
    }

    @Test func markersAfterClosedInlineCodeAreFine() {
        let text = "运行 `swift build` 就行。"
        let presentation = answer([ContentBlock(.text(text, citations: [CitationSpan(citation: wiki, textRange: 0..<text.utf16.count)]))])
        #expect(presentation.markdown == text + "[\\[1\\]](<https://en.wikipedia.org/wiki/Claude_Shannon>)")
    }

    @Test func markersGoIntoTheirOwnTextBlocksAndTheCopyTextStaysOriginal() {
        let presentation = answer([
            ContentBlock(.text("先说一句。")),
            ContentBlock(.webSearch(query: "天气")),
            ContentBlock(.text("晴。", citations: [CitationSpan(citation: wiki, textRange: 0..<2)])),
        ])
        #expect(presentation.markdown == "先说一句。晴。[\\[1\\]](<https://en.wikipedia.org/wiki/Claude_Shannon>)")
        #expect(presentation.copyText == "先说一句。晴。")
    }

    @Test func searchStatusWhileSearchingAndAfterTheAnswerStarts() {
        let searching = answer([ContentBlock(.text("我查一下。")), ContentBlock(.webSearch(query: "东京天气"))], status: .streaming)
        #expect(searching.searchStatus == .searching(query: "东京天气"))

        let answering = answer([
            ContentBlock(.webSearch(query: "东京天气")),
            ContentBlock(.webSearch(query: "東京 天気")),
            ContentBlock(.text("晴")),
        ], status: .streaming)
        #expect(answering.searchStatus == .searched(queries: ["东京天气", "東京 天気"]))

        // 完成后，即使最后一块是搜索（Gemini 的搜索词可能最后才到），也显示「搜索了」
        let done = answer([ContentBlock(.text("晴")), ContentBlock(.webSearch(query: "东京天气"))])
        #expect(done.searchStatus == .searched(queries: ["东京天气"]))

        #expect(answer([ContentBlock(.text("晴"))]).searchStatus == nil)
    }

    @Test func repeatedQueriesAreShownOnce() {
        let presentation = answer([ContentBlock(.webSearch(query: "q")), ContentBlock(.webSearch(query: "q")), ContentBlock(.text("a"))])
        #expect(presentation.searchStatus == .searched(queries: ["q"]))
    }

    @Test func geminiSearchSuggestionComesFromTheOpaqueBlock() {
        let raw: JSONValue = .array([
            .object(["text": .string("晴")]),
            .object(["groundingMetadata": .object(["searchEntryPoint": .object(["renderedContent": .string("<div>建议</div>")])])]),
        ])
        let presentation = answer([ContentBlock(.opaque(provider: .gemini, raw)), ContentBlock(.text("晴"))])
        #expect(presentation.searchSuggestionHTML == "<div>建议</div>")
        #expect(answer([ContentBlock(.text("晴"))]).searchSuggestionHTML == nil)
    }

    @Test func geminiRedirectLinksShowTheTitleAsTheDomain() {
        // Gemini 的来源链接都是 vertexaisearch 的跳转地址，标题本身就是网站的域名
        let gemini = Citation(title: "aljazeera.com", url: URL(string: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/abc")!)
        let presentation = answer([ContentBlock(.text("a", citations: [CitationSpan(citation: gemini, textRange: 0..<1)]))])
        #expect(presentation.sources == [.init(number: 1, title: "aljazeera.com", domain: "aljazeera.com", url: gemini.url)])
    }
}
