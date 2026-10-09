import ChatbotCore
import Foundation
import Synchronization
import Testing

/// 假的 HTTPTransport：返回预设的状态码和 body，并记下收到的请求。
final class StubTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(statusCode: Int, headers: [String: String], body: [UInt8])
        /// 先返回 200 和这段 body，然后连接断开
        case truncated(body: [UInt8], error: ChatError)
        case failure(ChatError)
    }

    /// 依次使用的回复；用完之后一直重复最后一个。
    private let replies: Mutex<[Reply]>
    private let recorded = Mutex<[HTTPRequest]>([])

    init(_ reply: Reply) {
        self.replies = Mutex([reply])
    }

    init(sequence: [Reply]) {
        self.replies = Mutex(sequence)
    }

    convenience init(statusCode: Int = 200, headers: [String: String] = [:], body: String) {
        self.init(.response(statusCode: statusCode, headers: headers, body: Array(body.utf8)))
    }

    var requests: [HTTPRequest] {
        recorded.withLock { $0 }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        let reply = replies.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        switch reply {
        case .failure(let error):
            throw error
        case .response(let statusCode, let headers, let body):
            let stream = AsyncThrowingStream<UInt8, any Error> { continuation in
                for byte in body { continuation.yield(byte) }
                continuation.finish()
            }
            return HTTPResponse(statusCode: statusCode, headers: headers, body: stream)
        case .truncated(let body, let error):
            let stream = AsyncThrowingStream<UInt8, any Error> { continuation in
                for byte in body { continuation.yield(byte) }
                continuation.finish(throwing: error)
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: stream)
        }
    }
}

enum Fixture {
    /// 读取 Tests/ChatbotCoreTests/Fixtures 下的文件。
    static func string(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
