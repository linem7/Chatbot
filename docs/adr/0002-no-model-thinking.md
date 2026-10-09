# 所有请求都关闭模型思考，UI 也不展示推理过程

> 2026-10-09 修订（#23）：Anthropic 的部分模型无法关闭思考，改为按 `/v1/models` 的 capabilities 处理，见下文的 Anthropic 一段。主旨不变。

这个 app 的定位是「快速解决问题」，需要深度推理的复杂问题，用户会去别的工具里解决。思考会明显拖慢首字出现的时间，所以所有请求都尽量关闭思考：

- **DeepSeek**：发 `thinking: disabled`。
- **Anthropic**：能关就关，按 `/v1/models` 的 capabilities 处理。
  - Model 能关闭思考（`thinking.types.disabled.supported` 为 true）时，发 `thinking: {type: "disabled"}`。
  - Claude Sonnet 5.5 发 disabled 会返回 400，但可以用 `thinking: {type: "between_tools"}` 关闭（effort 不超过 high，我们用 low）。
  - 关不掉的（Claude Opus 5.5、Fable）走默认的 adaptive。
  - 只要 Model 支持 low effort，都发 `output_config.effort: "low"`，把思考和延迟压到最少。
  - Model 返回的思考块不展示，作为不透明数据原样回传（[ADR-0001](0001-provider-adapter-single-call-turn-drives-tools.md)）。
- **Gemini**：部分模型无法完全关闭思考，请求最低的思考级别，并丢弃思考内容。

UI 里没有推理区域，也没有思考开关。

## Considered Options

- **不在模型选择器里提供关不掉思考的 Anthropic 模型**：否决。那样就用不了 Opus 5.5 和 Sonnet 5.5；用 low effort 已经能把思考压到很少。

## Consequences

- DeepSeek 在 thinking 模式下有一条硬约束：只要请求带 tools，就必须回传历史上所有的 `reasoning_content`，否则返回 400。关闭思考后这条约束不再适用。
- 协议要求回传的签名（Gemini 的 `thoughtSignature`、Anthropic 思考块的 `signature`）仍然必须保存并原样回传，按 ADR-0001 作为不透明数据挂在内容块上。
- Anthropic 的思考块绑定产生它的模型和对话：只能在同一个 Model 上原样回传；Conversation 创建后不换 Model 保证了这一点。绑定的前缀不只是之前的消息，**还包括顶层的 `system` 和 `tools`**。system prompt 里的日期隔天会变、用户会改 system prompt、地球按钮会增减 tools，前缀对不上时，较新的账号会一直收到 400，重试也没用。我们这样处理：
  - adaptive 的 Model（Opus 5.5、Fable）：回传思考块时声明 `block_binding.prefix_mismatch_behavior: "drop_block"`（beta `thinking-binding-controls-2026-08-01`），对不上的块由服务端丢掉，回答照常进行；
  - `between_tools`（Sonnet 5.5）不接受 `block_binding`：之前完成的回答里的思考块一律不回传，前缀因此始终一致；
  - `disabled` 的 Model 不产生思考块。
- 关不掉思考的 Anthropic 模型，首字仍会比其他模型慢一些，这是接受的代价。
- 以后如果要加回思考，需要重新处理 DeepSeek 的 `reasoning_content` 回传和 UI 展示。
