import ChatbotCore
import Foundation
import Synchronization

/// 和 GRDB 7 的异步 `write` 一样：调用方的 Task 已经取消时直接抛 `CancellationError`。
/// 用来验证「取消之后仍然要保存」这条约定。
final class CancellationCheckingStore: MessageStore {
    private let saved = Mutex<[Message]>([])

    var messages: [Message] {
        saved.withLock { $0 }
    }

    func saveUserMessage(_ message: Message, conversationID: UUID) async throws {
        try save(message)
    }

    func saveAssistantMessage(_ message: Message, conversationID: UUID) async throws {
        try save(message)
    }

    private func save(_ message: Message) throws {
        try Task.checkCancellation()
        saved.withLock { $0.append(message) }
    }
}
