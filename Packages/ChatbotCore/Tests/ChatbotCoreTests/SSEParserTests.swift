import ChatbotCore
import Testing

/// 标了「WHATWG 示例」的用例，输入取自规范原文：
/// https://html.spec.whatwg.org/multipage/server-sent-events.html
/// 其余用例是根据规范和 ARCHITECTURE §3.3 自己构造的，不是官方原文。
struct SSEParserTests {
    private func parse(_ text: String) -> [SSEEvent] {
        parse(chunks: [text])
    }

    private func parse(chunks: [String]) -> [SSEEvent] {
        parse(byteChunks: chunks.map { Array($0.utf8) })
    }

    private func parse(byteChunks: [[UInt8]]) -> [SSEEvent] {
        var parser = SSEParser()
        return byteChunks.flatMap { parser.push($0) } + parser.finish()
    }

    // MARK: WHATWG 示例

    @Test func multipleDataLinesAreJoinedWithNewline() {
        let events = parse("data: YHOO\ndata: +2\ndata: 10\n\n")
        #expect(events == [SSEEvent(data: "YHOO\n+2\n10")])
    }

    @Test func namedEventsCarryTheirType() {
        let events = parse("event: add\ndata: 73857293\n\nevent: remove\ndata: 2153\n\nevent: add\ndata: 113411\n\n")
        #expect(events == [
            SSEEvent(event: "add", data: "73857293"),
            SSEEvent(event: "remove", data: "2153"),
            SSEEvent(event: "add", data: "113411"),
        ])
    }

    @Test func commentsIDsAndOnlyOneLeadingSpaceIsStripped() {
        let events = parse(": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n")
        // 第三个事件后面没有空行，不派发
        #expect(events == [
            SSEEvent(data: "first event", id: "1"),
            SSEEvent(data: "second event", id: ""),
        ])
    }

    @Test func emptyDataFieldsStillDispatch() {
        let events = parse("data\n\ndata\ndata\n\ndata:")
        #expect(events == [SSEEvent(data: ""), SSEEvent(data: "\n")])
    }

    @Test func spaceAfterColonIsOptional() {
        let events = parse("data:test\n\ndata: test\n\n")
        #expect(events == [SSEEvent(data: "test"), SSEEvent(data: "test")])
    }

    // MARK: 行尾和分块

    @Test func crlfAndBareCRAreLineEndings() {
        let events = parse("data: a\r\n\r\ndata: b\r\rdata: c\n\n")
        #expect(events == [SSEEvent(data: "a"), SSEEvent(data: "b"), SSEEvent(data: "c")])
    }

    @Test func crlfSplitAcrossChunksIsOneLineEnding() {
        // 如果把 `\r` 和后面的 `\n` 当成两个行尾，会多出一个空行，提前派发一个空事件
        let events = parse(chunks: ["data: a\r", "\ndata: b\r", "\n\r", "\n"])
        #expect(events == [SSEEvent(data: "a\nb")])
    }

    @Test func lineSplitInsideMultibyteCharacter() {
        let bytes = Array("data: 你好\n\n".utf8)
        // 从「你」的三个字节中间切开
        let events = parse(byteChunks: [Array(bytes[..<7]), Array(bytes[7...])])
        #expect(events == [SSEEvent(data: "你好")])
    }

    @Test func leadingByteOrderMarkIsIgnored() {
        let events = parse(byteChunks: [[0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)])
        #expect(events == [SSEEvent(data: "x")])
    }

    // MARK: Provider 相关

    @Test func deepSeekKeepAliveCommentsAreIgnored() {
        // DeepSeek 排队时会持续发送 `: keep-alive`（https://api-docs.deepseek.com/quick_start/rate_limit）
        let events = parse(": keep-alive\n\n: keep-alive\n\ndata: {\"x\":1}\n\n")
        #expect(events == [SSEEvent(data: "{\"x\":1}")])
    }

    @Test func unknownFieldsAreIgnored() {
        let events = parse("retry: 1000\nfoo: bar\ndata: x\n\n")
        #expect(events == [SSEEvent(data: "x")])
    }

    @Test func asyncByteSequenceYieldsEvents() async throws {
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in "data: a\n\n: keep-alive\n\ndata: [DONE]\n\n".utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        var events: [SSEEvent] = []
        for try await event in bytes.sseEvents() { events.append(event) }
        #expect(events == [SSEEvent(data: "a"), SSEEvent(data: "[DONE]")])
    }
}
