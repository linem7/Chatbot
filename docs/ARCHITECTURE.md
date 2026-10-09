# Chatbot v1 架构

> 本文说明 v1 怎么实现。功能规格见 [`SPEC.md`](SPEC.md)，术语见 [`CONTEXT.md`](../CONTEXT.md)，关键取舍见 [`docs/adr/`](adr/)。研究资料在 [`docs/research/`](research/)。其中截图研究（`macos-screenshot.md`）和搜索服务商研究（`search-providers.md`）只作存档。

## 1. 工程基线

| 项 | 决定 |
|---|---|
| 平台 | macOS 26 Tahoe 及以上 |
| 语言 | Swift 6 语言模式，开启严格并发检查 |
| UI | SwiftUI 为主；Quick Panel、Hotkey 等系统集成用 AppKit |
| 工程 | XcodeGen：仓库里只提交 `project.yml`，`.xcodeproj` 加入 `.gitignore` |
| 测试 | Swift Testing；`ChatbotCore` 可以用 `swift test` 单独运行 |
| 依赖（SPM） | App target：`sindresorhus/KeyboardShortcuts`（3.x）、`gonzalezreal/swift-markdown-ui`（2.4.1 起，product `MarkdownUI`）、`smittytone/HighlighterSwift`（3.1.0 起，product `Highlighter`，代码高亮）。ChatbotCore：`groue/GRDB.swift`（7.x）。MarkdownUI 已进入维护模式，后继是 Textual，暂不迁移（见 §8 第 1 条） |
| 不引入 | 任何 LLM SDK、SSE 库、Sparkle 等更新框架 |
| bundle id | `com.linem7.Chatbot` |
| 签名 | 本机构建时用一张固定的自签名证书，不做公证（ADR-0005） |
| CI | GitHub Actions macOS runner，push 到 main 和 PR 时都构建并跑测试。仓库是公开的，标准 runner 不收费。CI 不签名，也不发布 |
| 分发 | v1 只自用：在本机构建后安装。不发 GitHub Release，也不做更新检查 |
| 日志 | 只用 `os.Logger`，不记录 key 和对话内容，不做远程上报 |

## 2. 模块划分

```
project.yml
App/                         # app target「Chatbot」：界面和系统集成
  ChatbotApp.swift           # @main：MenuBarExtra + Settings scene，LSUIElement = true
  AppDelegate.swift          # 通过 @NSApplicationDelegateAdaptor 持有 Hotkey、QuickPanel、定时任务
  QuickPanel/                # NSPanel 子类、面板控制器、SwiftUI 视图（聊天窗式）
  MainWindow/                # 历史列表、搜索、Conversation 详情
  Settings/                  # 通用 / Connection / 高级三个标签页
  System/                    # Hotkey、Keychain、开机启动、剪贴板和拖拽的接入
  Rendering/                 # MarkdownUI 主题、代码高亮、Citation 角标、Gemini 搜索建议的 WebView
Packages/ChatbotCore/        # 本地 SPM 包：不依赖 UI，可以单独测试。以下目录都在 Sources/ChatbotCore/ 下，测试在 Tests/ChatbotCoreTests/
  Domain/                    # Connection、Model、ModelCapabilities、Conversation、Message、ContentBlock、ChatError
  Providers/                 # SSE 解析器、三个 Provider adapter、请求编码和流解码
  Turn/                      # TurnRunner：串起一次回答所需的多次模型调用，处理取消和续接
  Storage/                   # GRDB 数据库、迁移、全文搜索、30 天清理、附件文件
  Attachments/               # 图片缩放和编码、PDF 抽取文本、文本文件解码
  Titles/                    # 后台生成标题
```

依赖方向：`App → ChatbotCore`。`ChatbotCore` 不引用 SwiftUI 和 AppKit；PDFKit、ImageIO 不属于 UI 框架，可以在包里用。

## 3. Provider 抽象（ADR-0001、ADR-0003）

### 3.1 接口

```swift
protocol ProviderAdapter: Sendable {
    /// 一次模型调用：把各家的流统一成 ModelEvent。出错时抛出 ChatError。
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    /// 拉取 Model 列表和能力；保存 Connection 时也用它做连接测试。
    func listModels(_ connection: Connection, apiKey: String) async throws -> [ModelInfo]
}

struct ModelRequest {
    var connection: Connection; var apiKey: String; var modelID: String
    var systemPrompt: String
    var messages: [Message]          // 领域 Message，由 adapter 序列化成各家格式
    var webSearch: Bool              // 当前 Model 支持搜索，并且这个 Conversation 没有关掉搜索
}

enum ModelEvent {
    case textDelta(String)
    case toolCallStarted(id: String, name: String)        // app 侧工具；v1 没有，保留这个接口
    case toolCallArgumentsDelta(id: String, json: String)
    case toolCallCompleted(id: String, argumentsJSON: String)
    case webSearchStarted(query: String)
    case citation(Citation, textRange: Range<Int>?)       // 正文中引用的范围（UTF-16 偏移）
    case providerData(blockIndex: Int, opaque: JSONValue) // 必须原样回传的数据
    case finished(FinishReason)                           // stop / length / pauseTurn / toolUse
}
```

### 3.2 三个 adapter

| | OpenAI 兼容（DeepSeek 等） | Anthropic Messages | Gemini `generateContent` |
|---|---|---|---|
| 端点 | `POST {base}/chat/completions`（DeepSeek 的 base URL 不带 `/v1`） | `POST /v1/messages` | `POST /v1beta/models/{m}:streamGenerateContent?alt=sse` |
| 关闭思考 | DeepSeek 发 `thinking: {type: "disabled"}`；不发它不支持的 OpenAI 字段（`n`、`seed`、`parallel_tool_calls` 等） | 不发 `thinking` | `thinkingConfig` 设为最低级别，丢弃 `thought: true` 的 Part |
| system prompt | `role: "system"` 消息 | 顶层 `system` | 顶层 `systemInstruction` |
| 图片 | `image_url` + base64 data URL | `image` block，base64 | `inlineData`，base64 |
| Web Search | 不支持 | `tools: [{type: "web_search_20250305", name: "web_search", max_uses: 3}]`；要处理 `stop_reason: "pause_turn"`；`server_tool_use` 和 `web_search_tool_result` 块原样保存、原样回传 | `tools: [{google_search: {}}]`；用 `groundingMetadata` 生成 Citation；`searchEntryPoint.renderedContent` 存进 providerData，供 UI 渲染 |
| 结束标记 | `data: [DONE]`；DeepSeek 的 usage 挂在最后一个内容 chunk 上（v1 不使用） | `event: message_stop`；流中可能出现 `event: error` | 带 `finishReason` 的 chunk 加 EOF |
| 必须原样回传的数据 | 无（思考已关闭） | `server_tool_use`、`web_search_tool_result`（含 `encrypted_content`） | `thoughtSignature`（必须留在原来的 Part 上） |
| 能力来源 | DeepSeek：`GET /models` 的 `input_modalities`；tools 视为支持；搜索一律不支持 | `GET /v1/models` 的 `capabilities.image_input` 和 `capabilities.server_tools.web_search.supported` | 内置表（按模型名判断），接口只提供 token 上限 |

**Model Capabilities 的来源优先级**：接口报告 > 内置表 > 保守默认。保守默认是「只支持文本和 tools，不支持图片，不支持搜索」。用户不能手动修改。

### 3.3 SSE 解析器（自己写，不引入库）
研究 #2 记录了这些坑：
- 按字节自己切行（`\n`、`\r`、`\r\n`），**不要用 `AsyncBytes.lines`**，它会吞掉空行，而 SSE 靠空行分隔事件。
- 忽略以 `:` 开头的注释行（DeepSeek 的 `: keep-alive`），跳过 Anthropic 的 `ping` 事件。
- 未知事件类型和字段一律宽松解码，不抛错。
- HTTP 状态不是 2xx 时，读取有限长度的错误体，再映射成 `ChatError`。
- `timeoutIntervalForRequest` 是空闲超时，不是总时长。总时长由 Turn 控制。
- 用各家官方文档里的流示例做 fixture 测试。

### 3.4 错误映射
`ChatError` 有 8 个类别：`authentication`、`rateLimited(retryAfter:)`、`overloaded`、`contextTooLong`、`unsupportedInput`、`network`、`invalidRequest`、`providerError(raw)`。每个 adapter 负责把 HTTP 状态码、错误体和流中的错误事件映射到这些类别。例如 Anthropic 的 529 和 DeepSeek 的 `insufficient_system_resource` 都映射为 `overloaded`。取消不属于错误。

OpenAI 兼容 adapter（DeepSeek）的映射按 SPEC §7：
- 401 → `authentication`；402（余额不足）和 429 → `rateLimited`，429 读 `Retry-After`；
- 400、422 → `invalidRequest`；所有 5xx 和 `insufficient_system_resource` → `overloaded`；
- `finish_reason` 为 `aborted`、`content_filter` → `providerError`；`length` 正常结束，不算错误；
- transport 层的断网、超时 → `network`；流在 `finish_reason` 和 `[DONE]` 之前断开也算 `network`。

`contextTooLong` 是启发式判断：400 且错误体的 `code` 是 `context_length_exceeded`，或 message 含 "maximum context length"。DeepSeek 文档没写这种情况的返回，**还没用真实 key 验证**。

## 4. Turn

`TurnRunner` 负责执行一次 Turn：
1. 用户 Message 落库。
2. 组装 `ModelRequest`，调用 adapter，把收到的事件累积成一条 assistant Message 的内容块，同时推送给 UI。
3. 收到 `finished(.pauseTurn)`（Anthropic 搜索时会出现）时，把当前内容原样发回去继续。收到 `finished(.toolUse)` 时执行 app 侧工具，v1 没有 app 侧工具。
4. 结束、取消、出错或 app 退出时，把 assistant Message 落库，状态分别是 complete / interrupted / failed。
5. 如果这是这个 Conversation 的第一次 Turn，就在后台触发标题生成。

取消用 `Task.cancel()` 实现。UI 状态由一个 `@MainActor @Observable` 的 store 持有，`TurnRunner` 的事件在主 actor 上合并进 store。面板隐藏不影响正在执行的 Turn。

落库通过可注入的 `MessageStore` 协议完成（第 1、4 步）。#19 用内存实现 `InMemoryMessageStore`，#20 换成 GRDB 实现。

## 5. 数据模型与存储（ADR-0004）

### 5.1 设置类数据
- **Connection 列表**：名称、Provider、base URL、隐藏的 Model、缓存的 Model 列表及其能力。以 JSON 形式存在 UserDefaults。
- **API key**：每个 Connection 一条 Keychain 通用密码（service 为 `com.linem7.Chatbot.apikey`，account 为 Connection ID）。第一次用到时读取，之后缓存在内存里。
- **其他设置**也存在 UserDefaults：Default Model、system prompt、开机启动等。Hotkey 由 KeyboardShortcuts 自己存。

### 5.2 历史数据库
位置：`~/Library/Application Support/com.linem7.Chatbot/history.sqlite`。附件副本放在同一目录的 `attachments/<conversationID>/` 下。

```
conversation(id, title, titleIsGenerated, connectionID, modelID, webSearchEnabled, createdAt, lastMessageAt)
message(id, conversationID → conversation ON DELETE CASCADE, seq, role, status, errorCategory?, errorDetail?,
        content JSON,       -- [ContentBlock]，包括 providerData
        plainText,          -- 用于全文搜索：用户文字或回答正文
        createdAt)
attachment(id, messageID → message ON DELETE CASCADE, kind(image|pdf|text), originalName, storedFile, extractedTextFile?)
conversation_fts(FTS5，trigram 分词，和 conversation.title 同步)
message_fts(FTS5，trigram 分词，和 message.plainText 同步)
```

- **时间**：所有时间列存 `timeIntervalSinceReferenceDate`，也就是自 2001-01-01 起的秒数（Double）。这是 `Date` 内部的表示，读写完全一致；换算成 Unix 秒会有舍入误差。
- **全文搜索**：标题和正文各用一张 FTS5 表，由 GRDB 建的触发器自动同步。用 trigram 分词，因为中文没有空格，默认的 unicode61 分词会把一整段中文当成一个词。trigram 的 MATCH 对少于 3 个字符的查询匹配不到任何结果，所以：
  - 3 个字符及以上用 MATCH，走索引；
  - 更短的查询（比如两个字的中文词）退回 `LIKE '%…%'`，是全表扫描。
- **写入**：由 `HistoryStore` 实现 `MessageStore`（§4）。用户 Message 第一次保存时，一起创建 conversation 行，标题先用第一条用户消息的前一行。所以 `saveUserMessage` 接收整个 Conversation。后台生成的标题通过 `TitleStore` 写入。

`ContentBlock` 的种类：`text(String, citations)`、`attachmentRef(id)`、`toolCall`、`toolResult`、`webSearch(query)`、`opaque(provider, JSONValue)`。每个块都可以带 `providerData`。

- **清理**：app 启动时执行一次，之后每 24 小时执行一次 `DELETE FROM conversation WHERE lastMessageAt < now - 30 days`，再删掉对应的附件目录。
- **删除 Connection**：同时删除 `connectionID` 等于它的所有 Conversation。

## 6. Attachment 处理
- **图片**：用 ImageIO 读取，缩放到长边 ≤ 2000px。有透明通道的保持 PNG，其他转成 JPEG（质量 0.85），以 base64 发送。存进历史的就是这份压缩后的版本。
- **PDF**：用 PDFKit 逐页抽取文本，存为文本文件。抽出来是空的就报 `AttachmentError.scannedPDF`，界面提示是扫描版。
- **文本和代码**：按 UTF-8 解码，失败时尝试系统的编码检测。发送时作为文字块，前面加上文件名。
- **入口**：Quick Panel 输入框的粘贴（`NSPasteboard` 中的图片数据或文件 URL）、拖放、「+」打开的 `NSOpenPanel`，三者都汇入同一个 `AttachmentIntake`。

实现要点（#21）：
- **处理**：`AttachmentIntake`（ChatbotCore）把文件或图片数据处理成 `Attachment`。
  - 按扩展名判断图片和 PDF，其他文件一律当文本试着解码：带 BOM 的 UTF-8、UTF-16、UTF-32 按 BOM 识别；前 8KB 有 NUL 字节就当成二进制拒绝，Office 文档也会因此被拒绝。`.pages`、`.key` 这类 bundle 目录报 `unsupportedType`。
  - 加入附件时的问题用 `AttachmentError` 报告，由界面提示，不进入 Turn：`unsupportedType`、`unreadable`、`scannedPDF`（扫描版）。
- **发送**：
  - 用户 Message 里用 `attachmentRef(id)` 按顺序引用附件，TurnRunner 把这个 Conversation 里所有附件放进 `ModelRequest.attachments`。
  - adapter 按 Model Capabilities 编码：Model 支持图片时，图片作为 base64 data URL 发送；不支持或能力未知时，图片换成占位文字「[图片已省略：当前模型不支持图片]」，保证只有图片的用户 Message 不会整条消失，user 和 assistant 仍然交替出现。提示由界面负责，只有图片时界面禁止发送（#21 的 App 部分）。
  - 文本和 PDF 附件作为文字块，前面加上「附件 文件名：」。
- **存储**：附件副本写在 `attachments/<conversationID>/<attachmentID>.{jpg,png,txt}`，attachment 表的 `storedFile` 存这个文件名。PDF 存的是抽出的文字，所以 `extractedTextFile` 目前不用。
- **平台**：ImageIO 和 PDFKit 只在 Apple 平台上可用，用 `#if canImport` 隔开。相关测试只在 CI 上跑。

## 7. 系统集成
- **Hotkey**：使用 KeyboardShortcuts（底层是 Carbon `RegisterEventHotKey`，不需要权限），默认 option+space。用 `isTakenBySystem` 检测冲突，冲突时提示。
- **Quick Panel**：`NSPanel` 子类，主要配置如下：
  - `styleMask` 设为 `.nonactivatingPanel` + `.borderless`，并重写 `canBecomeKey = true`；
  - `level = .floating`，`collectionBehavior` 包括 `.canJoinAllSpaces`、`.fullScreenAuxiliary`、`.transient`、`.ignoresCycle`；
  - 内容用 `NSHostingView`；
  - 在 `windowDidResignKey` 中执行 `orderOut`，用 `.onExitCommand` 处理 Esc；
  - 按鼠标所在的屏幕定位。
- **菜单栏**：使用 `MenuBarExtra`。图标的三种状态（空闲、生成中、有未读）由 store 驱动。
- **开机启动**：`SMAppService.mainApp`。
- **Gemini 搜索建议**：在回答下方放一个小的 `WKWebView`，加载 `renderedContent`。

## 8. 实现前需要核实的事

1. **MarkdownUI 的维护状态和高亮器选择**（已核实，2026-10-09）：
   - `swift-markdown-ui` 已进入维护模式（[作者 2025-12-28 的公告](https://github.com/gonzalezreal/swift-markdown-ui/discussions/437)），后继项目是 Textual。Textual 还是 0.x，流式渲染的问题较多，v1 继续用 MarkdownUI 2.4.1，暂不迁移。
   - 代码高亮器选 `smittytone/HighlighterSwift`（Highlightr 的维护版，内置 highlight.js 11.11.1）。它提供同步 API `highlight(_:as:) -> NSAttributedString?`，可以直接实现 MarkdownUI 的同步协议 `CodeSyntaxHighlighter`。
   - 接入要点（#19）：
     - 深浅色各建一个 `Highlighter` 实例（例如 atom-one-light 和 atom-one-dark），按 `colorScheme` 选择；
     - `Highlighter` 是非 Sendable 的 class，只在 MainActor 上使用；
     - 按 (code, language, colorScheme) 缓存高亮结果；
     - MarkdownUI 每次都整体重新解析，所以流式中的 Message 单独成为一个 view，只重绘最后一条；
     - 2.4.1 的 `Theme` 不是 Sendable，Swift 6 下自定义主题可能报错。可以给自定义主题加 `@MainActor`，或者把依赖钉到 main 上「make the Theme type support Swift 6 (#351)」那个 commit。
2. **Gemini**：
   - 哪些模型无法完全关闭思考；
   - 流中途出错时的格式；
   - `functionCall` 会不会被拆到多个 chunk 里；
   - `groundingSupports` 的偏移单位是字节还是字符（文档前后不一致）。
3. **Hotkey 和面板**（`hotkey-and-panel.md` §6，需要在真机上验证）：
   - 非激活面板里 SwiftUI 输入框第一次能否可靠获得焦点；
   - 全屏 app 上方用 `.floating` 层级是否足够。
4. **DeepSeek**：关闭思考后，确认 `deepseek-flash` 和 `deepseek-v4-pro` 都能接受图片，以 `/models` 返回的结果为准。

## 9. 建议的实现顺序（用来拆分实现 ticket）

1. **工程骨架**：`project.yml`、App 和 ChatbotCore、CI 构建测试、本机自签名配置。
2. **核心链路**：Domain → SSE 解析器 → OpenAI 兼容 adapter（DeepSeek）→ TurnRunner。用 fixture 测试。
3. **最小可用版本**：菜单栏 + Hotkey + Quick Panel（聊天窗式）+ 流式回答 + Markdown 渲染。Connection 设置先只支持 DeepSeek。
4. **存储**：GRDB 历史、标题生成、30 天清理、Main Window 的列表和全文搜索。
5. **Attachment**：粘贴、拖拽、「+」，图片缩放，PDF 和文本处理。
6. **设置完整化**：三个标签页、Connection 模板、首次启动引导、开机启动。
7. **Anthropic adapter**，包括 Web Search、Citation、`pause_turn`。
8. **Gemini adapter**，包括 google_search 和搜索建议的 WebView。
9. **错误展示的完善**，以及本机打包安装的步骤说明。
