# Chatbot

macOS 菜单栏 AI 助手，用原生 Swift + SwiftUI 开发。规划阶段已经完成，**还没有代码**。功能以 `docs/SPEC.md` 为准，实现方案以 `docs/ARCHITECTURE.md` 为准（其中 §8 是实现前要核实的事，§9 是建议的实现顺序）。

## 任务从哪来

所有工作都由 GitHub issue 驱动（`linem7/Chatbot`，私有仓库）。规划阶段（Wayfinder 地图 #1）已经结束，现在是实现阶段：实现 ticket 带 `v1` label（#17–#25），按 `docs/ARCHITECTURE.md` §9 的顺序做，每个 ticket 写明了范围、完成标准和依赖。开工前先读这个 ticket，以及它引用的 SPEC 和 ARCHITECTURE 章节。

这台开发机可能是 Linux，没法构建 macOS app。改动只能靠 CI（PR 时运行）或用户在 Mac 上验证，汇报时要说明哪些内容没有经过编译验证。

规划阶段用过的 ticket 类型（以后再开规划类 ticket 时沿用）：
- `wayfinder:research`：用 `research` 技能，结论写入 `docs/research/<name>.md`。
- `wayfinder:grilling`：用 `grilling` 和 `domain-modeling` 技能，逐轮向用户提问，用户确认后才落地。
- `wayfinder:prototype`、`wayfinder:task`：按 ticket 描述执行。

关闭一个 ticket 时做三件事：在 ticket 下评论结论，关闭它，再在 #1 的「Decisions so far」里追加一行（格式见那一节的注释）。

## 记忆

`MEMORY.md` 记录跨会话要记住的信息：用户的偏好、当前进度、还没做完的收尾。每次会话开始时先读它。有新的进度或偏好时更新它，内容过时就删掉。

## 术语和决策

- `CONTEXT.md` 是术语表。写代码、文档、issue 时都用里面的词，避开每个词条 _Avoid_ 下列出的说法。术语有变化时当场更新。
- `docs/adr/` 记录不容易推翻的设计决策。改动 Provider 抽象、消息模型、模型调用参数之前，先读相关的 ADR。

## 用户和产品取向

- 用户通过 API 使用模型，**绝大部分时候用 DeepSeek**，不接本地模型。设计时优先保证 DeepSeek 的体验。
- 产品定位是「快速解决问题」：所以不开思考，不展示推理，也不做重量级的会话管理。新功能也以这个定位为准。
- 文档、issue 和回复都用中文，代码标识符用英文。
