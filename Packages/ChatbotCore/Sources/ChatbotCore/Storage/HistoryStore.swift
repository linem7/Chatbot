import Foundation
import GRDB

/// 本地历史（ARCHITECTURE §5.2，ADR-0004）：GRDB 数据库加附件目录。
///
/// 目录结构：`<directory>/history.sqlite` 和 `<directory>/attachments/<conversationID>/`。
/// App 里 directory 是 `~/Library/Application Support/com.linem7.Chatbot/`。
public final class HistoryStore: MessageStore, TitleStore, Sendable {
    /// 最后一条消息在这么久之前的 Conversation 会被静默删除（SPEC §8）。
    static let retention: TimeInterval = 30 * 86_400

    private let database: DatabasePool
    private let attachmentsDirectory: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabasePool(path: directory.appendingPathComponent("history.sqlite").path)
        attachmentsDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
        try Self.migrator.migrate(database)
    }

    // MARK: MessageStore

    public func saveUserMessage(_ message: Message, attachments: [Attachment], in conversation: Conversation) async throws {
        // 附件副本先写文件，再在同一个事务里写 message 和 attachment 行
        let storedFiles = try attachments.map { try writeCopy(of: $0, conversationID: conversation.id) }
        try await database.write { db in
            if try Self.conversationExists(conversation.id, db) {
                try Self.touch(conversation.id, at: message.createdAt, db)
            } else {
                var conversation = conversation
                conversation.lastMessageAt = message.createdAt
                if conversation.title.isEmpty { conversation.title = Self.fallbackTitle(for: message) }
                try Self.insert(conversation, db)
            }
            try Self.upsert(message, conversationID: conversation.id, db)
            for (attachment, storedFile) in zip(attachments, storedFiles) {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO attachment (id, messageID, kind, originalName, storedFile)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [attachment.id.uuidString, message.id.uuidString, attachment.kind.rawValue, attachment.originalName, storedFile]
                )
            }
        }
    }

    public func saveAssistantMessage(_ message: Message, conversationID: UUID) async throws {
        try await database.write { db in
            try Self.touch(conversationID, at: message.createdAt, db)
            try Self.upsert(message, conversationID: conversationID, db)
        }
    }

    public func attachments(in conversationID: UUID) async throws -> [Attachment] {
        // 在闭包里就转换成 Sendable 的值：Row 不是 Sendable，返回 Row 会让编译器选中阻塞的同步 read
        let rows = try await database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT attachment.* FROM attachment
                    JOIN message ON message.id = attachment.messageID
                    WHERE message.conversationID = ?
                    ORDER BY message.seq, attachment.rowid
                    """,
                arguments: [conversationID.uuidString]
            ).map { row in
                (id: row["id"] as String, kind: row["kind"] as String, originalName: row["originalName"] as String, storedFile: row["storedFile"] as String)
            }
        }
        let folder = attachmentsDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row.id),
                  let kind = Attachment.Kind(rawValue: row.kind),
                  // 副本文件丢了就略过这个附件
                  let data = try? Data(contentsOf: folder.appendingPathComponent(row.storedFile))
            else { return nil }
            let content: Attachment.Content
            switch kind {
            case .image:
                content = .image(data, mediaType: row.storedFile.hasSuffix(".png") ? "image/png" : "image/jpeg")
            case .pdf, .text:
                content = .text(String(decoding: data, as: UTF8.self))
            }
            return Attachment(id: id, kind: kind, originalName: row.originalName, content: content)
        }
    }

    /// 把附件副本写到 `attachments/<conversationID>/`，返回文件名。已经存在时不重写（Retry）。
    /// 图片存压缩后的版本，PDF 和文本文件存抽出的文字（SPEC §4）。
    private func writeCopy(of attachment: Attachment, conversationID: UUID) throws -> String {
        let folder = attachmentsDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        let data: Data
        let fileName: String
        switch attachment.content {
        case .image(let imageData, let mediaType):
            data = imageData
            fileName = attachment.id.uuidString + (mediaType == "image/png" ? ".png" : ".jpg")
        case .text(let text):
            data = Data(text.utf8)
            fileName = attachment.id.uuidString + ".txt"
        }
        let url = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return fileName
    }

    // MARK: 读取

    /// 全部 Conversation，按最后一条消息的时间倒序（SPEC §8）。
    public func conversations() async throws -> [Conversation] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM conversation ORDER BY lastMessageAt DESC")
                .map(Self.conversation(from:))
        }
    }

    public func conversation(_ id: UUID) async throws -> Conversation? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM conversation WHERE id = ?", arguments: [id.uuidString])
                .map(Self.conversation(from:))
        }
    }

    /// 一个 Conversation 的全部 Message，按发出顺序。
    public func messages(in conversationID: UUID) async throws -> [Message] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM message WHERE conversationID = ? ORDER BY seq", arguments: [conversationID.uuidString])
                .map(Self.message(from:))
        }
    }

    /// 全文搜索标题和所有消息正文，结果按最后一条消息的时间倒序。查询为空时返回全部。
    ///
    /// 用 trigram 分词：中文没有空格，默认的 unicode61 分词会把一整段中文当成一个词，搜不到其中的词。
    /// trigram 的 MATCH 对少于 3 个字符的查询匹配不到任何结果，所以 3 个字符及以上用 MATCH 走索引；
    /// 更短的（中文常见的两个字的词）退回 LIKE。这种 LIKE 用不上 trigram 索引，是全表扫描，
    /// 对单机的个人历史足够快。
    public func search(_ query: String) async throws -> [Conversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return try await conversations() }

        let titleCondition: String
        let bodyCondition: String
        let pattern: String
        if query.unicodeScalars.count >= 3 {
            pattern = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            titleCondition = "conversation_fts MATCH ?"
            bodyCondition = "message_fts MATCH ?"
        } else {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            pattern = "%" + escaped + "%"
            titleCondition = "conversation_fts.title LIKE ? ESCAPE '\\'"
            bodyCondition = "message_fts.plainText LIKE ? ESCAPE '\\'"
        }
        let sql = """
            SELECT * FROM conversation
            WHERE rowid IN (SELECT rowid FROM conversation_fts WHERE \(titleCondition))
               OR id IN (
                   SELECT message.conversationID FROM message
                   JOIN message_fts ON message_fts.rowid = message.rowid
                   WHERE \(bodyCondition))
            ORDER BY lastMessageAt DESC
            """
        return try await database.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [pattern, pattern]).map(Self.conversation(from:))
        }
    }

    // MARK: 修改

    /// 地球按钮：这个 Conversation 开不开 Web Search。还没落库的 Conversation 不做任何事——
    /// 第一次保存用户 Message 时会把这个字段一起写进去。
    public func saveWebSearchEnabled(_ enabled: Bool, conversationID: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE conversation SET webSearchEnabled = ? WHERE id = ?",
                arguments: [enabled, conversationID.uuidString]
            )
        }
    }

    /// 后台生成的标题。
    public func saveGeneratedTitle(_ title: String, conversationID: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE conversation SET title = ?, titleIsGenerated = 1 WHERE id = ?",
                arguments: [title, conversationID.uuidString]
            )
        }
    }

    /// 删除单个 Conversation，连同它的 Message 和附件。
    public func deleteConversation(_ id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id.uuidString])
        }
        removeAttachments(of: [id])
    }

    /// 删除 Connection 时，同时删除它的所有 Conversation（ARCHITECTURE §5.2）。
    public func deleteConversations(connectionID: UUID) async throws {
        let ids = try await database.write { db in
            try Self.delete(where: "connectionID = ?", arguments: [connectionID.uuidString], db)
        }
        removeAttachments(of: ids)
    }

    /// 「清空全部历史」。
    public func deleteAll() async throws {
        let ids = try await database.write { db in
            try Self.delete(where: "1", arguments: [], db)
        }
        removeAttachments(of: ids)
    }

    /// 静默删除最后一条消息在 30 天前的 Conversation，连同附件。返回删除的个数。
    @discardableResult
    public func deleteExpiredConversations(now: Date = Date()) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSinceReferenceDate
        let ids = try await database.write { db in
            try Self.delete(where: "lastMessageAt < ?", arguments: [cutoff], db)
        }
        removeAttachments(of: ids)
        return ids.count
    }

    private func removeAttachments(of conversationIDs: [UUID]) {
        for id in conversationIDs {
            try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }
}

// MARK: - 表结构和行映射

extension HistoryStore {
    /// 注意：两张 FTS5 表是外部内容表（external content），靠 conversation 和 message 的隐式 rowid 对应。
    /// 这两张表的主键是 TEXT，rowid 不是主键的别名，执行 VACUUM 可能重新编号 rowid，
    /// 导致全文索引指向错误的行。所以**不要对这个数据库执行 VACUUM**；
    /// 真要压缩，先重建 FTS 索引（`INSERT INTO xxx_fts(xxx_fts) VALUES('rebuild')`）。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // 时间一律存 timeIntervalSinceReferenceDate（自 2001-01-01 起的秒数，Double）。
            // 这是 Date 内部的表示，读回来和原值完全相同；换算成 Unix 秒会有舍入误差。
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("titleIsGenerated", .boolean).notNull()
                t.column("connectionID", .text).notNull().indexed()
                t.column("modelID", .text).notNull()
                t.column("webSearchEnabled", .boolean).notNull()
                t.column("createdAt", .double).notNull()
                t.column("lastMessageAt", .double).notNull().indexed()
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("conversationID", .text).notNull().indexed()
                    .references("conversation", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("role", .text).notNull()
                t.column("status", .text).notNull()
                t.column("errorCategory", .text)
                t.column("errorDetail", .text)
                // [ContentBlock] 的 JSON，包括 providerData
                t.column("content", .text).notNull()
                // 用于全文搜索：用户文字或回答正文
                t.column("plainText", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.uniqueKey(["conversationID", "seq"])
            }
            // storedFile 是 attachments/<conversationID>/ 下的文件名；图片存压缩后的版本，PDF 和文本存抽出的文字，
            // 所以 extractedTextFile 目前不用
            try db.create(table: "attachment") { t in
                t.primaryKey("id", .text)
                t.column("messageID", .text).notNull().indexed()
                    .references("message", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("originalName", .text).notNull()
                t.column("storedFile", .text).notNull()
                t.column("extractedTextFile", .text)
            }
            // 两张 FTS5 表分别索引标题和正文，由 GRDB 建的触发器自动同步
            let trigram = FTS5TokenizerDescriptor(components: ["trigram"])
            try db.create(virtualTable: "conversation_fts", using: FTS5()) { t in
                t.synchronize(withTable: "conversation")
                t.tokenizer = trigram
                t.column("title")
            }
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = trigram
                t.column("plainText")
            }
        }
        return migrator
    }

    static func fallbackTitle(for message: Message) -> String {
        let firstLine = message.markdownText
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return String((firstLine ?? "").prefix(80))
    }

    private static func conversationExists(_ id: UUID, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM conversation WHERE id = ?)", arguments: [id.uuidString]) ?? false
    }

    private static func insert(_ conversation: Conversation, _ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO conversation (id, title, titleIsGenerated, connectionID, modelID, webSearchEnabled, createdAt, lastMessageAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                conversation.id.uuidString, conversation.title, conversation.titleIsGenerated,
                conversation.connectionID.uuidString, conversation.modelID, conversation.webSearchEnabled,
                conversation.createdAt.timeIntervalSinceReferenceDate, conversation.lastMessageAt.timeIntervalSinceReferenceDate,
            ]
        )
    }

    /// 有新消息时把 lastMessageAt 往后推（不会往前改）。
    private static func touch(_ id: UUID, at date: Date, _ db: Database) throws {
        try db.execute(
            sql: "UPDATE conversation SET lastMessageAt = max(lastMessageAt, ?) WHERE id = ?",
            arguments: [date.timeIntervalSinceReferenceDate, id.uuidString]
        )
    }

    private static func upsert(_ message: Message, conversationID: UUID, _ db: Database) throws {
        let content = String(decoding: try JSONEncoder().encode(message.content), as: UTF8.self)
        let (status, errorCategory, errorDetail) = encode(message.status)
        try db.execute(
            sql: """
                INSERT INTO message (id, conversationID, seq, role, status, errorCategory, errorDetail, content, plainText, createdAt)
                VALUES (?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM message WHERE conversationID = ?), ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    status = excluded.status,
                    errorCategory = excluded.errorCategory,
                    errorDetail = excluded.errorDetail,
                    content = excluded.content,
                    plainText = excluded.plainText
                """,
            arguments: [
                message.id.uuidString, conversationID.uuidString, conversationID.uuidString,
                message.role.rawValue, status, errorCategory, errorDetail,
                content, message.markdownText, message.createdAt.timeIntervalSinceReferenceDate,
            ]
        )
    }

    /// 删除符合条件的 Conversation，返回它们的 id（用来删附件目录）。
    private static func delete(where condition: String, arguments: StatementArguments, _ db: Database) throws -> [UUID] {
        let ids = try String.fetchAll(db, sql: "SELECT id FROM conversation WHERE \(condition)", arguments: arguments)
        try db.execute(sql: "DELETE FROM conversation WHERE \(condition)", arguments: arguments)
        return ids.compactMap(UUID.init(uuidString:))
    }

    private static func conversation(from row: Row) throws -> Conversation {
        Conversation(
            id: try uuid(row["id"]),
            title: row["title"],
            titleIsGenerated: row["titleIsGenerated"],
            connectionID: try uuid(row["connectionID"]),
            modelID: row["modelID"],
            webSearchEnabled: row["webSearchEnabled"],
            createdAt: Date(timeIntervalSinceReferenceDate: row["createdAt"]),
            lastMessageAt: Date(timeIntervalSinceReferenceDate: row["lastMessageAt"])
        )
    }

    private static func message(from row: Row) throws -> Message {
        let content: String = row["content"]
        let roleValue: String = row["role"]
        guard let role = Message.Role(rawValue: roleValue) else {
            throw StorageError.corruptRow("未知的 role：\(roleValue)")
        }
        return Message(
            id: try uuid(row["id"]),
            role: role,
            status: try decodeStatus(row["status"], category: row["errorCategory"], detail: row["errorDetail"]),
            content: try JSONDecoder().decode([ContentBlock].self, from: Data(content.utf8)),
            createdAt: Date(timeIntervalSinceReferenceDate: row["createdAt"])
        )
    }

    private static func uuid(_ string: String) throws -> UUID {
        guard let uuid = UUID(uuidString: string) else { throw StorageError.corruptRow("不是 UUID：\(string)") }
        return uuid
    }

    // MessageStatus 存成 status、errorCategory、errorDetail 三列（ARCHITECTURE §5.2）

    private static func encode(_ status: MessageStatus) -> (String, String?, String?) {
        switch status {
        case .streaming: return ("streaming", nil, nil)
        case .complete: return ("complete", nil, nil)
        case .interrupted: return ("interrupted", nil, nil)
        case .failed(let error):
            switch error {
            case .authentication: return ("failed", "authentication", nil)
            case .rateLimited(let retryAfter): return ("failed", "rateLimited", retryAfter.map { String($0) })
            case .overloaded: return ("failed", "overloaded", nil)
            case .network: return ("failed", "network", nil)
            case .contextTooLong: return ("failed", "contextTooLong", nil)
            case .unsupportedInput: return ("failed", "unsupportedInput", nil)
            case .invalidRequest(let message): return ("failed", "invalidRequest", message)
            case .providerError(let message): return ("failed", "providerError", message)
            }
        }
    }

    private static func decodeStatus(_ status: String, category: String?, detail: String?) throws -> MessageStatus {
        switch status {
        case "streaming": return .streaming
        case "complete": return .complete
        case "interrupted": return .interrupted
        case "failed":
            switch category {
            case "authentication": return .failed(.authentication)
            case "rateLimited": return .failed(.rateLimited(retryAfter: detail.flatMap(TimeInterval.init)))
            case "overloaded": return .failed(.overloaded)
            case "network": return .failed(.network)
            case "contextTooLong": return .failed(.contextTooLong)
            case "unsupportedInput": return .failed(.unsupportedInput)
            case "invalidRequest": return .failed(.invalidRequest(detail ?? ""))
            default: return .failed(.providerError(detail ?? ""))
            }
        default:
            throw StorageError.corruptRow("未知的 status：\(status)")
        }
    }
}

enum StorageError: Error {
    case corruptRow(String)
}
