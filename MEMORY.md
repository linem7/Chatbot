# Memory

跨会话需要记住、但从代码和 git 历史里看不出来的信息。内容过时时直接修改或删除。

## 用户

- 个人开发者，用中文交流，GitHub 账号 linem7，在做一个自用的 macOS 聊天助手。
- 做决策时务实、偏向砍功能：「快速解决问题」是最高优先级，复杂问题会去别的工具解决。对推荐答案通常直接同意，只在和这个定位冲突时反驳，比如否掉了思考模式、中途换模型、记录 token 用量、内置截图。凡是已经有成熟外部工具能做的事（例如截图），用户倾向于不在 app 里重做，提问前先想一下这个功能是否真的需要。用户也不想额外接第三方服务（例如否掉了 Tavily），宁可接受功能缺失。用户说的「tool call 搜索」指的是模型 API 的原生搜索。
- 用户强调过：DeepSeek 能看图，只是不能生成图片。图片支持以 `/models` 返回的能力为准，不要凭研究文档断言某个 DeepSeek 模型不支持图片。
- grilling 等需要用户做选择的提问，**用 AskUserQuestion 工具来问**（2026-10-09 用户明确要求），推荐项放在第一个并标「（推荐）」。不要在聊天里直接列出编号问题。

## 进度和待办（截至 2026-10-09）

- #2–#6 五个研究 ticket 已关闭，研究文档都在 main 的 `docs/research/` 下。远程的 `research/*` 分支已于 2026-10-09 删除，相关链接已改为指向 main。
- #7（Provider 抽象）已关闭，产出 `CONTEXT.md`、`docs/adr/0001`、`docs/adr/0002`。
- #8（Hotkey 与 Quick Panel 行为）已关闭，结论在 issue 评论里。
- #9 以「不做」关闭：v1 没有内置截图，用户用其他工具截图后粘贴。粘贴细节并入 #10，#1、#10、#16 的描述已同步修改；#3 的截图研究只作存档。
- #10（Attachment）已关闭。用户提出的「超过 1 个月没有新消息的 Conversation 自动删除」在 #12 里定为 30 天静默清理。
- #11（Web Search）已关闭：只用 Anthropic、Gemini 的原生搜索，DeepSeek 不联网（ADR-0003）；ADR-0001 已同步修订；#5 的 Tavily 研究只作存档。
- #12（本地历史）已关闭：用 GRDB 存储（ADR-0004），30 天静默清理，标题由模型生成，支持全文搜索，永远不做导出。
- #13（设置）已关闭：key 存 Keychain，设置是独立窗口，分三个标签页；去掉了「手动覆盖 Model Capabilities」（修改了 #7 的结论，已在 #7 补充说明）；界面做中英文，跟随系统。
- #14（工程基线）已关闭：最低支持 macOS 26；工程用 XcodeGen 生成；分层是 App target 加本地 SPM 包 ChatbotCore；用自签名证书签名、不做公证（ADR-0005）；CI 负责构建和测试（v1 不发布、不做更新检查，见下）；日志只用 os.Logger；Swift 6 + Swift Testing；bundle id 是 com.linem7.Chatbot。
- #15（Quick Panel 原型）已关闭：用户选了 **B · 聊天窗式**（固定高度、顶部是模型选择器和标题、消息用气泡、输入框在底部）。B 方案的原型发布在 GitHub Pages：https://linem7.github.io/Chatbot/ （源是孤儿分支 `gh-pages`，只有 `index.html` 和 `.nojekyll`）。`prototype/quick-panel` 分支已删除；含三个变体的完整版只剩 Claude Artifact 那份。
- #1 里剩下的三项 Not yet specified 已经定了（结论记在 #16 的评论里）：Markdown 用完整 GFM 加代码高亮，用 MarkdownUI 渲染；不截断上下文，超长时提示新开对话；错误显示在回答里并给出下一步；回答上悬停时显示「复制」。
- 2026-10-09：#16 和地图 #1 都已关闭，**规划阶段结束**。功能以 `docs/SPEC.md` 为准，实现以 `docs/ARCHITECTURE.md` 为准。
- v1 **只自用**：在本机构建安装；不发 GitHub Release，不做更新检查。
- 2026-10-09 应用户要求，仓库最终改为 **public**（来回改过几次），这样 macOS runner 不收费。CI 在 push 到 main 和 PR 时都跑构建和测试。GitHub Pages 已从 `gh-pages` 分支重新开启。
- **2026-10-09 v1 实现完成**：实现 ticket #17–#25 全部关闭，PR 是 #26–#38、#40、#41（#39 是真机验证清单 issue）。**下一步是用户在 Mac 上按 #39 逐项验证**，发现的问题再开 issue。
- 实现阶段新定的几条，都已经写进文档，以文档为准：
  - 用户本人定的：
    - 其他 app 的 Hotkey 冲突检测不到，只给静态提示：SPEC §2.1；
    - 生成中按 ⌘N，先停止当前回答（保留为 Interrupted）再新开：SPEC §2.4；
    - Claude 的思考「能关就关」，关不掉的压到最低档：ADR-0002；
    - system prompt 的当前日期由 app 在发送时加在最前面，不在可编辑文本里：SPEC §3、ARCHITECTURE §5.1；
    - 在 Main Window 里继续对话，是把对话装回 Quick Panel 继续：SPEC §8。
  - lead 定的，或者按用户的原则推出来的：
    - 生成中切换 Model 也先停止再切换（同 ⌘N）：SPEC §3；
    - Sonnet 5.5 用 `thinking: between_tools` 关闭思考：ADR-0002、ARCHITECTURE §3.2；
    - Gemini 的思考档位和能力来自内置表 `GeminiModelTable`：ADR-0002、ARCHITECTURE §3.2；
    - 错误按钮表里 `authentication` 也给「重试」：SPEC §7。
- v1 有意不建 App 的测试 target：ChatStore 等 App 侧逻辑目前靠 #39 的真机清单验证，v1 之后再考虑补测试。

## 偏好补充

- 给用户看的网页、原型，要给出**能直接点开的链接**，不要让用户下载文件或切分支再看。可以用 Claude Artifact 发布（Quick Panel 原型：https://claude.ai/artifact/91wkjCMTEVn2hBE36hZEJH ），也可以在征得用户同意后用 GitHub Pages。修改仓库可见性前要先问用户。
- **当前这台机器是 Linux**，没法构建和运行 Swift/macOS app。用户在 Mac 上开发，CI 用 macOS runner。在这里只能写代码、写文档，要说明代码没有经过编译验证。
  - 2026-10-09 起这台机器装了 Swift 6.3.3（swiftly，在 `~/.local/share/swiftly`，没改 shell 配置），可以在 Linux 上跑 ChatbotCore 的 `swift test`。用之前先 `source ~/.local/share/swiftly/env.sh`。系统没有 SQLite 头文件，GRDB 要用解到用户目录的 libsqlite3-dev，在仓库根目录执行：
    `swift test --package-path Packages/ChatbotCore -Xcc -I$HOME/.local/share/sqlite3-dev/root/usr/include -Xlinker -L$HOME/.local/share/sqlite3-dev/root/usr/lib/x86_64-linux-gnu`
  - Linux 上没有 `URLSession.bytes(for:)`，`URLSessionTransport` 只在 Darwin 上编译，真实网络调用和 App target 仍然只能靠 CI 或用户在 Mac 上验证。
  - 这台机器内存紧张：等 CI 时在前台查结果，不要开后台常驻的监视进程。
