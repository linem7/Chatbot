# Chatbot

macOS 菜单栏 AI 助手，用原生 Swift + SwiftUI 开发。目前处于**规划阶段，还没有代码**。

## 任务从哪来

所有工作都由 GitHub issue 驱动（`linem7/Chatbot`）。其中 #1 是 Wayfinder 地图，写着这个阶段的终点、已锁定的前提、已定的决策和尚未讨论的问题。开始任何 ticket 之前，先读 #1 和这个 ticket 本身。

按 label 区分 ticket 类型：
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
