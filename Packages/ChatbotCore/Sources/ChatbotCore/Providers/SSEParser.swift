/// 一个 Server-Sent Events 事件。
public struct SSEEvent: Equatable, Sendable {
    /// `event:` 字段；没有时为 nil（规范里的默认类型是 "message"）。
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// 按 WHATWG 规则把字节流解析成 SSE 事件（ARCHITECTURE §3.3）。
///
/// 自己按字节切行，不用 `AsyncBytes.lines`：它会吞掉空行，而 SSE 靠空行分隔事件。
/// 行尾可以是 `\n`、`\r` 或 `\r\n`，`\r\n` 被拆在两次 `push` 之间也能正确处理。
/// 以 `:` 开头的注释行（例如 DeepSeek 的 `: keep-alive`）和未知字段都直接忽略。
/// https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastByteWasCR = false
    private var sawFirstLine = false

    private var eventType: String?
    private var dataLines: [String] = []
    private var hasData = false
    private var lastEventID: String?

    public init() {}

    /// 喂入一段字节，返回这段字节里完成的事件。
    public mutating func push(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\n"):
                if lastByteWasCR {
                    // `\r\n` 的后半个，行已经在 `\r` 处结束了
                    lastByteWasCR = false
                    continue
                }
                endLine(into: &events)
            case UInt8(ascii: "\r"):
                endLine(into: &events)
                lastByteWasCR = true
            default:
                lastByteWasCR = false
                line.append(byte)
            }
        }
        return events
    }

    /// 流结束。规范规定：末尾没有以空行结束的事件不派发，所以总是返回空数组；
    /// 保留这个方法，是为了让调用方明确地重置状态。
    public mutating func finish() -> [SSEEvent] {
        self = SSEParser()
        return []
    }

    private mutating func endLine(into events: inout [SSEEvent]) {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if !sawFirstLine {
            sawFirstLine = true
            // 流开头的 UTF-8 BOM 要去掉
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }

        if bytes.isEmpty {
            dispatch(into: &events)
            return
        }
        if bytes.first == UInt8(ascii: ":") { return }

        let field: String
        let value: String
        if let colon = bytes.firstIndex(of: UInt8(ascii: ":")) {
            field = String(decoding: bytes[..<colon], as: UTF8.self)
            var valueStart = bytes.index(after: colon)
            if valueStart < bytes.endIndex, bytes[valueStart] == UInt8(ascii: " ") {
                valueStart = bytes.index(after: valueStart)
            }
            value = String(decoding: bytes[valueStart...], as: UTF8.self)
        } else {
            field = String(decoding: bytes, as: UTF8.self)
            value = ""
        }

        switch field {
        case "event":
            eventType = value
        case "data":
            dataLines.append(value)
            hasData = true
        case "id":
            if !value.contains("\0") { lastEventID = value }
        default:
            // `retry` 和未知字段：我们不做自动重连，一律忽略
            break
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer {
            eventType = nil
            dataLines.removeAll()
            hasData = false
        }
        guard hasData else { return }
        events.append(SSEEvent(event: eventType, data: dataLines.joined(separator: "\n"), id: lastEventID))
    }
}

extension AsyncSequence where Element == UInt8 {
    /// 把任意字节序列（例如 `URLSession.AsyncBytes`）解析成 SSE 事件序列。
    public func sseEvents() -> SSEEventSequence<Self> {
        SSEEventSequence(base: self)
    }
}

/// `sseEvents()` 返回的序列。不额外开 Task，取消随调用方的迭代一起生效。
public struct SSEEventSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = SSEEvent

    let base: Base

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var parser = SSEParser()
        var pending: [SSEEvent] = []
        var pendingIndex = 0

        public mutating func next() async throws -> SSEEvent? {
            while pendingIndex == pending.count {
                guard let byte = try await base.next() else { return nil }
                pending = parser.push(CollectionOfOne(byte))
                pendingIndex = 0
            }
            defer { pendingIndex += 1 }
            return pending[pendingIndex]
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}
