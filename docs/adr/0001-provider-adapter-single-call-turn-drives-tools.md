# Provider adapter 只做单次模型调用，Turn 驱动工具循环，一个 Turn 只产生一条 Message

三种 Provider（OpenAI 兼容、Anthropic Messages、Gemini）的流式 tool call 格式和消息结构差别很大，我们把这些差异全部关在 adapter 里。每个 adapter 只提供两个操作：「一次模型调用」和「拉取 Model 列表」。前者把各家的流统一成五种事件：文本片段、tool call 开始、tool call 参数片段、tool call 完成、结束。工具循环（执行 Web Search、把结果交回模型、限制调用次数、处理取消）只由 app 层的 Turn 实现一份。

领域模型**不照搬** API 的「assistant → tool → assistant」多消息结构。一个 Turn 只产生一条 assistant Message，内部是有序的内容块（工具调用、工具结果、正文）。序列化时由 adapter 在工具结果处切开，还原成各家要求的消息结构。

Provider 原生的不透明数据（例如 Gemini 的 `thoughtSignature`）挂在对应的内容块上，只由 adapter 读写，必须逐字保存、原样回传。

## Considered Options

- **每个 adapter 自己跑完整的工具循环**：否决。三家的循环逻辑完全相同，这样会写三遍，而且次数上限、超时、取消要分别处理三次。
- **领域 Message 照搬 API，增加 `tool` 角色**：否决。UI、历史、删除和 Retry 都以「一问一答」为单位，把一次回答拆成多条 Message，这些功能都要先把它们重新拼回去。

## Consequences

- adapter 不知道 Web Search 的存在。以后增加新工具只需要改 Turn 和工具定义，不需要改 adapter。
- 持久化层必须能保存每个内容块上的不透明数据，不能只保存渲染后的文本。
