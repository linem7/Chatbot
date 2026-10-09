import ChatbotCore
import Foundation
import Synchronization

/// 假的 ProviderAdapter：每次模型调用按剧本依次产出事件，并记下收到的请求。
final class ScriptedAdapter: ProviderAdapter {
    enum Step: Sendable {
        case event(ModelEvent)
        case fail(any Error)
        /// 一直等到被取消
        case hang
    }

    private let calls: Mutex<[[Step]]>
    private let recorded = Mutex<[ModelRequest]>([])

    /// 每个元素是一次模型调用的剧本。
    init(_ calls: [[Step]]) {
        self.calls = Mutex(calls)
    }

    var requests: [ModelRequest] {
        recorded.withLock { $0 }
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        recorded.withLock { $0.append(request) }
        let steps = calls.withLock { $0.isEmpty ? [] : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in steps {
                    switch step {
                    case .event(let event):
                        continuation.yield(event)
                    case .fail(let error):
                        continuation.finish(throwing: error)
                        return
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels(_ connection: Connection, apiKey: String) async throws -> [ModelInfo] {
        []
    }
}
