import Foundation

/// 把一次 Turn 里收到的 ModelEvent 累积成 assistant Message 的内容块（ADR-0001）。
///
/// - 正文片段接在最后一个 text 块后面；前面是别的块（例如搜索）时新开一个 text 块。
/// - Web Search 成为一个 webSearch 块。
/// - Provider 的原生块（providerData）按收到的顺序累积在**第一个**块里：`opaque(provider, [原生块…])`。
///   放在最前面，是为了不打断「正文接在最后一个 text 块后面」。adapter 回传时逐字发回。
/// - Citation 的范围由 adapter 按「这次调用输出的正文」计算，这里换算成「所在 text 块」里的偏移。
struct AnswerBuilder {
    let provider: Provider
    private var rawBlocks: [JSONValue] = []
    /// 这次调用到目前为止输出的正文长度（UTF-16）
    private var callText = 0
    /// 最后一个 text 块的开头在这次调用的偏移里是多少。块在调用开始前就有了（续接时）就是负数；
    /// 最后一个块不是 text 时为 nil。
    private var lastTextBlockStart: Int?

    init(provider: Provider) {
        self.provider = provider
    }

    /// 每次模型调用开始时调用：偏移从 0 重新计算。
    mutating func beginCall(_ answer: Message) {
        callText = 0
        if let last = answer.content.last, case .text(let text, _) = last.kind {
            lastTextBlockStart = -text.utf16.count
        } else {
            lastTextBlockStart = nil
        }
    }

    mutating func apply(_ event: ModelEvent, to answer: inout Message) {
        switch event {
        case .textDelta(let delta):
            if let last = answer.content.indices.last, case .text(let text, let citations) = answer.content[last].kind {
                answer.content[last].kind = .text(text + delta, citations: citations)
            } else {
                answer.content.append(ContentBlock(.text(delta)))
                lastTextBlockStart = callText
            }
            callText += delta.utf16.count
        case .webSearchStarted(let query):
            answer.content.append(ContentBlock(.webSearch(query: query)))
            lastTextBlockStart = nil
        case .citation(let citation, let range):
            guard let last = answer.content.indices.last, case .text(let text, var citations) = answer.content[last].kind else { return }
            var local: Range<Int>?
            if let range, let start = lastTextBlockStart {
                let shifted = (range.lowerBound - start)..<(range.upperBound - start)
                if shifted.lowerBound >= 0, shifted.upperBound <= text.utf16.count { local = shifted }
            }
            citations.append(CitationSpan(citation: citation, textRange: local))
            answer.content[last].kind = .text(text, citations: citations)
        case .providerData(_, let opaque):
            rawBlocks.append(opaque)
            let block = ContentBlock(.opaque(provider: provider, .array(rawBlocks)))
            if let first = answer.content.first, case .opaque = first.kind {
                answer.content[0] = block
            } else {
                answer.content.insert(block, at: 0)
            }
        case .toolCallStarted, .toolCallArgumentsDelta, .toolCallCompleted:
            // v1 没有 app 侧工具
            break
        case .finished:
            break
        }
    }
}
