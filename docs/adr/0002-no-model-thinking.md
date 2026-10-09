# 所有请求都关闭模型思考，UI 也不展示推理过程

这个 app 的定位是「快速解决问题」，需要深度推理的复杂问题，用户会去别的工具里解决。思考会明显拖慢首字出现的时间，所以所有请求都关闭思考：DeepSeek 发 `thinking: disabled`，Anthropic 不开 thinking。对于无法完全关闭思考的模型（Gemini 的部分模型），请求最低的思考级别，并丢弃思考内容。UI 里没有推理区域，也没有思考开关。

## Consequences

- DeepSeek 在 thinking 模式下有一条硬约束：只要请求带 tools，就必须回传历史上所有的 `reasoning_content`，否则返回 400。关闭思考后这条约束不再适用。
- 协议要求回传的签名（Gemini 的 `thoughtSignature`）仍然必须保存并原样回传，按 [ADR-0001](0001-provider-adapter-single-call-turn-drives-tools.md) 作为不透明数据挂在内容块上。
- 以后如果要加回思考，需要重新处理 DeepSeek 的 `reasoning_content` 回传和 UI 展示。
