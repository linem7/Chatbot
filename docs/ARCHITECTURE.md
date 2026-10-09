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
| 分发 | 本机构建 Apple Silicon Release，以固定自签名证书签名，手动上传 ZIP 到 GitHub Release；不做公证、更新检查或自动更新 |
| 日志 | 只用 `os.Logger`，不记录 key 和对话内容，不做远程上报 |

## 2. 模块划分

```
project.yml
App/                         # app target「Chatbot」：界面和系统集成
  ChatbotApp.swift           # @main：MenuBarExtra + Settings scene，LSUIElement = true（设置窗口或主窗口开着时临时切成 .regular，见 §7）
  AppDelegate.swift          # 通过 @NSApplicationDelegateAdaptor 持有 Hotkey、QuickPanel、定时任务
  QuickPanel/                # NSPanel 子类、面板控制器、SwiftUI 视图（聊天窗式）、输入框（包装 NSTextView）
  MainWindow/                # 历史列表、搜索、Conversation 详情
  Settings/                  # 通用 / Connection / 高级三个标签页
  System/                    # Hotkey、Keychain、开机启动、剪贴板和拖拽的接入
  Rendering/                 # MarkdownUI 主题、代码高亮；MessageRow（Quick Panel 和 Main Window 共用的消息显示：
                             #   搜索状态、Citation 角标、来源列表）；Gemini 搜索建议的 WebView
  Resources/                 # Localizable.xcstrings：界面文案的 String Catalog，源语言英文，另有 zh-Hans
Packages/ChatbotCore/        # 本地 SPM 包：不依赖 UI，可以单独测试。以下目录都在 Sources/ChatbotCore/ 下，测试在 Tests/ChatbotCoreTests/
  Domain/                    # Connection、Model、ModelCapabilities、Conversation、Message、ContentBlock、ChatError
  Providers/                 # SSE 解析器、三个 Provider adapter、请求编码和流解码
  Turn/                      # TurnRunner：串起一次回答所需的多次模型调用，处理取消和续接
  Storage/                   # GRDB 数据库、迁移、全文搜索、30 天清理、附件文件
  Attachments/               # 图片缩放和编码、PDF 抽取文本、文本文件解码
  Titles/                    # 后台生成标题
  Presentation/              # AnswerPresentation：回答怎么显示（插角标、来源列表、搜索状态、搜索建议），纯字符串处理，可测试
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
| 端点 | `POST {base}/chat/completions`（DeepSeek 的 base URL 不带 `/v1`） | `POST {base}/v1/messages`（经中转、OpenRouter 时 base URL 填到 `/v1` 之前） | `POST {base}/v1beta/models/{m}:streamGenerateContent?alt=sse` |
| 关闭思考 | 按 Platform（base URL 的 host）发：DeepSeek 发 `thinking: {type: "disabled"}`；OpenRouter 发 `reasoning: {enabled: false}`，`/models` 报告 `reasoning.mandatory` 的模型改发它支持的最低档 `reasoning.effort`，缓存里没有 `reasoning` 信息时只给 `deepseek/` 模型发；百炼发 `enable_thinking: false`（只会思考的 deepseek-r1、QwQ、QVQ、`*-thinking` 不发）；不认识的服务什么都不发。不发 DeepSeek 不支持的 OpenAI 字段（`n`、`seed`、`parallel_tool_calls` 等） | 能关就关（ADR-0002）：capabilities 里 `thinking.types.disabled` 支持就发 `thinking: disabled`；Sonnet 5.5 发 `between_tools`；关不掉的（Opus 5.5、Fable）走 adaptive，回传思考块时声明 drop_block。支持时都发 `output_config.effort: "low"`。思考块不展示，作为不透明数据原样回传 | `thinkingConfig` 设为最低级别，丢弃 `thought: true` 的 Part |
| system prompt | `role: "system"` 消息 | 顶层 `system` | 顶层 `systemInstruction` |
| 图片 | `image_url` + base64 data URL | `image` block，base64 | `inlineData`，base64 |
| Web Search | 按 Platform：OpenRouter（EU 端点除外）在 `tools` 里加 `{"type": "openrouter:web_search"}`，引用从流里的 `delta.annotations[]`（`url_citation`）取，正文收齐后用 `URLCitationLocator` 定位；百炼发 `enable_search: true`，不返回来源；其他服务不支持 | `tools: [{type: "web_search_20250305", name: "web_search", max_uses: 3}]`；要处理 `stop_reason: "pause_turn"`；`server_tool_use` 和 `web_search_tool_result` 块原样保存、原样回传 | `tools: [{google_search: {}}]`；用 `groundingMetadata` 生成 Citation；`searchEntryPoint.renderedContent` 存进 providerData，供 UI 渲染 |
| 结束标记 | `data: [DONE]`；DeepSeek 的 usage 挂在最后一个内容 chunk 上（v1 不使用） | `event: message_stop`；流中可能出现 `event: error` | 带 `finishReason` 的 chunk 加 EOF |
| 必须原样回传的数据 | 无（思考已关闭） | 整串原生内容块：`thinking`（含 `signature`）、`server_tool_use`、`web_search_tool_result`（含 `encrypted_content`）、带 `citations` 的 `text`（含 `encrypted_index`） | `thoughtSignature`（必须留在原来的 Part 上） |
| 能力来源 | `GET /models` 的 `input_modalities`（OpenRouter 在 `architecture.input_modalities` 里，上下文长度是 `context_length`）；tools 视为支持；搜索按 Platform：OpenRouter（EU 端点除外）的所有 Model 都支持；百炼按模型名和地域查 `BailianModelTable`（清单分北京、新加坡、全球三张表）；其他不支持（`Connection.capabilities(ofModel:)` 在运行时按 Platform 补上，老 Connection 不用重新拉取） | `GET /v1/models`（分页）的 `capabilities.image_input` 和 `capabilities.server_tools.web_search.supported`；capabilities 原文和 `max_tokens` 存进 ModelInfo，adapter 判断思考、effort 和 `max_tokens` 时用；接口没报告 capabilities 时（中转多半只返回 OpenAI 风格的列表）按内置表 `AnthropicModelTable` 兜底：`claude-*` 视为支持图片和搜索，思考和 effort 也按表处理，别家的模型不列出来 | 内置表（按模型名判断），接口只提供 token 上限；中转返回 OpenAI 风格的列表（`data[].id`）时同样按内置表 |

**OpenAI 兼容 adapter 的平台联网**（#54，ADR-0003 修订）：
- OpenRouter 的引用放在流式 chunk 的 `choices[].delta.annotations[]` 里，可能和正文不在同一个 chunk，也可能比它指向的正文先到。所以先收集，等这次调用的正文收齐、`finished` 之前统一发 `.citation`。同一条引用重复出现时只保留一次。annotations 按 JSONValue 宽松解码，格式不对不会连累同一个 chunk 里的正文。
- `start_index`、`end_index` 的单位文档没说，`end_index` 也可能是闭区间，所以 `URLCitationLocator` 不直接用它们：正文里有这条来源的 URL 时，取离 `start_index` 最近的一处，范围延伸到包住它的 Markdown 链接（`[标题](URL)`）或 `<URL>` 的结尾，角标插在链接之后，不会把链接拆坏；正文里没有 URL 时，按几种单位和开闭区间试，切出来的文字含有来源域名就用它；都不行就不给范围，只进来源列表。**需要真机核实。**
- 没有可靠的「正在搜索」事件（`: OPENROUTER PROCESSING` 是 SSE 注释），不发 `webSearchStarted`。
- 百炼的 OpenAI 兼容接口不返回来源，也看不出有没有搜，只在请求里开 `enable_search`。

**Anthropic adapter 的实现要点**（#23）：
- 请求：`POST {base}/v1/messages`，头部 `x-api-key` 和 `anthropic-version: 2023-06-01`。OpenRouter 的 Messages 端点（base URL `https://openrouter.ai/api`）只认 `Authorization: Bearer`，按 Platform 改发这个头；其他中转发 `x-api-key`，不两个都发（#51）。`max_tokens` 取 Model 报告的上限，最多 64000；不知道上限时用 16000。
- Web Search 仍用 `web_search_20250305`（官方文档仍以它配 claude-opus-5-5 示例）。更新的版本走代码执行做动态过滤，更慢，响应里还会多出代码执行块。
- 原样回传：流里每个完整的内容块通过 `providerData` 交给 TurnRunner，按顺序累积在 assistant Message 的第一个块 `opaque(.anthropic, [原生块…])` 里。complete 的回答（以及 `pause_turn` 续接时进行中的回答）逐字发回这一串；interrupted 或 failed 的回答里可能有不完整的工具块，只发文字。
- 思考块的签名绑定了 `system`、`tools` 和之前的消息。system 里的日期变了、用户改了 system prompt、地球按钮切换了 tools，都会让原样回传的思考块对不上：
  - adaptive（Opus 5.5、Fable）：请求里回传了思考块时，发 `thinking: {type: "adaptive", block_binding: {prefix_mismatch_behavior: "drop_block"}}` 和请求头 `anthropic-beta: thinking-binding-controls-2026-08-01`，服务端丢掉对不上的块，回答照常进行；
  - `between_tools`（Sonnet 5.5）不接受 `block_binding`：之前完成的回答里的思考块（工具调用之间的进度说明）一律不回传，每次请求都这样处理，前缀始终一致；`pause_turn` 续接时进行中的回答照常原样发回；
  - `disabled` 的 Model 不产生思考块，`block_binding` 和 disabled 一起发也会 400。
- capabilities 里有没有 `between_tools` 这一项还没有官方示例，按「有就用、没有就当不支持」宽松处理；没有时 Sonnet 5.5 走 adaptive + drop_block，同样能用。
- 经中转（#49、#51）：接口没报告 capabilities 时按模型名查内置表 `AnthropicModelTable`。模型名先统一写法（去掉 `anthropic/` 这类厂商前缀、版本里的点号换成 `-`）再匹配；表里给出关闭思考的方式（disabled、between_tools、关不掉走 adaptive、不发就不思考）和是否支持 low effort。表里没有的模型什么都不发。接口报告了 capabilities 时以接口为准。
- `pause_turn` 最多续接 5 次，到上限还没结束时回答标成 failed（只回传文字），避免下一次 Turn 回传一个没有结果的 `server_tool_use`。
- Citation：adapter 在 text 块结束时按「这次调用输出的正文」给出 UTF-16 范围，TurnRunner 换算成所在 text 块里的偏移。
- `stop_reason`：`refusal`（安全分类器拒答）报 `providerError`，不开服务端 fallback，因为 Conversation 的 Model 创建后不换；`model_context_window_exceeded` 按 `length` 处理。
- 错误映射：401 → authentication；402（billing）和 429 → rateLimited；400 里的 "prompt is too long" 和 413（请求超过 32MB，多半是图片和附件太多）→ contextTooLong，其他 400 和 404 → invalidRequest；所有 5xx（含 529）→ overloaded；流中的 `event: error` 按 `error.type` 映射。

**Gemini adapter 的实现要点**（#24）：
- 请求：`POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse`，key 放在 `x-goog-api-key` 头里。
- 思考：按内置表 `GeminiModelTable` 发每个模型支持的最低档（见 §8 第 2 条），不认识的模型什么都不发；`thought: true` 的 Part 不展示。
- 原样回传：每个 SSE 事件是一个完整的 `GenerateContentResponse`。收到的每个 Part（包括空文本、只带 `thoughtSignature` 的 Part）都通过 `providerData` 交给 TurnRunner，累积在 `opaque(.gemini, [Part…])` 里。complete 的回答逐个原样发回，不合并（带签名的 Part 不能和别的 Part 合并）；interrupted 或 failed 的回答只发文字。
- Google Search：`groundingMetadata` 以 `{"groundingMetadata": …}` 的形式放进同一串不透明数据，供 App 渲染 `searchEntryPoint.renderedContent`（必须展示），回传时跳过。Citation 由 `groundingSupports` 换算成 UTF-16 范围。
- 能力：`/v1beta/models` 只用来拿模型列表和 token 上限（只保留能 `generateContent` 的聊天模型）；图片和搜索能力来自内置表。中转只返回 OpenAI 风格的列表（`{"data": [{"id": …}]}`）时也接受，同样只保留 `gemini-*` 的聊天模型；ID 带厂商前缀（`google/gemini-…`）时去掉前缀再查表，发请求仍用原始 ID（#51）。
- `finishReason`：`MAX_TOKENS` → length；`SAFETY`、`RECITATION`、`BLOCKLIST`、`PROHIBITED_CONTENT`、`SPII` 等 → providerError；`promptFeedback.blockReason` → providerError。
- 错误映射：key 无效（400 + `API_KEY_INVALID`）、401、403 → authentication；429（读 `RetryInfo.retryDelay`）→ rateLimited；400 里的 "exceeds the maximum number of tokens" → contextTooLong，其他 400 和 404 → invalidRequest；5xx → overloaded。流中途的 `{"error": …}` 按同样的规则映射。

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
- **其他设置**也存在 UserDefaults：Default Model、system prompt、首次启动标记等。开机启动的状态以 `SMAppService.mainApp.status` 为准，不另外存；Hotkey 由 KeyboardShortcuts 自己存。
- **system prompt**：UserDefaults 里只存用户可编辑的文本。发送时由 app 在最前面加一行「Today is <日期>.」（日期每天变化，对 Anthropic 回传思考块的影响见 §3.2 的处理）。
- **Connection 模板**（App 侧的 `ConnectionTemplate`）：DeepSeek、Anthropic、Gemini 用 Core 的 `Connection.deepSeek()` 等；OpenAI 用 OpenAI 兼容 Provider，base URL 是 `https://api.openai.com/v1`（adapter 直接在 base 后面拼 `/chat/completions`，所以要带 `/v1`，DeepSeek 不带）；自定义可以选 Provider、填 base URL。

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

- **清理**：app 启动时执行一次，之后每 24 小时执行一次 `DELETE FROM conversation WHERE lastMessageAt < now - 30 days`，再删掉对应的附件目录。定时任务在 AppDelegate 里，调用 `HistoryStore.deleteExpiredConversations()`；删掉了东西就通知 Main Window 刷新。
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
- **Hotkey**：两种方式由 `HotkeyController` 二选一注册，选择存在 UserDefaults 的 `hotkeyTrigger`（#64）。
  - 组合键：使用 KeyboardShortcuts（底层是 Carbon `RegisterEventHotKey`，不需要权限），默认 option+space。用 `isTakenBySystem` 检测和系统快捷键的冲突，冲突时提示。其他 app 注册的同一组合检测不到（Carbon 的非独占注册不报错），只在设置里放一句静态提示。
  - 连按两次 ⌘：`DoubleCommandMonitor` 同时装全局和本地的 `flagsChanged` + `keyDown` 监视器。修饰键没有单独的按下事件，只能从 `flagsChanged` 的 `keyCode`（54 左 / 55 右）和 `modifierFlags` 推断按下；⌘ 的抬手不算，否则每次双击都会被自己的抬手清掉计时；中间混进别的按键或修饰键就作废，⌘C、⌘V 才不会被当成双击。全局监视器只看得到别的 app 的按键，本地的只看得到自己的，两边都装面板开着时才能双击收起。这需要**辅助功能**权限，没给之前 `apply()` 保留组合键、不装监视器（`AXIsProcessTrusted()` 判断，`applicationDidBecomeActive` 时重看一次）。
  - 两种方式互斥：换到 ⌘ 双击时 `KeyboardShortcuts.disable`，换回来再 `enable`。
- **Quick Panel**：`NSPanel` 子类，主要配置如下：
  - `styleMask` 设为 `.nonactivatingPanel` + `.borderless`，并重写 `canBecomeKey = true`；
  - `level = .floating`，`collectionBehavior` 包括 `.canJoinAllSpaces`、`.fullScreenAuxiliary`、`.transient`、`.ignoresCycle`；
  - 内容用 `NSHostingView`；
  - 在 `windowDidResignKey` 中执行 `orderOut`；面板被固定住时（顶栏图钉，#59）`hide()` 直接返回，失焦、Esc、Hotkey 都不再收起，窗口就留在 `.floating` 层级上——「保持在最前」靠的是已有的层级，固定状态只是不再自己 `orderOut`。守卫只放在 `hide()` 这一处，三种收起方式都从它经过；
  - 面板内的快捷键用本地 `NSEvent` monitor 按 keyCode 处理：Esc 隐藏面板，⌘. 停止生成，⌘N 新对话。不用 `.onExitCommand`，因为 AppKit 把 Esc 和 ⌘. 都映射为 `cancelOperation:`，没法区分；输入法正在组字时 Esc 交给输入法；
  - 定位：按鼠标所在的屏幕，偏上居中。顶栏的空当包一个 `NSViewRepresentable`，在 `mouseDown` 里调 `NSWindow.performDrag(with:)` 拖动窗口（#63）——无边框窗口没有标题栏，系统不给拖。`isMovable` 为 true 配合 `performDrag`，`isMovableByWindowBackground` 保持 false，消息区选字才不会被当成拖窗口。拖过一次后 `ChatStore.hasMovedPanel` 置位，之后 `show()` 不再重新定位；这一位和 `isPanelPinned` 一样不写进设置，重启回到偏上居中。
- **输入框**：用 `NSViewRepresentable` 包装 `NSTextView`，不用 SwiftUI 的 `TextEditor`。一是要在 `textView(_:doCommandBy:)` 里实现 ⏎ 发送、⇧⏎ 换行，输入法正在组字时 ⏎ 由输入法消费，不会误发送；二是面板显示时可以直接 `makeFirstResponder`，不依赖 `@FocusState`。面板不激活 app，⌘C、⌘V 等编辑命令由面板的 `performKeyEquivalent` 直接发给响应链。
- **菜单栏**：使用 `MenuBarExtra`。图标的三种状态（空闲、生成中、有未读）由 store 驱动。label 会被渲染成静态图片，`.symbolEffect` 不会播放，所以生成中由 store 的计时器每 0.5 秒切换一次帧（正常和变淡两张 template 图片）。
- **普通窗口（设置窗口、Main Window）**（#46）：
  - SwiftUI 在 LSUIElement app 里创建的窗口 `hidesOnDeactivate` 为 true，点别的 app 时会被 AppKit 自动隐藏。所以由 `RegularWindows` 在窗口出现时把它设为 false，让它们像普通窗口一样留在原处。
  - 这类窗口开着时，激活策略切成 `.regular`，临时出现在 Dock 和 ⌘Tab 里；最后一个关掉（`willCloseNotification`）后切回 `.accessory`。如果这时 app 仍在前台、但已经没有可见窗口，就把前台还给打开第一个窗口之前的 app（`yieldActivation(to:)` 加 `activate(from:)`，和 Quick Panel 打开文件面板后的做法一样）。不用 `NSApp.hide(nil)`：app 进入 hidden 状态后，不激活 app 的 Quick Panel 就显示不出来。Quick Panel 的 `show()` 开头也会在 app 被隐藏时先 `unhideWithoutActivation()`。
  - Quick Panel 不经过这里，不会触发激活策略的切换。
- **界面文案**：用 String Catalog（`App/Resources/Localizable.xcstrings`），源语言英文，另加 zh-Hans，跟随系统语言。
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
2. **Gemini**（按文档核实，2026-10-09，#24）：
   - **API 仍用 `generateContent`**：文档页已标为「Gemini Generate Content API (Legacy)」，默认文档换成了 Interactions API。但截至 2026-10-09 没有停用计划：[Deprecations 页面](https://ai.google.dev/gemini-api/docs/deprecations)（2026-10-07 更新）只列了模型的停用；[changelog](https://ai.google.dev/gemini-api/docs/changelog) 里 2026-05-06 的「legacy schema 移除」说的是 Interactions API 自己的旧格式；2026-06-17 还给 `streamGenerateContent` 加了新功能。
   - **哪些模型无法完全关闭思考**（[thinking 文档](https://ai.google.dev/gemini-api/docs/generate-content/thinking)）：2.5 Flash、Flash-Lite 能关（`thinkingBudget: 0`）；2.5 Pro 最少 128；3.1 Pro 最低 `thinkingLevel: low`；3.x Flash 和 Flash-Lite 都关不掉，最低是 `minimal`，3.7、3.8 Flash 发 `minimal` 会报错，最低是 `low`。已做成内置表 `GeminiModelTable`。
   - **`groundingSupports` 的偏移单位**：文档仍然没写，官方示例本身也对不上。实现上不依赖单位，按 UTF-8 字节换算后和 `segment.text` 对照，对不上就在正文里找 `segment.text`。**需要用真实 key、用中文问题核实一次。**
   - **流中途出错的格式**：文档没写。按 Google API 通用的 `{"error": {...}}` 宽松解码。**需要真机核实。**
   - **`groundingMetadata` 在哪个 chunk 出现**：文档没写。每个 chunk 都检查，保留最后一次的；正文开始前就拿到的搜索词立刻显示。**需要真机核实。**
   - **`functionCall` 会不会被拆到多个 chunk 里**：v1 没有 app 侧工具，暂不影响。
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
