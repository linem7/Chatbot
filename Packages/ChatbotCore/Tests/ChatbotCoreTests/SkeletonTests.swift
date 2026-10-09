import GRDB
import Testing

struct SkeletonTests {
    /// 历史的全文搜索依赖 FTS5（ARCHITECTURE §5.2），确认 GRDB 背后的 SQLite 带有它。
    @Test func sqliteSupportsFTS5() throws {
        let dbQueue = try DatabaseQueue()
        let hits = try dbQueue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE doc USING fts5(body)")
            try db.execute(sql: "INSERT INTO doc(body) VALUES ('hello world'), ('goodbye')")
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM doc WHERE doc MATCH 'hello'")
        }
        #expect(hits == 1)
    }
}
