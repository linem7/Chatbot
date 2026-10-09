# Memory

跨会话需要记住、但从代码和 git 历史里看不出来的信息。内容过时时直接修改或删除。

## 用户

- 个人开发者，用中文交流，GitHub 账号 linem7，在做一个自用的 macOS 聊天助手。
- 做决策时务实、偏向砍功能：「快速解决问题」是最高优先级，复杂问题会去别的工具解决。对推荐答案通常直接同意，只在和这个定位冲突时反驳，比如否掉了思考模式、中途换模型、记录 token 用量、内置截图。凡是已经有成熟外部工具能做的事（例如截图），用户倾向于不在 app 里重做，提问前先想一下这个功能是否真的需要。用户也不想额外接第三方服务（例如否掉了 Tavily），宁可接受功能缺失。用户说的「tool call 搜索」指的是模型 API 的原生搜索。
- 用户强调过：DeepSeek 能看图，只是不能生成图片。图片支持以 `/models` 返回的能力为准，不要凭研究文档断言某个 DeepSeek 模型不支持图片。
- grilling 等需要用户做选择的提问，**用 AskUserQuestion 工具来问**（2026-10-09 用户明确要求），推荐项放在第一个并标「（推荐）」。不要在聊天里直接列出编号问题。

## 进度和待办（截至 2026-10-09）

- #2–#6 五个研究 ticket 已关闭。它们的分支已合并到 main，但远程 `research/*` 分支还保留着；各 issue 评论里的文档链接仍指向这些分支，删分支前要先把链接改成指向 main。
- #7（Provider 抽象）已关闭，产出 `CONTEXT.md`、`docs/adr/0001`、`docs/adr/0002`。
- #8（Hotkey 与 Quick Panel 行为）已关闭，结论在 issue 评论里。
- #9 以「不做」关闭：v1 没有内置截图，用户用其他工具截图后粘贴。粘贴细节并入 #10，#1、#10、#16 的描述已同步修改；#3 的截图研究只作存档。
- #10（Attachment）已关闭。用户新提出「超过 1 个月没有新消息的 Conversation 自动删除」，已写进 #12 的描述，待在 #12 里细化。
- #11（Web Search）已关闭：只用 Anthropic、Gemini 的原生搜索，DeepSeek 不联网（ADR-0003）；ADR-0001 已同步修订；#5 的 Tavily 研究只作存档。
- #12（本地历史）已关闭：用 GRDB 存储（ADR-0004），30 天静默清理，标题由模型生成，支持全文搜索，永远不做导出。
- #13（设置）已关闭：key 存 Keychain，设置是独立窗口，分三个标签页；去掉了「手动覆盖 Model Capabilities」（修改了 #7 的结论，已在 #7 补充说明）；界面做中英文，跟随系统。
- #14（工程基线）已关闭：最低支持 macOS 26；工程用 XcodeGen 生成；分层是 App target 加本地 SPM 包 ChatbotCore；用自签名证书签名、不做公证（ADR-0005）；CI 负责构建、测试和按 tag 发布；更新只做「有新版本」提示；日志只用 os.Logger；Swift 6 + Swift Testing；bundle id 是 com.linem7.Chatbot。
- #15（Quick Panel 原型）已关闭：用户选了 **B · 聊天窗式**（固定高度、顶部是模型选择器和标题、消息用气泡、输入框在底部）。原型在 `prototype/quick-panel` 分支上，不进 main。
- #1 里剩下的三项 Not yet specified 已经定了（结论记在 #16 的评论里）：Markdown 用完整 GFM 加代码高亮，用 MarkdownUI 渲染；不截断上下文，超长时提示新开对话；错误显示在回答里并给出下一步；回答上悬停时显示「复制」。
- 2026-10-09：#16 和地图 #1 都已关闭，**规划阶段结束**。功能以 `docs/SPEC.md` 为准，实现以 `docs/ARCHITECTURE.md` 为准。
- 仓库是私有的，所以 v1 **只自用**：在本机构建安装；不发 GitHub Release，不做更新检查；CI 只在 PR 时跑构建和测试（私有仓库的 macOS runner 按 10 倍消耗免费额度）。
- 实现 ticket 按 ARCHITECTURE §9 的顺序创建，都带 `v1` label。下一步从「实现 1：工程骨架」开始。
- 仓库在 2026-10-09 曾短暂改成 public 来开 GitHub Pages，同一天又应用户要求改回了 **private**。免费账号的私有仓库没有 Pages，原来的 Pages 链接已经失效。

## 偏好补充

- 给用户看的网页、原型，要给出**能直接点开的链接**，不要让用户下载文件或切分支再看。仓库是私有的，所以用 Claude Artifact 发布（Quick Panel 原型：https://claude.ai/artifact/91wkjCMTEVn2hBE36hZEJH ）。修改仓库可见性前要先问用户。
- **当前这台机器是 Linux**，没法构建和运行 Swift/macOS app。用户在 Mac 上开发，CI 用 macOS runner。在这里只能写代码、写文档，要说明代码没有经过编译验证。
