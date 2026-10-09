# 本地历史用 GRDB（SQLite），不用 SwiftData

本地历史存在 `~/Library/Application Support/<bundle id>/` 下的 SQLite 数据库里，通过 GRDB 访问。Attachment 副本存在同一目录下的文件夹里。Message 的内容块，以及块上 Provider 原生的不透明数据（见 [ADR-0001](0001-provider-adapter-single-call-turn-drives-tools.md)），以 JSON 形式存在列里。

选 GRDB 的原因：
- 历史需要全文搜索，GRDB 直接支持 SQLite FTS5；
- 「静默删除最后一条消息在 30 天前的 Conversation」用一条 SQL 就能完成；
- 内容块结构因 Provider 而异，存成 JSON 列比映射成对象模型更省事；
- 行为可预测，容易写测试。

## Considered Options

- **SwiftData**：否决。它和 SwiftUI 集成最好，但在 macOS 14 上已知问题较多，全文搜索和批量删除都不如直接写 SQL 灵活。
- **每个 Conversation 一个 JSON 文件**：否决。最简单，但全文搜索要遍历所有文件，自动清理也要自己扫目录。
