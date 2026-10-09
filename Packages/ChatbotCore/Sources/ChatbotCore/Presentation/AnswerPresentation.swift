import Foundation

/// 一条回答怎么显示（SPEC §5）：带角标的正文、来源列表、搜索状态、Gemini 的搜索建议。
///
/// 只做字符串处理，不依赖 UI，所以放在 ChatbotCore 里测试；App 侧（Quick Panel 和 Main Window 共用的 MessageRow）只负责渲染。
public struct AnswerPresentation: Equatable, Sendable {
    public struct Source: Equatable, Sendable, Identifiable {
        public var number: Int
        public var title: String
        /// 显示在标题旁边的域名（去掉 www.）。
        public var domain: String
        public var url: URL

        public var id: Int { number }

        public init(number: Int, title: String, domain: String, url: URL) {
            self.number = number
            self.title = title
            self.domain = domain
            self.url = url
        }
    }

    public enum SearchStatus: Equatable, Sendable {
        /// 搜索中：「正在搜索：关键词」
        case searching(query: String)
        /// 正文开始输出后：一行灰字「搜索了：A、B」
        case searched(queries: [String])
    }

    /// 正文，引用处插入了角标链接 `[1]`，点击用默认浏览器打开来源。
    public var markdown: String
    /// 「复制」用的 Markdown 原文，不含角标（SPEC §6）。
    public var copyText: String
    /// 回答末尾的来源列表，按角标编号排列。
    public var sources: [Source]
    public var searchStatus: SearchStatus?
    /// Gemini 的「搜索建议」组件（HTML 和 CSS），按条款必须原样展示。
    public var searchSuggestionHTML: String?

    public init(_ message: Message) {
        var numbers: [URL: Int] = [:]
        var sources: [Source] = []
        func number(for citation: Citation) -> Int {
            if let number = numbers[citation.url] { return number }
            let number = sources.count + 1
            numbers[citation.url] = number
            sources.append(Source(number: number, title: citation.title, domain: Self.domain(of: citation), url: citation.url))
            return number
        }

        var markdown = ""
        var queries: [String] = []
        var suggestion: String?
        for block in message.content {
            switch block.kind {
            case .text(let text, let citations):
                // 同一个位置可能有多个来源：[1][2]
                var markers: [Int: [Int]] = [:]
                for span in citations {
                    let n = number(for: span.citation)
                    guard let range = span.textRange, range.upperBound <= text.utf16.count else { continue }
                    let offset = Self.markerOffset(for: range, in: text)
                    guard !Self.isInsideCode(text, utf16Offset: offset) else { continue }
                    if markers[offset, default: []].contains(n) == false {
                        markers[offset, default: []].append(n)
                    }
                }
                markdown += Self.insert(markers, into: text, sources: sources)
            case .webSearch(let query):
                if !queries.contains(query) { queries.append(query) }
            case .opaque(.gemini, .array(let raw)):
                for item in raw {
                    if let html = item["groundingMetadata"]?["searchEntryPoint"]?["renderedContent"]?.stringValue { suggestion = html }
                }
            default:
                break
            }
        }

        self.markdown = markdown
        copyText = message.markdownText
        self.sources = sources
        searchSuggestionHTML = suggestion

        // 还在生成、并且最后一块是搜索：正在搜索；否则有搜索过就显示「搜索了」
        let lastVisible = message.content.last { if case .opaque = $0.kind { false } else { true } }
        if message.status == .streaming, case .webSearch(let query)? = lastVisible?.kind {
            searchStatus = .searching(query: query)
        } else {
            searchStatus = queries.isEmpty ? nil : .searched(queries: queries)
        }
    }

    /// 在 UTF-16 偏移处插入角标链接，从后往前插，前面的偏移不受影响。
    private static func insert(_ markers: [Int: [Int]], into text: String, sources: [Source]) -> String {
        var result = text
        for (offset, numbers) in markers.sorted(by: { $0.key > $1.key }) {
            let links = numbers.map { n in "[\\[\(n)\\]](<\(sources[n - 1].url.absoluteString)>)" }.joined()
            let index = String.Index(utf16Offset: offset, in: result)
            result.insert(contentsOf: links, at: index)
        }
        return result
    }

    /// 角标的位置：引用范围的结尾，但跳过末尾的空白和换行。范围以换行结尾时，
    /// 角标如果插在下一行行首，会破坏「## 标题」「- 列表项」这类行首语法。
    private static func markerOffset(for range: Range<Int>, in text: String) -> Int {
        let utf16 = Array(text.utf16)
        var offset = range.upperBound
        while offset > range.lowerBound, let scalar = Unicode.Scalar(utf16[offset - 1]),
              scalar.properties.isWhitespace {
            offset -= 1
        }
        return offset
    }

    /// 偏移处是不是在代码里：代码块（``` 或 ~~~ 围栏）或者行内代码（同一行前面有奇数个反引号）。代码里不插角标。
    private static func isInsideCode(_ text: String, utf16Offset: Int) -> Bool {
        let prefix = String(text.utf16.prefix(utf16Offset)) ?? ""
        var lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        let currentLine = lines.popLast() ?? ""

        // 围栏：开头是 ``` 或 ~~~，要用同一种字符结束
        var openFence: Character?
        for line in lines + [currentLine] {
            let trimmed = line.drop { $0 == " " }
            guard let first = trimmed.first, first == "`" || first == "~", trimmed.prefix(3).allSatisfy({ $0 == first }),
                  trimmed.count >= 3
            else { continue }
            if openFence == nil { openFence = first } else if openFence == first { openFence = nil }
        }
        if openFence != nil { return true }

        return currentLine.filter { $0 == "`" }.count % 2 == 1
    }

    /// 来源旁边显示的域名。Gemini 的来源链接都是 vertexaisearch 的跳转地址，这时标题本身就是网站的域名。
    private static func domain(of citation: Citation) -> String {
        guard let host = citation.url.host?.lowercased() else { return citation.title }
        if host.hasSuffix("vertexaisearch.cloud.google.com") { return citation.title }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
