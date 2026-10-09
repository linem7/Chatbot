# Provider adapter 只做单次模型调用，Turn 驱动工具循环，一个 Turn 只产生一条 Message

> 2026-10-09 修订（#11）：Web Search 改用 Provider 的原生能力（见 [ADR-0003](0003-web-search-provider-native-only.md)），由 adapter 负责，不再是 Turn 执行的 app 侧工具。下文已按修订后的结论更新。

三种 Provider（OpenAI 兼容、Anthropic Messages、Gemini）的流式 tool call 格式、原生搜索格式和消息结构差别很大，我们把这些差异全部关在 adapter 里。每个 adapter 只提供两个操作：「一次模型调用」和「拉取 Model 列表」。

「一次模型调用」把各家的流统一成以下几种事件：
- 文本片段；
- tool call 开始、tool call 参数片段、tool call 完成（用于 app 侧工具，v1 没有）；
- Web Search 开始（带查询词）、Citation；
- 结束（带原因）。

原生 Web Search 的开启、搜索次数上限，以及搜索结果块和引用的解析，都由 adapter 完成。

app 层的 Turn 负责把一次回答需要的多次模型调用串起来：执行 app 侧工具并把结果交回模型、处理 Provider 要求的续接（例如 Anthropic 的 `pause_turn`）、处理取消。这套逻辑只实现一份。v1 没有 app 侧工具，但 Turn 仍然保留，因为续接需要它。

领域模型**不照搬** API 的「assistant → tool → assistant」多消息结构。一个 Turn 只产生一条 assistant Message，内部是有序的内容块（工具调用、工具结果、搜索、正文和它的 Citation）。序列化时由 adapter 还原成各家要求的消息结构。

Provider 原生的不透明数据挂在对应的内容块上，只由 adapter 读写，必须逐字保存、原样回传。例如 Gemini 的 `thoughtSignature`，以及 Anthropic 的 `server_tool_use` 和 `web_search_tool_result` 块（其中有 `encrypted_content`）。

## Considered Options

- **每个 adapter 自己跑完整的工具循环**：否决。三家的循环逻辑完全相同，这样会写三遍，而且次数上限、超时、取消要分别处理三次。
- **领域 Message 照搬 API，增加 `tool` 角色**：否决。UI、历史、删除和 Retry 都以「一问一答」为单位，把一次回答拆成多条 Message，这些功能都要先把它们重新拼回去。

## Consequences

- 原生 Web Search 是 adapter 的职责。Turn 和 UI 只看到统一的「搜索开始」和 Citation 事件。
- 以后增加 app 侧工具，只需要改 Turn 和工具定义，不需要改 adapter 的流解析。
- 持久化层必须能保存每个内容块上的不透明数据，不能只保存渲染后的文本。
