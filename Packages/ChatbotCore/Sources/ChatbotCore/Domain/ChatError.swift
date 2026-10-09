import Foundation

/// 模型调用出错的类别（ARCHITECTURE §3.4，SPEC §7）。每个 adapter 负责把 HTTP 状态码、
/// 错误体和流中的错误事件映射到这里。用户取消不属于错误，对应 Message 的 interrupted 状态。
public enum ChatError: Error, Codable, Sendable, Hashable {
    /// key 无效或缺失。
    case authentication
    /// 限流或额度用完。接口给了等待时间（秒）时带上。
    case rateLimited(retryAfter: TimeInterval?)
    /// 服务端过载、5xx。
    case overloaded
    /// 断网、超时。
    case network
    /// 对话太长，超出了模型的上下文。
    case contextTooLong
    /// 当前模型不支持这种输入。
    case unsupportedInput
    /// 请求无效，带接口返回的原始信息。
    case invalidRequest(String)
    /// 其他 Provider 侧错误，带接口返回的原始信息。
    case providerError(String)
}
