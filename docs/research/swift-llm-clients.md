# 研究：Swift 侧 LLM 客户端方案

- 对应 issue：[#2 研究：Swift 侧 LLM 客户端方案](https://github.com/linem7/Chatbot/issues/2)（Part of #1）
- 日期：2026-10-08（下文的版本号、发布日期和 commit 数都是当天用 GitHub API 查的）
- 前提：原生 Swift/SwiftUI，macOS 14+，App Store 外分发，不开 App Sandbox；用户自带 API key（BYOK）；v1 先接 DeepSeek（见 [README](https://github.com/linem7/Chatbot/blob/main/README.md)）
- 术语按 `CONTEXT.md`：
  - **Provider**：API 协议族，分 OpenAI 兼容、Anthropic Messages、Google Gemini 三种。DeepSeek 和 Ollama 是走 OpenAI 兼容 Provider 的服务，本身不算 Provider。
  - **Attachment**：Screenshot，或用户自己选的文件。
  - **Web Search**：app 侧实现的搜索，模型通过 tool calling 调用。

## TL;DR

1. **推荐全部自研。** 在 URLSession `bytes(for:)` 上写一个一两百行的 SSE 解析器，再写三个 Provider adapter（OpenAI 兼容、Anthropic Messages、Gemini），都输出 app 自己定义的统一流式事件类型。不引入任何 LLM SDK。SSE 解析器可以自己写，也可以只依赖一个纯 SSE 包（比如 `mattt/EventSource`）。
2. **没有哪个现成库能同时满足下面这些要求**：三个 Provider、流式、tool calling、图片、PDF、自定义 base URL、BYOK、macOS 14。最接近的两个是：
   - `AIProxySwift`：三家都支持。但 Gemini 的 direct service 改不了 base URL，三家各用一套类型，版本还在 0.x。
   - `AnyLanguageModel`：抽象最统一。但不支持 PDF，API 形状跟 Apple Foundation Models 绑在一起，近一个月发了 8 个 0.x 版本。
3. **Google 没有能用于 BYOK 的官方 Swift SDK。**
   - `generative-ai-swift` 已经 archived，README 标题写着 "Obsolete - DO NOT USE"。
   - 替代品 Firebase AI Logic 必须建 Firebase 项目，生产流量走 `firebasevertexai.googleapis.com` 代理。直连 `generativelanguage.googleapis.com` 的 endpoint 只在 `#if DEBUG` 下才有。
   - 所以没法拿用户自己的 Gemini key 直连。
4. **Anthropic 也没有官方的 Swift Messages API SDK。** 官方的 `ClaudeForFoundationModels` 要求 macOS 27 beta，不满足 macOS 14+。
5. **自研的主要坑都有一手文档写明，可控：**
   - `AsyncBytes.lines` 会吞掉空行，而 SSE 靠空行分隔事件。
   - `: keep-alive` 注释和 `ping` 事件要跳过。
   - tool call 的参数是分片的 JSON 字符串，要按 index 拼起来。
   - 流中途可能出现 `error` 事件；遇到未知事件类型要忽略。
   - `timeoutIntervalForRequest` 是空闲超时，不是总超时。
   - 取消直接用 Swift 的 `Task.cancel()`。

---

## 1. 需求回顾（判断标准）

| 维度 | 需求来源 |
| --- | --- |
| 三个 Provider：OpenAI 兼容（DeepSeek、Ollama 等，需要自定义 base URL）、Anthropic Messages、Gemini | issue #2、`CONTEXT.md` |
| 流式输出 | issue #2 |
| tool calling：Web Search 在 app 侧实现，通过 tool calling 调用 | `CONTEXT.md`「Web Search」、README「联网问答」 |
| 图片输入（Screenshot）和 PDF 输入（「+」选的本地文件） | `CONTEXT.md`「Attachment」 |
| BYOK：客户端直连 Provider，不经第三方代理 | README「AI 后端」（key 存哪还没定，但没有自建后端） |
| macOS 14+，Swift Concurrency | 项目前提 |

---

## 2. 现有库逐个评估

### 2.1 MacPaw/OpenAI

- **仓库**：https://github.com/MacPaw/OpenAI ，MIT 协议。
  - 最新 release 是 `0.5.2`（2026-10-07）。
  - 近 6 个月（2026-04-08 起）有 188 个 commit，维护很活跃（来源：GitHub API [releases/latest](https://api.github.com/repos/MacPaw/OpenAI/releases/latest)、[commits](https://api.github.com/repos/MacPaw/OpenAI/commits)）。
- **覆盖范围**：只支持 OpenAI 协议（Chat Completions 和 Responses）。README 的原话是 "This SDK has a limited support for other providers like Gemini, Perplexity etc." 和 "The top priority of this SDK is OpenAI"（[README#support-for-other-providers](https://github.com/MacPaw/OpenAI#support-for-other-providers)）。
- **接兼容服务的坑**：
  - 其他服务返回的字段如果缺失或为 `null`，严格解码会失败，要打开 `.relaxed` parsing option（同上）。
  - 相关 issue：[#324 ModelResult decode failed for DeepSeek](https://github.com/MacPaw/OpenAI/issues/324)、[#283 Gemini fails to decode](https://github.com/MacPaw/OpenAI/issues/283)。
  - 请求侧传厂商私有参数的需求至今没解决：[#434 No support for vendor-specific parameters](https://github.com/MacPaw/OpenAI/issues/434)（open）。
- **流式**：
  - 接口是 `chatsStream(query:)`（[README#chat-completions](https://github.com/MacPaw/OpenAI#chat-completions)）。
  - 内部用基于 `URLSessionDataDelegate` 的 `StreamingSession`，配一个按 WHATWG 规范逐字节解析的 SSE parser（[StreamingSession.swift](https://github.com/MacPaw/OpenAI/blob/main/Sources/OpenAI/Private/Streaming/StreamingSession.swift)、[ServerSentEventsStreamParser.swift](https://github.com/MacPaw/OpenAI/blob/main/Sources/OpenAI/Private/Streaming/ServerSentEventsStreamParser.swift)）。自研时可以拿这个 parser 做参考。
  - 流式结果里有 DeepSeek 的 `reasoning_content` 字段（[ChatStreamResult.swift](https://github.com/MacPaw/OpenAI/blob/main/Sources/OpenAI/Public/Models/ChatStreamResult.swift)）。
- **tool calling**：支持（[README#function-calling](https://github.com/MacPaw/OpenAI#function-calling)）。
- **图片和 PDF**：`ChatQuery` 支持两种 content part：`image(ContentPartImageParam)` 和 `file(ContentPartFileParam)`，后者通过 `file_data` 传 base64（[ChatQuery.swift](https://github.com/MacPaw/OpenAI/blob/main/Sources/OpenAI/Public/Models/ChatQuery.swift)）。
- **自定义 base URL**：`OpenAI.Configuration` 可以设 `host`、`basePath`、`port`、`scheme`、`customHeaders`（[README#initialization](https://github.com/MacPaw/OpenAI#initialization)）。
- **Swift Concurrency**：
  - 同时提供 async/await、closure、Combine 三套 API，模型类型都标了 `Sendable`。
  - 取消时 "simply cancel the calling task, and corresponding underlying `URLSessionDataTask` would get cancelled automatically"（[README#cancelling-requests](https://github.com/MacPaw/OpenAI#cancelling-requests)）。
- **平台**：最低 `.macOS(.v10_15)`，依赖 `apple/swift-openapi-runtime`（[Package.swift](https://github.com/MacPaw/OpenAI/blob/main/Package.swift)）。
- **结论**：只看 OpenAI 兼容这一家的话，它是质量最好的 Swift 库。但它不管 Anthropic 和 Gemini，而且以 OpenAI 为准，第三方服务的字段差异只能靠 parsing option 兜底。

### 2.2 jamesrochabrun/SwiftOpenAI

- **仓库**：https://github.com/jamesrochabrun/SwiftOpenAI ，MIT 协议。最新 `4.6.3`（2026-10-05），近 6 个月 22 个 commit，11 个 open issue（GitHub API）。
- **覆盖范围**：
  - 只实现 OpenAI 协议。README 把 Anthropic、Gemini、Ollama、DeepSeek 等列为 "OpenAI-Compatible Providers"。
  - Anthropic 和 Gemini 用的是这两家各自提供的 OpenAI 兼容层：`overrideBaseURL` 设成 `"https://api.anthropic.com"`，或者 `"https://generativelanguage.googleapis.com"` 加 `v1beta`（[README#anthropic](https://github.com/jamesrochabrun/SwiftOpenAI#anthropic)、[README#gemini](https://github.com/jamesrochabrun/SwiftOpenAI#gemini)）。
  - Gemini 官方文档说这个兼容层 "is still in beta"，不支持的参数会被 "silently ignored"（[Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)）。
- **流式**：接口是 `startStreamedChat`，实现是 `urlSession.bytes(for:)` 加 `asyncBytes.lines`（[URLSessionHTTPClientAdapter.swift](https://github.com/jamesrochabrun/SwiftOpenAI/blob/main/Sources/OpenAI/Private/Networking/URLSessionHTTPClientAdapter.swift)）。
- **tool calling**：支持（[README#function-calling](https://github.com/jamesrochabrun/SwiftOpenAI#function-calling)）。
- **图片**：支持 `.imageUrl`（[README#vision](https://github.com/jamesrochabrun/SwiftOpenAI#vision)）。
- **PDF**：不支持。Chat Completions 的 content 类型只有 `text`、`imageUrl`、`inputAudio`，没有 `file` part（[ChatCompletionParameters.swift](https://github.com/jamesrochabrun/SwiftOpenAI/blob/main/Sources/OpenAI/Public/Parameters/Chat/ChatCompletionParameters.swift)）。而 OpenAI 的 Chat Completions 本身是接受 PDF `file` part 的（[OpenAI PDF files guide](https://developers.openai.com/api/docs/guides/pdf-files)）。
- **自定义 base URL**：用 `OpenAIServiceFactory.service(apiKey:overrideBaseURL:...)`。Ollama 的写法是 `service(baseURL: "http://localhost:11434")`（[README#ollama](https://github.com/jamesrochabrun/SwiftOpenAI#ollama)）。
- **平台**：README 写 macOS 13+，`Package.swift` 里声明的是 `.macOS(.v12)`（[Package.swift](https://github.com/jamesrochabrun/SwiftOpenAI/blob/main/Package.swift)）。

### 2.3 jamesrochabrun/SwiftAnthropic

- **仓库**：https://github.com/jamesrochabrun/SwiftAnthropic ，MIT 协议（LICENSE 文件到 2026-04 才补上，见 [commit 记录](https://github.com/jamesrochabrun/SwiftAnthropic/commits/main)）。
  - 最新 `2.2.2`（2026-04-18）。
  - 近 6 个月只有 4 个 commit；之前几个版本的间隔是 2025-10 → 2026-02 → 2026-04（[releases](https://github.com/jamesrochabrun/SwiftAnthropic/releases)）。
  - **维护偏慢。**
- **流式、tool calling、图片、PDF**：README 里都有对应章节：Message Stream、Function Calling、PDF Support（[README](https://github.com/jamesrochabrun/SwiftAnthropic#readme)）。
- **自定义 base URL**：`AnthropicServiceFactory.service(apiKey:apiVersion:basePath:)`（同上）。
- **平台**：`.macOS(.v12)`（[Package.swift](https://github.com/jamesrochabrun/SwiftAnthropic/blob/main/Package.swift)）。
- **结论**：功能齐全，但更新慢。Anthropic 文档说过 "new event types may be added"（见 §3.2），新事件类型和新字段都要等作者跟进。

### 2.4 Google：generative-ai-swift 与 Firebase AI Logic

**generative-ai-swift**：

- 仓库已 archived，最新 release 是 `0.5.6`（2024-08-22）。
- README 标题是 "[Obsolete - DO NOT USE] Google AI Swift SDK for the Gemini API"，正文写 "We don't plan to add anything to this SDK or make any further changes"，并让开发者改用 Firebase AI Logic（[README](https://github.com/google-gemini/generative-ai-swift)）。
- Gemini 官方 libraries 页面把它标成 "Not actively maintained"，说旧库 "are deprecated as of November 30th, 2025"，Swift 一栏写的是 "Use Firebase AI Logic"（[Gemini API libraries](https://ai.google.dev/gemini-api/docs/libraries)）。
- 官方 Google GenAI SDK 只有 Python、JS/TS、Go、Java、C#，**没有 Swift**（同上）。

**Firebase AI Logic**（`FirebaseAILogic`，在 [firebase-ios-sdk](https://github.com/firebase/firebase-ios-sdk) 里，Apache-2.0 协议，最新 `13.0.1`，2026-10-07）：

- **必须有 Firebase 项目**。入门文档要求 "select your Firebase project"，并推荐配合 App Check 使用。最低 iOS 15 / macOS 12，需要 Xcode 26.2+（[Get started](https://firebase.google.com/docs/ai-logic/get-started)）。
- **不能脱离 Firebase 直连**：
  - 源码里生产 endpoint 只有一个：`firebaseProxyProd = "https://firebasevertexai.googleapis.com"`。
  - 直连 `https://generativelanguage.googleapis.com` 的 `googleAIBypassProxy` 被包在 `#if DEBUG` 里，注释写着 "for SDK development and testing only"（[APIConfig.swift](https://github.com/firebase/firebase-ios-sdk/blob/main/FirebaseAI/Sources/Types/Internal/APIConfig.swift)）。
  - Firebase 项目没开 Firebase AI Logic API 时，SDK 会报错，要求 "to be enabled in your Firebase project"（[GenerativeAIService.swift](https://github.com/firebase/firebase-ios-sdk/blob/main/FirebaseAI/Sources/GenerativeAIService.swift)）。
- **结论**：它的设计前提是开发者用自己的 Firebase 项目替所有用户付费。这和本项目「用户自带 Gemini key 直连」的模式冲突，**排除**。
- 顺带一提，它的流式实现也是 `urlSession.bytes(for:)` 加 `stream.lines`，请求 URL 后面加 `?alt=sse`（[GenerativeAIService.swift](https://github.com/firebase/firebase-ios-sdk/blob/main/FirebaseAI/Sources/GenerativeAIService.swift)、[GenerateContentRequest.swift](https://github.com/firebase/firebase-ios-sdk/blob/main/FirebaseAI/Sources/GenerateContentRequest.swift)）。也就是说，Google 自己的 Swift SDK 也是在 URLSession 上手写 SSE。

### 2.5 lzell/AIProxySwift

- **仓库**：https://github.com/lzell/AIProxySwift ，MIT 协议。最新 `0.157.0`（2026-08-28），近 6 个月 21 个 commit。
- **覆盖范围**：
  - 支持 OpenAI、Gemini、Anthropic、DeepSeek 等十几家。
  - README 写 "Your initialization code determines whether requests go straight to the provider or are protected through the AIProxy backend"，并说明 BYOK 场景不需要配置 AIProxy 后端（[README](https://github.com/lzell/AIProxySwift#readme)）。
- **流式、tool calling、图片、PDF**：README 里有这些示例（[README](https://github.com/lzell/AIProxySwift#readme)）：
  - Anthropic：流式加 tool call、fine-grained tool streaming、PDF 输入。
  - Gemini：tool call、图片输入。
  - OpenAI 和 Gemini 的 PDF 本次没有逐个核实。
- **自定义 base URL**：
  - 支持：`openAIDirectService(unprotectedAPIKey:baseURL:requestFormat:)` 和 `anthropicDirectService(unprotectedAPIKey:baseURL:)`。
  - **不支持**：`geminiDirectService(unprotectedAPIKey:)` 没有 base URL 参数（[AIProxy.swift](https://github.com/lzell/AIProxySwift/blob/main/Sources/AIProxy/AIProxy.swift)）。
- **平台**：`.macOS(.v13)`（[Package.swift](https://github.com/lzell/AIProxySwift/blob/main/Package.swift)）。
- **结论**：三家都能接，但有三个问题：
  - 每家是一套独立的 request/response 类型，上层的统一抽象还是得自己写。
  - 版本号 0.157 说明没有稳定 API 的承诺。
  - 库的定位和商业重心在 AIProxy 代理服务上。

### 2.6 mattt/AnyLanguageModel

- **仓库**：https://github.com/mattt/AnyLanguageModel ，Apache-2.0 协议。
  - 最新 `0.16.0`（2026-10-04），近 6 个月 104 个 commit。
  - 2026-09-14 到 2026-10-04 之间发了 8 个 release（`0.12.0` → `0.16.0`）（[releases](https://github.com/mattt/AnyLanguageModel/releases)）。
- **定位**：作为 Apple Foundation Models 的 "drop-in replacement"，用同一个 `LanguageModelSession` 驱动 Ollama、Anthropic Messages、Gemini、OpenAI（Chat Completions 和 Responses）以及本地模型（[README](https://github.com/mattt/AnyLanguageModel#readme)）。
- **流式、tool calling、图片**：流式接口是 `streamResponse`。README 说 "Tool calling is supported by all providers"，图片输入在 OpenAI、Anthropic、Gemini 三家都标为 "yes"（同上）。
- **PDF**：**不支持**。
  - Anthropic 实现里的 content 类型只有 `text`、`image`、`tool_use`、`tool_result`、`thinking`，没有 `document`（[AnthropicLanguageModel.swift](https://github.com/mattt/AnyLanguageModel/blob/main/Sources/AnyLanguageModel/Models/AnthropicLanguageModel.swift)）。
  - 在仓库里做代码搜索，`application/pdf` 零结果。
- **自定义 base URL**：OpenAI、Anthropic、Gemini 三个 model 都有 `baseURL` 参数（README 的 OpenAI 段；[GeminiLanguageModel.swift](https://github.com/mattt/AnyLanguageModel/blob/main/Sources/AnyLanguageModel/Models/GeminiLanguageModel.swift)）。
- **平台**：macOS 14+，但要求 **Swift 6.3+ / Xcode 26.4+**（[README#requirements](https://github.com/mattt/AnyLanguageModel#requirements)）。
- **结论**：它的抽象层最接近我们想要的统一模型，但有三个问题：
  - 没有 PDF。
  - 工具循环由 session 驱动（可以用 `ToolExecutionDelegate` 拦截）。
  - 0.x 版本迭代极快，跟版本的成本高。

  适合当设计参考，不适合当底座。

### 2.7 anthropics/ClaudeForFoundationModels（Anthropic 官方）

- Anthropic 官方 SDK 只有 Python、TypeScript、C#、Go、Java、PHP、Ruby，**没有 Swift**（[SDKs overview](https://platform.claude.com/docs/en/cli-sdks-libraries/overview)）。
- 唯一的官方 Swift 包是 `ClaudeForFoundationModels`（[Apple Foundation Models 文档](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models)）：
  - 要求 "iOS 27, macOS 27 ... (all in beta)"，不满足 macOS 14+。
  - 文档明确说它 "is **not** a general-purpose Messages API client"，Files API、beta headers 等都不暴露。
- **排除。**

### 2.8 纯 SSE 包：mattt/EventSource

- **仓库**：https://github.com/mattt/EventSource ，MIT 协议，最新 `1.5.1`（2026-08-17）。
- **能力**：README 自称 "spec-compliant Server-Sent Events (SSE) client"（[README](https://github.com/mattt/EventSource#readme)）：
  - 支持 `LF`、`CR`、`CRLF` 三种换行。
  - 解析 `id`、`event`、`data`、`retry` 字段。
  - 可以直接对 `URLSession.bytes(for:)` 的返回值调用 `.events`。
- AnyLanguageModel 的 Anthropic 实现里就 `import EventSource`（[AnthropicLanguageModel.swift](https://github.com/mattt/AnyLanguageModel/blob/main/Sources/AnyLanguageModel/Models/AnthropicLanguageModel.swift)）。
- 它只负责把字节解析成 SSE 事件，不涉及任何 Provider 的语义。如果不想自己写 parser，这是自研方案里唯一值得考虑的依赖。

### 2.9 对比表

| 库 | 最新版本（日期） | 近 6 个月 commit | Provider 覆盖 | 流式 | tool calling | 图片 | PDF | 自定义 base URL | 最低 macOS | Concurrency | License |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | 0.5.2（2026-10-07） | 188 | 仅 OpenAI 兼容 | ✅ | ✅ | ✅ | ✅（`file` part） | ✅（host / basePath） | 10.15 | async/await、Combine、closure；`Sendable` | MIT |
| [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) | 4.6.3（2026-10-05） | 22 | OpenAI 兼容（Anthropic、Gemini 走各自的兼容层） | ✅ | ✅ | ✅ | ❌（Chat 无 `file` part） | ✅ | 12（README 写 13） | async/await | MIT |
| [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) | 2.2.2（2026-04-18） | 4 | 仅 Anthropic | ✅ | ✅ | ✅ | ✅ | ✅（basePath） | 12 | async/await | MIT |
| [generative-ai-swift](https://github.com/google-gemini/generative-ai-swift) | 0.5.6（2024-08-22） | 已 archived | Gemini | — | — | — | — | — | — | — | —（已废弃） |
| [Firebase AI Logic](https://firebase.google.com/docs/ai-logic/get-started) | firebase-ios-sdk 13.0.1（2026-10-07） | 活跃 | 仅 Gemini（经 Firebase 代理） | ✅ | ✅ | ✅ | 未核实 | ❌（直连仅 DEBUG） | 12 | async/await | Apache-2.0 |
| [AIProxySwift](https://github.com/lzell/AIProxySwift) | 0.157.0（2026-08-28） | 21 | OpenAI、Anthropic、Gemini、DeepSeek 等 | ✅ | ✅ | ✅ | Anthropic ✅，其余未核实 | OpenAI、Anthropic ✅；Gemini ❌ | 13 | async/await | MIT |
| [AnyLanguageModel](https://github.com/mattt/AnyLanguageModel) | 0.16.0（2026-10-04） | 104 | OpenAI、Anthropic、Gemini、Ollama、本地 | ✅ | ✅（session 驱动） | ✅ | ❌ | ✅ | 14（需 Swift 6.3） | async/await | Apache-2.0 |
| [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) | 0.2.3（2026-10-07，beta） | 活跃 | 仅 Anthropic | ✅ | ✅ | ✅ | ❌（不暴露 Files API） | ✅ | **27 beta** | Foundation Models | Apache-2.0 |
| 自研（URLSession + SSE） | — | — | 三家都按官方协议实现 | ✅ | ✅ | ✅ | ✅ | ✅ | 12（`bytes(for:)` 的要求） | 原生 | — |

表中的 commit 数和日期来自 GitHub REST API（`/repos/{owner}/{repo}/releases/latest` 和 `/commits?since=2026-04-08`），其余各格的来源见 §2.1–2.8。

---

## 3. 自研方案评估：URLSession `bytes(for:)` + SSE

### 3.1 基础能力

- **`URLSession.bytes(for:delegate:)`**：macOS 12.0 起可用，"delivers an asynchronous sequence of bytes"（[Apple 文档](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:))）。收到响应头就返回，body 以 `AsyncSequence` 的形式边到边交（[WWDC21 "Use async/await with URLSession"](https://developer.apple.com/videos/play/wwdc2021/10095/)）。
- **取消**：
  - 同一个 WWDC 讲座说 "Swift concurrency's cancellation works with URLSession async methods"，示例就是对 `Task` 调 `cancel()`（同上）。
  - MacPaw 的 README 也说，取消 Task 会自动取消底层的 data task（[README#cancelling-requests](https://github.com/MacPaw/OpenAI#cancelling-requests)）。
  - 所以 Quick Panel 的「停止生成」只要 `task.cancel()` 就行，不需要额外写 delegate。
- **主流 SDK 内部也是这么写的**：Google 自己的 Firebase AI SDK（[GenerativeAIService.swift](https://github.com/firebase/firebase-ios-sdk/blob/main/FirebaseAI/Sources/GenerativeAIService.swift)）和 SwiftOpenAI（[URLSessionHTTPClientAdapter.swift](https://github.com/jamesrochabrun/SwiftOpenAI/blob/main/Sources/OpenAI/Private/Networking/URLSessionHTTPClientAdapter.swift)）都是 `bytes(for:)` 加逐行解析。

### 3.2 已知坑与对策

| 坑 | 一手来源 | 对策 |
| --- | --- | --- |
| `AsyncBytes.lines` **会跳过空行**，而 SSE 正是靠空行触发事件分发 | [Apple Developer Forums #725162](https://developer.apple.com/forums/thread/725162)；[WHATWG SSE 解析规则](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation) | 自己按字节切行（处理 `\n`、`\r`、`\r\n`），或者用 `mattt/EventSource`。<br>补充：三家 Provider 的每个事件都是单行 `data:` 里的一段 JSON，而且自带 `type` 字段，所以 Firebase 和 SwiftOpenAI 用 `.lines` 也能跑。但这不符合规范，遇到多行 `data:` 就会出错。 |
| **等待时的保活**：DeepSeek 流式请求排队时会不断发 `: keep-alive` 注释，非流式请求则发空行；排队超过 10 分钟还没开始推理，服务端会断开连接 | [DeepSeek Rate Limit](https://api-docs.deepseek.com/quick_start/rate_limit) | 解析器忽略以 `:` 开头的注释行 |
| Anthropic 的流里会夹杂任意数量的 `ping` 事件 | [Anthropic Streaming#ping-events](https://platform.claude.com/docs/en/build-with-claude/streaming#ping-events) | 跳过 |
| **流到一半出错**：Anthropic 可能在 HTTP 200 的流里发 `event: error`，比如 `overloaded_error`（非流式请求时对应 HTTP 529） | [Anthropic Streaming#error-events](https://platform.claude.com/docs/en/build-with-claude/streaming#error-events) | 统一事件类型里要有 `.error`；UI 要能显示「生成到一半失败了」 |
| **未知事件类型**：文档原话是 "new event types may be added, and your code should handle unknown event types gracefully" | [Anthropic Streaming#other-events](https://platform.claude.com/docs/en/build-with-claude/streaming#other-events) | 用宽松的 enum 解码（带 `unknown` case），不要因为新字段或新类型就抛错。MacPaw 的 #283、#324 就是严格解码惹的问题 |
| **tool call 参数分片到达**：<br>• Anthropic 用 `input_json_delta.partial_json` 分片，到 `content_block_stop` 时才完整。<br>• OpenAI 兼容服务（如 DeepSeek）的 `delta.tool_calls` 带 `index`，文档说 "The first chunk of each tool call carries the `id`, `type` and `function` fields; subsequent chunks only carry the function arguments" | [Anthropic Streaming#input-json-delta](https://platform.claude.com/docs/en/build-with-claude/streaming#input-json-delta)；[DeepSeek create-chat-completion](https://api-docs.deepseek.com/api/create-chat-completion) | 按 block index 或 tool call index 累积字符串，等这个调用的参数收齐再用 `JSONDecoder` 解析 |
| **Gemini 的流式不太一样**：要请求 `:streamGenerateContent?alt=sse`；`FunctionCall` 以完整的 Part（`functionCall { id, name, args }`）出现，不分片 | [Gemini generate-content API](https://ai.google.dev/api/generate-content) | Gemini adapter 不用拼参数，但仍然要输出统一的 tool-call 事件 |
| Gemini thinking 模型的签名（thought signature）要在多轮对话里原样传回去，推理才能连贯 | [Gemini Thinking#signatures](https://ai.google.dev/gemini-api/docs/thinking#signatures) | 持久化 Message 时，保留 Provider 私有的不透明字段 |
| **超时的语义**：`timeoutIntervalForRequest` 是「等新数据」的空闲超时，"The timer ... is reset whenever new data arrives"，默认 60 秒 | [Apple 文档](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest) | 别拿它当流式请求的总时长上限。推理模型在第一个 token 之前可能长时间没有输出（DeepSeek 靠 keep-alive 撑着），可以适当调大；总时长由 app 层自己给 Task 加超时 |
| 非 2xx 响应的错误体也从 `bytes` 流里出来，得自己读 | MacPaw 给错误体设了 256 KB 的缓冲上限（[StreamingSession.swift](https://github.com/MacPaw/OpenAI/blob/main/Sources/OpenAI/Private/Streaming/StreamingSession.swift)） | 先检查 `HTTPURLResponse.statusCode`；不是 2xx 就读有限长度的字节，解析错误 JSON |
| Ollama 的 OpenAI 兼容层：`image_url` 不能传 URL，只能传 base64；不支持 `tool_choice` | [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility) | Screenshot 一律用 base64 data URL 发送（反正本来就是本地图片） |
| Gemini 的 OpenAI 兼容层 "still in beta"，没列出的参数会被 "silently ignored" | [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) | Gemini 走原生的 `generateContent` 协议，不走兼容层 |

### 3.3 三家的图片和 PDF 编码（自研需要实现的部分）

- **OpenAI 兼容**：
  - 图片用 `image_url`（data URL）。
  - PDF 用 `file` part 的 `file_data`。Chat Completions 的 `file` part 只接受 PDF；单个文件和整个请求的所有文件合计都要小于 50 MB（[OpenAI PDF files](https://developers.openai.com/api/docs/guides/pdf-files)）。
  - DeepSeek 的 content part 也有 `image_url` 和 `file` 两种（[DeepSeek create-chat-completion](https://api-docs.deepseek.com/api/create-chat-completion)）。
- **Anthropic**：PDF 用 `document` content block，传 base64 的 `application/pdf`。整个请求最大 32 MB，最多 600 页；上下文窗口小于 1M 时最多 100 页（[Anthropic PDF support](https://platform.claude.com/docs/en/build-with-claude/pdf-support)）。
- **Gemini**：
  - 媒体用 `Part.inlineData`，类型是 `Blob { mimeType, data(base64) }`（[generate-content API](https://ai.google.dev/api/generate-content)）。
  - PDF 最大 50 MB 或 1000 页（[Document processing](https://ai.google.dev/gemini-api/docs/document-processing)）。
  - 认证用请求头 `x-goog-api-key`（[API key 文档](https://ai.google.dev/gemini-api/docs/api-key)）。

### 3.4 工作量估计（推断，没有来源依据）

- **SSE 字节解析器**：照 WHATWG 规则实现，可以对照 MacPaw 的 [ServerSentEventsStreamParser.swift](https://github.com/MacPaw/OpenAI/blob/main/Sources/OpenAI/Private/Streaming/ServerSentEventsStreamParser.swift)。大约 100–200 行，加单元测试。
- **每个 Provider adapter**：估计各 300–500 行。要做两件事：
  - 编码请求：messages、system、text / image / PDF parts、tools schema、tool results。
  - 把流事件转成统一事件：`textDelta`、`reasoningDelta`、`toolCall(id, name, argsJSON)`、`usage`、`finish(reason)`、`error`。
- **测试**：把官方文档里的 SSE 示例原文存成 fixture 做 golden test（比如 Anthropic 文档里带 tool use 的完整 HTTP 流），不需要真实 key。
- **合计**：大约一个人 1–2 周。三家协议都是公开、稳定的 REST + SSE。

---

## 4. 推荐：全部自研（可以只依赖一个纯 SSE 解析包）

**结论**：不用任何 LLM SDK。自己定义 `LLMClient` 协议，写三个 Provider adapter，底层用 `URLSession.bytes(for:)`。SSE 解析器自己写，或者依赖 `mattt/EventSource`。

**理由**：

1. **没有一个库能覆盖全部需求**（§2.9）。
   - 按 Provider 混用三个库（MacPaw + SwiftAnthropic + ……），Gemini 那一格还是空的：官方 SDK 要么已废弃，要么强绑 Firebase（§2.4），只能再加一个第三方库或者自己写。
   - 混用还意味着三套类型、三套错误、三套流式 API。上层的统一抽象终究得自己写。
   - 库真正能省掉的只有「JSON 编解码 + SSE」这一层，而这恰好是最容易写、也最容易测的部分。
2. **Web Search 是 app 侧的 tool**（`CONTEXT.md`）。整个 tool 循环必须由我们统一控制，而且跨 Provider 行为一致：模型发起调用 → app 执行搜索 → 把结果作为 tool result 回填 → 继续流式输出。AnyLanguageModel 这类把 tool 循环收进 session 的库，会把这条关键路径藏起来。
3. **Attachment 需要 PDF。** SwiftOpenAI 和 AnyLanguageModel 不支持 PDF，AIProxySwift 只确认了 Anthropic 支持。而三家的原生协议都支持 PDF（§3.3），自研只是多写一种 content part。
4. **兼容服务之间有差异**：DeepSeek 多一个 `reasoning_content` 字段，Ollama 不支持 URL 图片，Gemini 兼容层会静默忽略参数。以 OpenAI 为准的库只能靠宽松解码兜底（MacPaw #283、#324、#434）；自研的 adapter 可以针对已知服务单独处理。
5. **BYOK 直连**：Firebase AI Logic 和 AIProxy 的主线设计都是「开发者付费 + 走代理」，和本项目「用户自带 key 直连」的模式对不上（§2.4、§2.5）。
6. **依赖和升级风险**：
   - 候选库大多是 0.x 而且迭代很快：AnyLanguageModel 3 周发了 8 个版本，AIProxySwift 已经到 0.157。
   - 要么就更新很慢：SwiftAnthropic 半年只有 4 个 commit。
   - Provider 新增事件类型时（Anthropic 明确说会加），自研只需要改一个 adapter 里的 `switch`。
7. **自研的坑都有明确的一手文档和对策**（§3.2）。业界 SDK（包括 Google 自家的 Firebase SDK）本来也是在 URLSession 上手写 SSE。

**落地顺序建议**（推断）：

1. SSE parser 和 OpenAI 兼容 adapter（覆盖 v1 的 DeepSeek，顺带 Ollama）
2. Anthropic adapter
3. Gemini 原生 adapter

每一步都拿官方文档里的流示例做 fixture 测试。实现时可以把 MacPaw 的 SSE parser 和 AnyLanguageModel 的 Provider 分层当阅读参考（两者分别是 MIT 和 Apache-2.0 协议），但不把它们作为依赖引入。

**什么情况下会改主意**：

- 后来决定只支持 OpenAI 兼容这一个 Provider：可以直接用 MacPaw/OpenAI（打开 `.relaxed` 解析）。
- AnyLanguageModel 发布 1.0 并补上 PDF：可以重新评估把它当统一层。
