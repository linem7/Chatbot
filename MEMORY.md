# Memory

跨会话需要记住、但从代码和 git 历史里看不出来的信息。内容过时时直接修改或删除。

## 用户

- 个人开发者，用中文交流，GitHub 账号 linem7，在做一个自用的 macOS 聊天助手。
- 做决策时务实、偏向砍功能：「快速解决问题」是最高优先级，复杂问题会去别的工具解决。对推荐答案通常直接同意，只在和这个定位冲突时反驳，比如否掉了思考模式、中途换模型、记录 token 用量、内置截图。凡是已经有成熟外部工具能做的事（例如截图），用户倾向于不在 app 里重做，提问前先想一下这个功能是否真的需要。用户也不想额外接第三方服务（例如否掉了 Tavily），宁可接受功能缺失。用户说的「tool call 搜索」指的是模型 API 的原生搜索。
- 用户强调过：DeepSeek 能看图，只是不能生成图片。图片支持以 `/models` 返回的能力为准，不要凭研究文档断言某个 DeepSeek 模型不支持图片。
- grilling 等需要用户做选择的提问，**用 AskUserQuestion 工具来问**（2026-10-09 用户明确要求），推荐项放在第一个并标「（推荐）」。不要在聊天里直接列出编号问题。
- 用户的 macOS 是**英文系统**（2026-10-09 真机验证时发现）。README 等文档里提到 macOS 的 app、菜单、设置位置、系统弹窗，以及 Chatbot 自己的界面文字时，一律写英文原文（例如 Keychain Access、System Settings › Privacy & Security、Settings 的 General 页、Launch at Login），正文仍然用中文。app 的界面文字以 `App/Resources/Localizable.xcstrings` 的英文 key 为准。

## 进度和待办（截至 2026-10-10）

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
- 2026-10-10 用户决定发布 **v1.0.0** 给朋友安装，推翻此前“v1 只自用、不发 Release”的决定。采用本机固定自签名构建、Apple Silicon ZIP、手动上传 GitHub Release；最低 macOS 26，不做公证或自动更新。用户明确跳过本次发布前测试和试装。
- 2026-10-09 应用户要求，仓库最终改为 **public**（来回改过几次），这样 macOS runner 不收费。CI 在 push 到 main 和 PR 时都跑构建和测试。GitHub Pages 已从 `gh-pages` 分支重新开启。
- **2026-10-09 v1 实现完成**：实现 ticket #17–#25 全部关闭，PR 是 #26–#38、#40、#41（#39 是真机验证清单 issue）。用户在 Mac 上完成了真机验证，#39 已关闭。
- **2026-10-09 真机反馈处理完成**：地图 #45「v1.1：真机反馈」已关闭（调研 PR #52，实现 PR #55–#58），用户复测通过。用户在这一轮定的，都已写进文档：
  - OpenRouter 用平台自带联网并显示引用；百炼只开搜索、不显示来源；按 base URL 的 host 识别平台，「+」里加了两个模板；地球按钮默认开：ADR-0003（修订）、SPEC §5；
  - 经中转的 Claude / Gemini 用 Custom 模板选原生格式，接口没报告能力时按模型名查内置表兜底：ARCHITECTURE §3.2；
  - 设置窗口和 Main Window 不随失焦隐藏，开着时临时出现在 Dock 和 ⌘Tab：SPEC §1。
  - 「旧 Connection 消失」是误会：用户没注意到 Connection 页的「+」按钮（#50 以 not planned 关闭）。
- #59–#67 都已关闭，见「进度（追加）」。**当前没有打开的 issue**。
- 实现阶段新定的几条，都已经写进文档，以文档为准：
  - 用户本人定的：
    - 其他 app 的 Hotkey 冲突检测不到，只给静态提示：SPEC §2.1；
    - 生成中按 ⌘N，先停止当前回答（保留为 Interrupted）再新开：SPEC §2.4；
    - Claude 的思考「能关就关」，关不掉的压到最低档：ADR-0002；
    - system prompt 的当前日期由 app 在发送时加在最前面，不在可编辑文本里：SPEC §3、ARCHITECTURE §5.1；
    - 在 Main Window 里继续对话，是把对话装回 Quick Panel 继续：SPEC §8。
  - lead 定的，或者按用户的原则推出来的：
    - 生成中切换 Model 也和 ⌘N 一样，先停止再新开 Conversation：SPEC §3；
    - Sonnet 5.5 用 `thinking: between_tools` 关闭思考：ADR-0002、ARCHITECTURE §3.2；
    - Gemini 的思考档位和能力来自内置表 `GeminiModelTable`：ADR-0002、ARCHITECTURE §3.2；
    - 错误按钮表里 `authentication` 也给「重试」：SPEC §7。
- v1 有意不建 App 的测试 target：ChatStore 等 App 侧逻辑目前靠 #39 的真机清单验证，v1 之后再考虑补测试。

## 进度（追加）

- 2026-10-09：百炼的联网能力判断修掉了。之前假设「百炼平台上所有 Model 都能联网」，实际文档的清单按模型名给、而且分地域（北京 / 新加坡 / 全球三张表，全球地域上一个 DeepSeek 都没有）。新增 `BailianModelTable` 查表，`Platform.bailian` 带上地域。**这条推翻了 ADR-0003 原来的说法**，ADR-0003 / SPEC / ARCHITECTURE / research 都已同步。用户要求直接收尾，**没有走 PR**，直接推到了 main（commit 4f45099）。
- 2026-10-09：#59（Quick Panel 可以固定，一直在最前）实现完并合进 main（PR #60）。决策（用户已确认）：固定后 Esc、Hotkey、失焦都**不再**收起面板，只能点图钉取消固定；**不**跨重启记住；开关是 Quick Panel 顶栏的图钉按钮。`hide()` 是唯一的收口，守卫放在那一处。
- 2026-10-09：#63（面板可拖动）和 #64（Hotkey 支持连按两次 ⌘）实现完，在 PR #65 里。决策（用户已确认）：只有顶栏空当能拖、位置不持久化（重启回到偏上居中）；⌘ 双击接受辅助功能权限、没授权之前组合键继续可用。两项都已编译、装到 /Applications，真机验证通过。
- 2026-10-09：真机发现 PR #65 的拖动区把顶栏撑高了（NSView 没有固有高度，塞进 HStack 会被竖直拉伸）。修法（PR #66，合并人 linem7）：中间换回 `Spacer(minLength: 0)`，`HeaderDragArea` 挪进整条顶栏的 `.background`。用户 2026-10-10 确认顶栏高度恢复。
- 2026-10-10：**#62、#63、#64 收尾关闭**——每个 issue 下写了结论评论、按 completed 关闭、并在 #1 的「Decisions so far」追加了一行。同一时间远端没有别的待合 PR。本地 `main` 已同步到 `4dc099c`；`/Applications` 里装的就是这个提交的内容（和 `462c0d8` 无 diff）。
- 2026-10-10：清理分支——本地五个已并入 main 的旧分支（`quick-panel-header-height`、`quick-panel-drag-hotkey`、`quick-panel-pin`、`fix/bailian-deepseek-v41-web-search`、`fix/bailian-web-search-model-table`）和远端两个（`quick-panel-drag-hotkey`、`quick-panel-pin`，均已合入 main）都已删除。远端现在只剩 `main` 和 `gh-pages`（原型页，保留）。
- 2026-10-10：**以 #1 为准**（用户确认）。#59 关闭时漏掉的那一行已补进 #1 的「Decisions so far」，按关闭顺序排在 #62/#63/#64 前面。
- 2026-10-10：**#67 以 not planned 关闭**（用户决定）。代码没改过——`AppWindow.openSettings` 仍是 `NSApp.activate()` 后立刻 `openSettings()`、100ms 后 `orderFrontRegardless()` + `makeKey()`；用户判断窗口按钮和 Toggle 画成非激活样式只是视觉问题、不影响使用，v1.0.0 不修。结论已追加到 #1。**至此所有 issue 都关掉了。**
- 2026-10-10：两件悬着的事情，用户决定**都不动**——v1.1 那批（#46–#54）的结论只有 #45 地图里有、不搬进 #1；CI 保持 push 到 main 和 PR 都跑，不改成只在 PR 时跑。
- 2026-10-10：本地 `main` 已跟到 `27bca41`（「发布 v1.0.0：安装包脚本与安装指引」，另一个会话推的：新增 `docs/INSTALL.md`、`docs/releases/v1.0.0.md`、`scripts/package-release.sh`，版本号改成 1.0.0，并把「v1 只自用、不发 Release」的决定改成发布给朋友手动安装）。
- 2026-10-10：#68（Web Search 默认关闭）完成，PR #69 已合（用户真机测过）。决策（用户已确认）：每个新 Conversation 都从关开始、不记住上一次；Settings › General 加「新对话默认联网」开关（默认关）。
- 2026-10-10：发布 **v1.0.1**（版本号由用户指定）。相对 v1.0.0 只有 #68 一项改动：联网搜索默认关闭 + 「新对话默认联网」开关。动了 `project.yml` 的 MARKETING_VERSION、README 和 `docs/INSTALL.md` 的版本号与下载链接、SPEC §11（改成不写死版本号），新增 `docs/releases/v1.0.1.md`；用 `scripts/package-release.sh` 打包，ZIP 和 .sha256 传到 GitHub Release。
- 2026-10-10：#70 已解决，PR #71 已合并。用户在 Mac 上安装修复分支后确认百炼 `qwen3.8-max` 图片输入正常，验证结论已记入 PR 和 issue。修法是 `BailianModelTable.acceptsImages` 按模型名查表，并在运行时补上已保存 Connection 的图片能力；调研在 `docs/research/bailian-vision-models.md`。用户要求以 **v1.0.2** 发布，沿用本机固定自签名、Apple Silicon ZIP 和 SHA-256 校验文件。

## 偏好补充

- 给用户看的网页、原型，要给出**能直接点开的链接**，不要让用户下载文件或切分支再看。可以用 Claude Artifact 发布（Quick Panel 原型：https://claude.ai/artifact/91wkjCMTEVn2hBE36hZEJH ），也可以在征得用户同意后用 GitHub Pages。修改仓库可见性前要先问用户。
- **当前这台机器就是用户的 Mac**（2026-10-09 起；`Chaopais-Mac-mini.local`，arm64，macOS 27.0，Apple Swift 6.4）。Xcode 27.0 装在 `/Applications/Xcode-27.0.0.app`（**版本号带后缀**，不是 `/Applications/Xcode.app`），`xcode-select` 已指过去。可以直接构建和跑测试，改动能本地验证，不用只靠 CI：
  - `xcodebuild -project Chatbot.xcodeproj -scheme Chatbot -configuration Debug -derivedDataPath build build`
  - `swift test --package-path Packages/ChatbotCore`
  - 装 app 用 `./scripts/install.sh`。
- **网络**：GitHub、Apple 的 CDN 直连不通（curl 15 秒超时、0 字节），命令行工具（git、gh、xcodebuild 拉包）要挂代理，例如 `export https_proxy=http://127.0.0.1:8118 http_proxy=http://127.0.0.1:8118`，详见记忆 `github-needs-local-proxy`。**不要**改全局 git 代理配置（用户没同意过）。`xcodebuild` 尤其要注意：SPM 解析依赖时会在 `DerivedData/.../SourcePackages/checkouts/` 里 `git clone` 各个包，不挂代理就**卡在那里不动**（不是报错，是一直等），看起来像编译慢。构建前记得 export 代理。
- 更早的会话在另一台 Linux 机器上跑（swiftly 装 Swift 6.3.3、GRDB 要解 libsqlite3-dev、没有 `URLSession.bytes(for:)`）。那些说明在 Mac 上都不适用：这台没有 `~/.local/share/swiftly`。
