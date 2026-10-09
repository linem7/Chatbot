# Handoff：开始 v1 实现（2026-10-09）

上一个 session 完成了 Chatbot v1 的全部规划（Wayfinder 地图 #1 及其子 ticket #2–#16，均已关闭）。新 session 的任务是**写代码**，从 #17 开始。

## 先读这些（按顺序）

1. `CLAUDE.md`：工作方式，以及 ticket 和 label 的约定。
2. `MEMORY.md`：用户偏好和当前进度。这里没有重复它的内容，开始前一定要读。
3. 当前要做的 ticket：`gh issue view 17`。每个实现 ticket 都写明了范围、完成标准和依赖。
4. ticket 引用的章节：`docs/SPEC.md`（功能）、`docs/ARCHITECTURE.md`（实现）、`CONTEXT.md`（术语）、`docs/adr/0001`–`0005`（关键取舍）。
5. 做到 Provider 相关的 ticket（#18、#23、#24）时，读 `docs/research/provider-capabilities.md` 和 `docs/research/swift-llm-clients.md`。
6. 做到 Hotkey 和面板（#19）时，读 `docs/research/hotkey-and-panel.md`。

## 实现 ticket（label `v1`）

| # | 内容 | 依赖 |
|---|---|---|
| #17 | 工程骨架 | 无 |
| #18 | 核心链路：Domain、SSE、DeepSeek adapter、Turn | #17 |
| #19 | 最小可用版本：菜单栏、Hotkey、Quick Panel、流式回答 | #18 |
| #20 / #21 / #22 | 本地历史 / 附件 / 设置与首次启动 | #19 |
| #23 → #24 → #25 | Anthropic、Gemini、错误展示完善 | 按顺序依赖 |

这个顺序就是 `docs/ARCHITECTURE.md` §9 的实现顺序。

## 动手前要注意

- **#17 第一步是核实**：`gonzalezreal/swift-markdown-ui` 当前是否还在维护，然后选定代码高亮器（`docs/ARCHITECTURE.md` §8 第 1 条）。结论要写回 ARCHITECTURE 的依赖表。如果改用别的库，先用 AskUserQuestion 问用户。
- **构建环境**：上一个 session 运行在 Linux 上，没法构建 macOS app。用户在 Mac 上开发，工程要求 macOS 26 和 Xcode。
  - 如果新 session 也在 Linux 上：只能写代码，再靠 CI（push 到 main 和 PR 时运行）或用户在 Mac 上验证。汇报时要明确说出哪些内容没有经过编译。
  - `ChatbotCore` 里只要不依赖 Apple 框架的部分（比如 SSE 解析器），可以考虑在 Linux 上用 `swift test` 先测，前提是装了 Swift toolchain。
- **仓库已经是 public**（用户为了让 macOS runner 免费而改的）。CI 设计成 push 到 main 和 PR 时都跑，不签名，也不发布。v1 只自用，不发 Release，不做更新检查。
- **工程里的固定值**：bundle id `com.linem7.Chatbot`，Swift 6 语言模式，测试用 Swift Testing，用 XcodeGen 生成工程（只提交 `project.yml`）。

## 其他

- Quick Panel 原型在 `prototype/quick-panel` 分支上，在线查看：https://claude.ai/artifact/91wkjCMTEVn2hBE36hZEJH 。最终选定的是「B · 聊天窗式」，结论记在 #15 里。GitHub Pages 目前是关闭的。

## 建议使用的技能

- `mattpocock-skills:tdd`：#18 的 SSE 解析器、三个 adapter 的流解码和错误映射，都适合先写 fixture 测试（ARCHITECTURE §3.3 要求用官方文档的流示例做 fixture）。
- `claude-api`：做 #23（Anthropic adapter、`web_search` 工具、`pause_turn`）之前先加载它，核对最新的 API 细节。
- `mattpocock-skills:diagnosing-bugs`：遇到构建、并发或流解析的疑难问题时使用。
- `mattpocock-skills:grilling` + `mattpocock-skills:domain-modeling`：实现中如果遇到 SPEC 没覆盖的决策，或者术语需要调整，用它们。提问一律用 AskUserQuestion；术语有变化就当场更新 `CONTEXT.md`。
- `mattpocock-skills:code-review` 或 `code-review`：每个 ticket 完成、开 PR 之前用。
- `run`：在 Mac 上启动 app、验证改动时用。
- `mattpocock-skills:writing-for-agents`：修改 `CLAUDE.md` 时用。
