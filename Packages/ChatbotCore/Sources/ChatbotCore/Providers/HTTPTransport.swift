import Foundation

/// adapter 发出的一个 HTTP 请求。不直接用 `URLRequest`，这样网络层以外的代码在 Linux 上
/// 不需要 FoundationNetworking，也能用 `swift test` 测试。
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// 一个 HTTP 响应：收到响应头就返回，body 以字节流的形式边到边交。
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    /// header 名一律小写。
    public var headers: [String: String]
    public var body: AsyncThrowingStream<UInt8, any Error>

    public init(statusCode: Int, headers: [String: String], body: AsyncThrowingStream<UInt8, any Error>) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    /// 读出最多 `limit` 个字节。用于读非 2xx 的错误体：只读有限长度（ARCHITECTURE §3.3）。
    func collectBody(limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in body {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }
}

/// 网络层的注入点。测试时换成假实现。
/// 实现要求：断网、超时这类网络错误抛 `ChatError.network`；被取消时抛 `CancellationError`。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 当前平台默认的 transport。
public func defaultHTTPTransport() -> any HTTPTransport {
    #if canImport(Darwin)
    URLSessionTransport()
    #else
    UnavailableTransport()
    #endif
}

#if canImport(Darwin)
/// 用 `URLSession.bytes(for:)` 实现的 transport。只在 Apple 平台上可用。
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// `timeoutIntervalForRequest` 是「等新数据」的空闲超时，不是总时长（ARCHITECTURE §3.3）。
    /// 总时长由 Turn 控制。DeepSeek 排队时会发 keep-alive，空闲超时用默认的 60 秒就够了。
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ChatError.providerError("不是 HTTP 响应")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }

        let body = AsyncThrowingStream<UInt8, any Error> { continuation in
            let task = Task {
                do {
                    for try await byte in bytes { continuation.yield(byte) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }

    private static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : ChatError.network
        }
        return error
    }
}
#endif

/// 没有可用网络实现的平台（Linux）。只是为了让包能在 Linux 上编译和测试。
struct UnavailableTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw ChatError.providerError("这个平台上没有网络实现")
    }
}
