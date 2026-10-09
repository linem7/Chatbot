# 研究：OpenRouter 和阿里云百炼的联网搜索 API

- 对应 issue：[#47 研究：OpenRouter 和阿里云百炼的联网搜索 API](https://github.com/linem7/Chatbot/issues/47)（Part of #45）
- 日期：2026-10-09
- 前提：用户通过 OpenRouter 和阿里云百炼（下称「百炼」）用 DeepSeek，Connection 的 Provider 是 OpenAI 兼容。ADR-0003 规定 OpenAI 兼容的 Connection 不联网，所以地球按钮是灰的。
- 来源：只用两家的官方文档、官方 API reference（OpenAPI）和官方 SDK 源码。没有 API key，所以没有发过任何需要鉴权的请求；标「实际请求」的是无鉴权的公开接口。

## TL;DR

1. **OpenRouter 能给 DeepSeek 联网，而且给的是标准的 `url_citation`**。推荐的开法是在 `tools` 里加 `{"type": "openrouter:web_search"}`（server tool，Beta），由模型决定搜不搜、搜几次。旧的 `plugins: [{id: "web"}]` 和模型名加 `:online` 已经标为 deprecated，它们每个请求固定搜一次。DeepSeek 没有原生搜索，所以 OpenRouter 改用 Exa：每次搜索 $0.007，含 10 条结果，超出部分每条 $0.001（`max_results` 最多 25），搜到的内容另按输入 token 计费。流式响应里，引用出现在 `choices[].delta.annotations[]`，类型是 `url_citation`，字段有 `url`、`title`、`content`、`start_index`、`end_index`。**偏移按什么单位算，官方没有写**；官方 SDK 把 `title` 和偏移都当成可选字段。
2. **百炼的 OpenAI 兼容接口可以开联网，但不返回来源**。在请求体顶层加 `enable_search: true` 就能开，DeepSeek（deepseek-v4-pro / v4-flash / v3.2 等）在支持之列。但官方明确说 OpenAI 兼容 Chat Completions「不支持返回搜索来源和角标标注」，响应里连「这次有没有搜」都判断不出来。来源（`search_info.search_results`）和 `[1]`、`[ref_1]` 角标只有 DashScope 原生协议有。走 Responses API 的话，只返回 URL 列表，没有标题，也没有角标。计费：除了多出来的输入 token，北京地域默认的 turbo 策略每千次 3 元。
3. **怎么判断平台和能力**：OpenRouter 的 host 是 `openrouter.ai`，百炼的 host 都在 `aliyuncs.com` 下（`dashscope*.aliyuncs.com` 和 `{WorkspaceId}.{region}.maas.aliyuncs.com`）。两家的 `/models` 都看不出「这个模型能不能联网」：
   - OpenRouter 的 server tool 对任何模型都能用（没有原生搜索的就退到 Exa）。
   - 百炼只能按官方模型清单写死。
4. **和关闭思考可以一起用**，但现在 app 在这两个平台上**都没有关思考**：
   - OpenRouter 发 `reasoning: {enabled: false}`，或者 `effort: "none"`；
   - 百炼发 `enable_thinking: false`；
   - 两者跟搜索参数互相独立。
   - 问题在于，现有 adapter 只在 host 是 `deepseek.com` 时才发 `thinking: disabled`。而 DeepSeek V4 在这两个平台上**默认开着思考**（OpenRouter `/models` 的 `reasoning.default_enabled: true`，百炼文档写着「默认开启思考模式」）。这和 ADR-0002 冲突，跟联网是两回事，建议单独开 issue。
5. **OpenRouter 可以用原生 Anthropic Messages 格式调 Claude**：端点是 `POST https://openrouter.ai/api/v1/messages`。请求里的 `tools` 接受 `web_search_20250305` 和 `web_search_20260209`，响应和流里有 `web_search_tool_result`、`citations_delta`、`web_search_result_location`，跟 Anthropic 原生一样。但它**只认 `Authorization: Bearer`**，现有 Anthropic adapter 发的是 `x-api-key`；`/models` 返回的也是 OpenRouter 自己的格式。所以要让 Anthropic adapter 指向 OpenRouter，至少得改鉴权头和拉模型列表这两处。另外，百炼也有 Anthropic 兼容接口（`/apps/anthropic`），但文档里的 `tools` 只有 function tool，没有提 web_search。

---

## 1. OpenRouter

### 1.1 怎么开启联网

一共三种开法，官方推荐第一种。

| 方式 | 请求里怎么写 | 谁决定搜不搜 | 状态 |
| - | - | - | - |
| Server tool | `tools: [{"type": "openrouter:web_search", "parameters": {...}}]` | 模型，每个请求 0 到 N 次 | Beta，官方推荐 |
| Web plugin | `plugins: [{"id": "web", ...}]` | 总是搜，每个请求搜一次 | deprecated |
| `:online` 后缀 | `"model": "deepseek/deepseek-v4-flash:online"` | 同 plugin，完全等价 | deprecated |

来源：[Web Search server tool](https://openrouter.ai/docs/guides/features/server-tools/web-search)（「Migrating from the Web Search Plugin」一节：「The web search plugin … and the `:online` variant are deprecated. Use the `openrouter:web_search` server tool instead.」）；[Web Search plugin](https://openrouter.ai/docs/guides/features/plugins/web-search)。

Server tool 的 `parameters`（全部可选，来源同上「Configuration」表）：

- `engine`：`auto`（默认）、`native`、`exa`、`firecrawl`、`parallel`、`perplexity`。`auto` 的意思是模型有原生搜索就用原生的，没有就用 Exa。
- `max_results`：每次搜索返回的结果数，1–25，默认 5。使用原生搜索时这个参数会被忽略。
- `max_uses`：一个请求里最多搜几次。用原生搜索时，这个值**只会转发给 Anthropic**。
- `max_total_results`：整个请求里结果总数的上限。
- `search_context_size`（`low`/`medium`/`high`）、`max_characters`：控制每条结果带多少内容。
- `allowed_domains`、`excluded_domains`、`user_location`。
- 顶层还有 `max_tool_calls`，是所有 server tool 共用的步数预算，默认 30，最多也是 30（[Server Tools · Tool Call Limits](https://openrouter.ai/docs/guides/features/server-tools)）。

Plugin 的参数是 `engine`、`max_results`（默认 5）、`search_prompt`、`include_domains`、`exclude_domains`。它的默认 search prompt 要求模型「Cite them using markdown links named using the domain of the source」（[Web Search plugin](https://openrouter.ai/docs/guides/features/plugins/web-search)），也就是说回答正文里会出现 Markdown 链接。

### 1.2 哪些模型能用，DeepSeek 用的是哪个引擎

- **任何模型都能用**：「The `openrouter:web_search` server tool gives any model on OpenRouter access to real-time web information.」（[server tool](https://openrouter.ai/docs/guides/features/server-tools/web-search)）
- 有原生搜索的只有 OpenAI、Anthropic、Google、SpaceXAI、Perplexity 这几家的部分模型（同页「Native Search Providers」），**DeepSeek 不在其中**，所以 `auto` 会退到 Exa。
- 实际请求核对过：公开的 `GET https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints` 返回的所有 endpoint，`native_tools` 都是 `{}`。按 [Server Tools · Native Execution](https://openrouter.ai/docs/guides/features/server-tools) 的说法，有原生搜索的 endpoint 会写成 `"openrouter:web_search": {...}`。

### 1.3 计费

来源：[server tool · Pricing](https://openrouter.ai/docs/guides/features/server-tools/web-search)。

- Exa 的 `auto`、`fast`、`instant` 每次搜索 $0.007，含 10 条结果，超出的每条 $0.001。
- 原生搜索按各家原价转收。
- 「All pricing is in addition to standard LLM token costs for processing the search result content.」：搜到的内容还要按输入 token 计费。
- Plugin 文档补充：「Using web search will incur extra costs, even with free models.」
- 用量统计：响应的 `usage.server_tool_use.web_search_requests` 是这个请求实际搜了几次。

### 1.4 响应里的搜索结果和引用

**格式**：OpenRouter 把所有模型的搜索结果都统一成 OpenAI Chat Completions 的 annotation 格式（[plugin · Parsing web search results](https://openrouter.ai/docs/guides/features/plugins/web-search)）：

```json
"annotations": [
  {
    "type": "url_citation",
    "url_citation": {
      "url": "https://www.example.com/web-search-result",
      "title": "Title of the web search result",
      "content": "Content of the web search result", // Added by OpenRouter if available
      "start_index": 100, // The index of the first character of the URL citation in the message.
      "end_index": 200 // The index of the last character of the URL citation in the message.
    }
  }
]
```

用 Exa 时，`content` 是从网页里抽出的几段摘录，段与段之间用 `[...]` 隔开（[server tool · Exa](https://openrouter.ai/docs/guides/features/server-tools/web-search)）。

**流式响应里在哪**：

- 官方 guide 和 OpenAPI 都没有写流式的位置。Chat Completions 的 OpenAPI 里，`ChatStreamDelta` 只列了 `content`、`reasoning`、`reasoning_details`、`refusal`、`role`、`tool_calls`、`audio`，**没有 `annotations`**（[Create a chat completion](https://openrouter.ai/docs/api/api-reference/chat/create-a-chat-completion)）。
- OpenRouter 官方的 Vercel AI SDK provider（[`OpenRouterTeam/ai-sdk-provider`](https://github.com/OpenRouterTeam/ai-sdk-provider)，commit `1b22b05`）在流式 chunk 的 schema 里定义了 `choices[].delta.annotations[]`，也从这里取出 `url_citation`：
  - `src/chat/schemas.ts`：`OpenRouterStreamChatCompletionChunkSchema`；
  - `src/chat/index.ts`：`if (delta.annotations) { … }`。
  
  它的 e2e 测试 `e2e/issues/issue-63-web-search-annotations.test.ts` 用真实的 `:online` 模型验证过，流式路径能拿到 sources。**所以以这份官方 SDK 源码为准：引用放在 `delta.annotations` 里，可能和正文 delta 不在同一个 chunk。**
- 字段是否一定存在：官方 SDK 的 schema 里，`title`、`start_index`、`end_index`、`content` 都是 optional，注释写的是「title, start_index, end_index are optional as some upstream providers may omit them」。测试里有只带 `url` 的流式 chunk（见附录 A.2）。

**偏移单位**：**官方文档没有写**，只说是「The index of the first/last character」。OpenRouter 文档没定义「character」指什么，OpenAI 文档也没有。现有的 `CitationSpan.textRange` 用的是 UTF-16 偏移（`Domain/Message.swift`），所以中文和 emoji 会不会错位，只能拿真实回答验证。还有一点：plugin 的 search prompt 让模型用 Markdown 链接引用，Exa 路径给出的 `start_index`/`end_index` 有没有意义，也要实测。

**「正在搜索」信号**：Chat Completions 流里，**官方文档没有说明有什么搜索开始或结束的事件**。

- 流里会穿插 `: OPENROUTER PROCESSING` 注释行，官方说可以拿来显示加载状态（[Streaming](https://openrouter.ai/docs/api_reference/streaming)），现有的 SSE 解析器会把它当注释丢掉。
- 另外，`GET /api/v1/tools` 的 schema 说，server tool 调用在 Chat Completions 里会以 `reasoning_details[].type` 的形式出现（[List server tools](https://openrouter.ai/docs/api/api-reference/tools/list-server-tools)，`ServerToolOutputName.type` 的描述）。对应的 schema 是 `ReasoningDetailServerToolCall`（`type: "reasoning.server_tool_call"`，带 `tool_name`、`arguments`、`result`）。不过 guide 里没有 web search 的实例，这个只能当成线索，要真机验证。

### 1.5 `/models` 能不能看出某个模型支持联网

实际请求：`GET https://openrouter.ai/api/v1/models`，无鉴权，2026-10-09 共返回 469 个模型。

- 每个模型的 `supported_parameters` 里**都没有 server tool 相关的项**。`web_search_options` 只出现在 19 个模型上（Perplexity、部分 GPT-4o 等），DeepSeek 都没有。
- 原生搜索只能从单个模型的 endpoints 接口查 `native_tools`。但 server tool 本来就对任何模型都能用，所以「能不能联网」对 OpenRouter 来说可以直接当成「能」，区别只在走原生搜索还是 Exa、价格不同。
- `GET /api/v1/tools`（列出 server tool 和每个工具支持哪些模型）需要鉴权，没有核对。

### 1.6 和关闭思考一起用

来源：[Reasoning Tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)。

- 统一参数是 `reasoning`：`"effort": "none"` 是「Disables reasoning entirely」；`reasoning.enabled` 是开关；`exclude: true` 只是不返回推理内容，**照样推理、照样计费**，不能拿来关思考。
- `/models` 里每个模型的 `reasoning` 对象有 `mandatory` 和 `default_enabled` 两个字段。文档说：「`mandatory`: When `true`, hide disable controls and do not send `effort: "none"` — the model rejects it.」
- 实际请求到的 DeepSeek 条目：

  | 模型 | `mandatory` | `default_enabled` | `supported_efforts` |
  | - | - | - | - |
  | `deepseek/deepseek-v4.1-flash` | false | true | `["max", "high", "low"]` |
  | `deepseek/deepseek-v4-pro`、`deepseek/deepseek-v4-flash` | false | （没有这个字段） | `["xhigh", "high"]` |
  | `deepseek/deepseek-v3.2` | false | false | — |

  也就是说都能关。v4.1-flash 默认是开着的。
- 搜索参数（`tools`/`plugins`）和 `reasoning` 是不同的字段，文档没有说两者互斥。
- 注意：现有 OpenAI 兼容 adapter 只在 `isDeepSeek`（host 是 `deepseek.com`）时才发 `thinking: {type: "disabled"}`，见 `Domain/Connection.swift`。对 OpenRouter 什么都不发，所以 v4.1-flash 等模型现在是开着思考跑的。

### 1.7 怎么识别是 OpenRouter

- 官方 base URL 是 `https://openrouter.ai/api/v1`（OpenAPI 的 `servers`）。
- 地域端点 `us.openrouter.ai`、`eu.openrouter.ai`：`eu` 上没有任何搜索引擎，`us` 上只有 Exa（[server tool · Privacy and regional availability](https://openrouter.ai/docs/guides/features/server-tools/web-search)）。
- 判断规则：host 是 `openrouter.ai`，或者以 `.openrouter.ai` 结尾。`eu.openrouter.ai` 仍然算 OpenRouter（关闭思考等字段照样要发），但**不支持联网**：EU 端点上没有任何搜索引擎可用。

### 1.8 用原生 Anthropic Messages 格式调 Claude（影响 #49）

- **有这个端点**：`POST https://openrouter.ai/api/v1/messages`，OpenRouter 的描述是「Creates a message using the Anthropic Messages API format」（[Create a message](https://openrouter.ai/docs/api/api-reference/anthropic-messages/create-a-message)）。官方的 Anthropic Agent SDK 和 Claude Code 集成，就是把 `ANTHROPIC_BASE_URL` 设成 `https://openrouter.ai/api`（[Anthropic Agent SDK](https://openrouter.ai/docs/guides/community/anthropic-agent-sdk)）。现有 adapter 的拼法是 base URL 加 `v1/messages`，路径上能对上。
- **鉴权不同**：OpenAPI 的 `securitySchemes` 写的是「API key as bearer token in Authorization header」。OpenRouter 的 Claude Code 指南专门解释过，要用 `ANTHROPIC_AUTH_TOKEN`（发 `Authorization: Bearer`），不要用 `ANTHROPIC_API_KEY`（发 `x-api-key`）。现有 Anthropic adapter 发的是 `x-api-key`，见 `AnthropicAdapter.swift`。
- **能用 Anthropic 原生搜索**：
  - 请求的 `tools` 接受 `{"type": "web_search_20250305", "name": "web_search", "max_uses": …}` 和 `web_search_20260209` 两个版本（同一 OpenAPI 里的 tool 定义）。
  - 响应的 content block 有 `web_search_tool_result`；流里有 `citations_delta`，citation 的类型包括 `web_search_result_location`（字段：`url`、`title`、`cited_text`、`encrypted_index`）。这些和 Anthropic 原生一致，现有 Anthropic adapter 的解析逻辑可以直接用。
  - `GET /api/v1/tools` 的 schema 说明，`web_search_20250305` 这类写法是 `openrouter:web_search` 在 `anthropic-messages` 格式下的别名，调用会以 `server_tool_use`（name `web_search`）的形式出现。Claude 的 endpoint 在 `native_tools` 里映射到 `web_search_20260209`（[Server Tools · Native Execution](https://openrouter.ai/docs/guides/features/server-tools) 的示例）。所以走 Claude 时用的是 Anthropic 原生搜索，按 Anthropic 原价计费。
  - 以上是从 schema 和文档推出来的，**没有用真实请求核对过**。
- **思考参数**：Messages 端点接受 `thinking: {type: "disabled"}`，等价于 `reasoning: {enabled: false}`（[Reasoning Tokens · Reasoning with the Anthropic Messages API](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)）。
- **模型列表**：OpenRouter 的 `/api/v1/models` 是它自己的格式（`data[].id` 形如 `anthropic/claude-sonnet-4.5`，没有 Anthropic 的 `has_more`、`capabilities` 等字段）。现有 Anthropic adapter 拉 `v1/models` 时，靠 Anthropic 格式的 capabilities 判断图片、搜索和思考能力，见 ARCHITECTURE §3.2，这部分对不上。

---

## 2. 阿里云百炼（DashScope）

### 2.1 怎么开启联网

来源：[联网搜索](https://help.aliyun.com/zh/model-studio/web-search)（中文站）、[Web search](https://www.alibabacloud.com/help/en/model-studio/web-search)（国际站）、[OpenAI 兼容 - Chat 参数说明](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)。

- **OpenAI 兼容 Chat Completions**：请求体顶层加 `"enable_search": true`。这不是 OpenAI 的标准参数，Python SDK 要放进 `extra_body`，Node SDK 和 curl 直接放顶层。
- **`search_options`** 在 OpenAI 兼容 Chat Completions 下支持这些（「核心能力」表）：
  - `forced_search`：强制联网；
  - `search_strategy`：`turbo`（默认）、`max`、`agent`、`agent_max`；
  - 垂域搜索、时效性、限定站点、用自然语言干预检索范围。
- **`enable_source`、`enable_citation`、`citation_format`、`prepend_search_result` 只支持 DashScope 原生协议**（文档原文：「以上 enable_source、enable_citation、citation_format 参数仅支持 DashScope 调用方式」；`prepend_search_result`：「不支持 OpenAI 兼容方式与 DashScope Java SDK 调用」）。
- **Responses API**：在 `tools` 里加 `{"type": "web_search"}`，属于 agent 式多轮检索，会忽略 `search_strategy`。
- `agent` 策略（以及 Responses 的 web_search 工具）的计费另算，见 §2.3。开启 `agent` 时只能用 `enable_source`，其他搜索功能都不可用。

### 2.2 哪些模型支持联网

来源：[联网搜索 · 支持的模型](https://help.aliyun.com/zh/model-studio/web-search)。

- **华北 2（北京）的 DeepSeek**：deepseek-v4-pro、deepseek-v4-pro-0813、deepseek-v4-flash、deepseek-v4-flash-0731、deepseek-v3.2、deepseek-v3.2-exp、deepseek-v3.1、deepseek-r1-0528、deepseek-r1、deepseek-v3。其中 deepseek-v4 系列也支持 Responses API。
- **新加坡的 DeepSeek**：deepseek-v4-pro、deepseek-v4-pro-0813、deepseek-v4-flash、deepseek-v4-flash-0731、deepseek-v3.2。
- **全球**部署范围（美国弗吉尼亚、中国香港、日本东京、德国法兰克福）：只有 qwen3.8-max、qwen3.8-max-0902、qwen3.8-flash、qwen3.8-omni-flash，**没有 DeepSeek**。
- 千问方面，「2025 年 7 月后发布的千问 Max、千问 Plus、千问 Flash 模型都自动支持联网搜索」，另外 Qwen3.5 到 3.8 系列也支持。完整清单见原文。
- 一个出入：[DeepSeek 模型页](https://help.aliyun.com/zh/model-studio/deepseek-api)的「其它功能」表里，**deepseek-v4.1-flash 标的是支持联网搜索**，但联网搜索页的清单里没有它。以哪边为准，要实测。

### 2.3 计费

来源：[联网搜索 · 计费说明](https://help.aliyun.com/zh/model-studio/web-search)。

- 内置联网搜索「本身不提供免费调用额度」。
- 费用分两部分：
  - **模型调用费**：网页内容会拼进提示词，按输入 token 计费。
  - **搜索策略费**：
    - turbo（默认）每千次 3 元，max 每千次 4 元，「该标准仅适用于华北 2（北京）地域」，从 2026-02-27 起正式收费；
    - agent 策略在北京、弗吉尼亚、香港、东京、法兰克福每千次 4 元，新加坡每千次 73.392381 元；
    - Responses API 的 web_search 工具按 agent 策略计费。
- 限流：联网搜索 15 RPS，按主账号计算。「超出限制时 API 不会报错，但搜索链路不会触发」。

### 2.4 响应里的搜索结果和引用

**OpenAI 兼容 Chat Completions：拿不到来源和引用。**

- 「核心能力」表里，「返回搜索来源」「角标引用标注」「提前返回搜索来源」三项在 OpenAI 兼容 Chat Completions 一列都是「不支持」。正文说：「OpenAI 兼容协议因协议限制，不支持搜索来源返回和角标标注等功能」。
- 甚至没法判断这次有没有搜。常见问题里写着：「OpenAI 兼容：暂无法通过响应明确判断是否执行搜索。可对比 usage 中返回的输入 Token 数量。」
- 官方的 OpenAI 兼容联网示例都只打印正文，没有给出流式 chunk 原文（见附录 B.3）。

**DashScope 原生协议**（`POST {base}/api/v1/services/aigc/text-generation/generation`，不是 OpenAI 格式）：

- `search_options.enable_source: true`：响应的 `output.search_info.search_results[]` 带 `index`、`title`、`url`、`site_name`、`icon`。
- 再加 `enable_citation: true`：正文里插入 `[1]` 或 `[ref_1]` 角标，样式由 `citation_format` 决定。**没有偏移量**，角标的数字对应 `search_results[].index`。官方示例里还出现过 `[ref_无]` 这种角标，说明有对不上来源的情况。
- 流式（SSE，`incremental_output: true`）：
  - 默认情况下，「首个数据包会包含搜索来源和模型回复的起始部分」；
  - 设 `prepend_search_result: true` 后，首包只含来源，之后每个包的 `search_info.search_results` 都是空数组；
  - 执行过搜索的话，`usage.plugins.search.count` 是 1。
  - 官方原文见附录 B.1。
- 判断有没有搜：「如果执行了搜索，响应会包含 `search_info` 字段，并且 `usage` 中会包含 `plugins` 字段。」
- 「正在搜索」信号：没有专门的事件。官方说，搜索结果就绪之后要过 0.5 秒以上才会发首包，`prepend_search_result` 就是用来缩短这段等待的。

**Responses API**：

- 来源在 `output[]` 里 `type: "web_search_call"` 的元素中，`action.sources[]` 只有 `{type: "url", url}`，**没有标题**。
- 「Responses API 暂不支持 enable_source、enable_citation、citation_format 参数，不会在回复内容中自动插入 [1] 角标。」
- 国际站英文页说 Responses 的引用以 `url_citation` annotation 返回，但中文站的 Responses 示例里 `annotations` 都是空数组，「核心能力」表里 Responses 一列「返回搜索来源」也写着「不支持」。官方资料互相矛盾，要实测。
- 我们目前没有 Responses adapter。

### 2.5 `/models` 能不能看出某个模型支持联网

- 没有找到一手文档。OpenAI 兼容的 `GET {base}/compatible-mode/v1/models` 存在：实际请求无鉴权访问返回 401。但文档没有说明它的返回字段里有没有联网能力。
- 能力只能按 §2.2 的官方清单写死在内置表里，而且不同地域的清单不一样。

### 2.6 和关闭思考一起用

- `enable_thinking` 和 `enable_search` 是两个独立参数。官方示例里两者同时为 true（[联网搜索 · 思考模型的联网搜索](https://help.aliyun.com/zh/model-studio/web-search)）。没有找到 `enable_thinking: false` 加 `enable_search: true` 的官方示例，但文档也没有说不允许。
- DeepSeek 的思考开关（[DeepSeek 模型页](https://help.aliyun.com/zh/model-studio/deepseek-api)）：
  - 混合思考模型用 `enable_thinking` 控制：deepseek-v4.1-flash、v4-pro、v4-flash、v4-flash-0731、v3.2、v3.2-exp、v3.1；
  - 「deepseek-v4.1-flash、deepseek-v4-pro、deepseek-v4-flash、deepseek-v4-flash-0731 和 deepseek-v4-pro-0813 默认开启思考模式」；
  - deepseek-r1 系列只能思考，deepseek-v3 只能不思考；
  - deepseek-v3.2-exp 和 v3.1 的联网搜索「仅支持非思考模式」。
- 注意：和 OpenRouter 一样，现有 adapter 不会给百炼发 `enable_thinking: false`，所以 DeepSeek V4 现在默认开着思考。百炼不认 DeepSeek 官方的 `thinking: {type: "disabled"}` 字段（文档只写了 `enable_thinking`），没有核对过发了会怎样。

### 2.7 怎么识别是百炼

来源：[选择地域、服务部署范围和接入域名](https://help.aliyun.com/zh/model-studio/regions)。

| 地域 | 业务空间专属域名（官方推荐） | DashScope 域名 |
| - | - | - |
| 华北 2（北京） | `{WorkspaceId}.cn-beijing.maas.aliyuncs.com` | `dashscope.aliyuncs.com` |
| 新加坡 | `{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com` | `dashscope-intl.aliyuncs.com` |
| 中国香港 | `{WorkspaceId}.cn-hongkong.maas.aliyuncs.com` | `cn-hongkong.dashscope.aliyuncs.com` |
| 美国（弗吉尼亚） | `{WorkspaceId}.us-east-1.maas.aliyuncs.com` | `dashscope-us.aliyuncs.com` |
| 德国（法兰克福）、日本（东京） | `{WorkspaceId}.eu-central-1/ap-northeast-1.maas.aliyuncs.com` | 不支持 |

- OpenAI 兼容路径都是 `{host}/compatible-mode/v1`。另外还有试用域名 `trial.{region}.maas.aliyuncs.com`。
- 「DashScope 域名（dashscope.aliyuncs.com）自 2026 年 9 月 30 日起不再支持新特性」，官方推荐迁到业务空间专属域名。
- 判断规则：host 以 `.aliyuncs.com` 结尾，并且是 `dashscope*.aliyuncs.com`、`*.dashscope.aliyuncs.com` 或 `*.maas.aliyuncs.com` 之一。地域决定支持哪些联网模型（§2.2），可以从 host 里的地域 ID 推出来。不过 `dashscope.aliyuncs.com` 本身就是北京。

---

## 3. 对 #48 / #49 决策的影响

这里只列事实和取舍，不替用户做决定。

### 3.1 OpenRouter + DeepSeek

**方案 O1：OpenAI 兼容 adapter 识别到 OpenRouter 后，在 `tools` 里加 `openrouter:web_search`。**

- 请求参数：加 `{"type": "openrouter:web_search", "parameters": {"max_uses": 3}}`，跟 Anthropic 一样限 3 次。不过 `max_uses` 只对 Exa 这类非原生引擎和 Anthropic 原生搜索有效，其他原生引擎会忽略它。可以用 `max_tool_calls` 兜底。
- 引用解析：从 `delta.annotations[]` 取 `url_citation`，映射成 `CitationSpan`。偏移单位要实测；如果不是 UTF-16，或者缺失，就退化成 `textRange: nil`（来源列表照样能显示）。
- 能力判断：OpenRouter 的所有模型都当成支持 Web Search，**host 是 `eu.openrouter.ai` 时除外**（§1.7，EU 端点没有搜索引擎）。地球按钮不再置灰，但要提示会额外收费。
- 「正在搜索」状态：没有可靠信号，可以退化成「连接已建立、正文还没开始」时显示。`reasoning.server_tool_call` 能不能当信号，要实测。
- ADR-0003：要修订，加一条「OpenRouter 用它的 server tool（第三方 Exa）」。这和 ADR 原来的「不接外部搜索服务」有冲突。Exa 由 OpenRouter 代调，用户不需要多管理一个 key，但多了一笔按次收的费用。

**方案 O2：用 deprecated 的 `plugins: [{id: "web"}]`。** 每个请求都固定搜一次（$0.007），引用格式和 O1 一样。好处是行为可预测、实现最简单；坏处是已经 deprecated。

### 3.2 百炼 + DeepSeek

**方案 B1：OpenAI 兼容 adapter 识别到百炼后，加 `enable_search: true`。**

- 请求参数只改这一处。
- 但**没有来源，没有 Citation，也不知道有没有搜**。正文的事实来自网络，却没法标出处，和 SPEC 里「Citation 角标和来源列表」的体验不一致。
- 能力判断：要按地域加模型名，内置一张百炼联网模型表。

**方案 B2：给百炼单独写一个 DashScope 原生协议的 adapter。**

- 能拿到 `search_info`，角标可以靠 `enable_citation` 拿到。
- 但这是第四种 Provider：请求格式、SSE 包结构、错误映射都和 OpenAI 兼容不同。ADR-0001 的 Provider 抽象要多一种实现。
- 角标是写进正文的文本（`[ref_1]`），没有偏移。要么在渲染时把 `[ref_n]` 换成 Citation 角标，要么另外写一个基于文本标记的 Citation 映射。

**方案 B3：走百炼的 Responses API。** 只拿得到 URL 列表，没有标题，也没有角标，还要新写一个 Responses 格式的 adapter。性价比最低。

**方案 B0：百炼的 Connection 继续不联网**，以后再说。

### 3.3 经中转的 Claude（#49）

- 如果中转 Connection 可以选「Anthropic Messages」格式，OpenRouter 上的 Claude 可以直接用现有 Anthropic adapter 的原生搜索和引用解析，但至少有两处要改：
  - 鉴权头：要支持 `Authorization: Bearer`；
  - 模型列表和能力：OpenRouter 的 `/api/v1/models` 不是 Anthropic 格式，能力要么从 OpenRouter 的格式里映射，要么用保守默认值，要么让用户手动选。
- 不选格式的另一条路：经 OpenRouter 的 OpenAI 兼容格式调 Claude 时，方案 O1 的 `openrouter:web_search` 会自动用 Anthropic 原生搜索，引用也会统一成 `url_citation`。这样不用改 Anthropic adapter，但引用会被转换一次，原生的 `cited_text`、`encrypted_index` 就拿不到了。
- 别的中转是不是提供 Anthropic 原生格式，不在这次调研范围内。

### 3.4 和联网无关、但这次发现的问题

- DeepSeek V4 在 OpenRouter 和百炼上默认开着思考，现有 adapter 没有关（§1.6、§2.6），这违反 ADR-0002。修法：
  - OpenRouter 发 `reasoning: {enabled: false}`，或者 `effort: "none"`，但 `mandatory` 为 true 的模型不能发；
  - 百炼发 `enable_thinking: false`。
  
  建议单独开 issue。

### 3.5 要用户在真机上用真实 key 验证的

1. OpenRouter + `deepseek/deepseek-v4-flash` + `openrouter:web_search` 的流式响应原文：
   - `delta.annotations` 出现在哪个 chunk；
   - 有没有 `title`、`start_index`、`end_index`；
   - 在含中文和 emoji 的回答里，偏移是 UTF-16、码点还是字节；
   - `end_index` 是闭区间还是半开区间：原文写的是「The index of the last character」，按字面是闭区间（指向最后一个字符），而 `CitationSpan.textRange` 是半开区间，换算时差 1；
   - 流里有没有 `reasoning_details` 的 server tool 记录；
   - `usage.server_tool_use.web_search_requests` 的值。
2. 同一请求加上 `reasoning: {enabled: false}`，确认没有 `reasoning` 输出，搜索照常进行。
3. 百炼北京 + `deepseek-v4-flash` + `enable_search: true` + `enable_thinking: false` 的流式响应原文：确认里面确实没有任何搜索来源字段，输入 token 明显变多（说明搜过）。
4. 百炼上给 DeepSeek 发 `thinking: {type: "disabled"}` 会报错还是被忽略。
5. 百炼上 `deepseek-v4.1-flash` 到底支不支持联网：DeepSeek 模型页的表里写着支持，联网搜索页的模型清单里却没有它（§2.2）。
6. OpenRouter `POST /api/v1/messages` + `anthropic/claude-*` + `web_search_20250305`：
   - 用 `x-api-key` 鉴权会不会被拒；
   - 流里的 `web_search_tool_result` 和 `citations_delta` 和 Anthropic 原生是否一致。

---

## 附录：官方示例原文（以后做 fixture 用）

### A. OpenRouter

**A.1 非流式响应里的 annotation**（[Web Search plugin](https://openrouter.ai/docs/guides/features/plugins/web-search)，原文照录，含原文注释）：

```json
{
  "message": {
    "role": "assistant",
    "content": "Here's the latest news I found: ...",
    "annotations": [
      {
        "type": "url_citation",
        "url_citation": {
          "url": "https://www.example.com/web-search-result",
          "title": "Title of the web search result",
          "content": "Content of the web search result", // Added by OpenRouter if available
          "start_index": 100, // The index of the first character of the URL citation in the message.
          "end_index": 200 // The index of the last character of the URL citation in the message.
        }
      }
    ]
  }
}
```

**A.2 流式 chunk 里的 annotation**：官方文档只给了非流式示例。下面这一行出自官方 SDK 的单元测试（[`OpenRouterTeam/ai-sdk-provider` `src/chat/index.test.ts`](https://github.com/OpenRouterTeam/ai-sdk-provider/blob/main/src/chat/index.test.ts)，用例「should handle url_citation with all optional fields missing in streaming response」），原文只有 `data:` 后面 JSON 的 `choices` 部分，前面的公共字段在测试代码里另外拼接：

```
"choices":[{"index":0,"delta":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/page"}}]},"finish_reason":null}]}
```

**A.3 SSE 注释**（[Streaming](https://openrouter.ai/docs/api_reference/streaming)）：

```
: OPENROUTER PROCESSING
```

**A.4 用量**（[server tool · Usage Tracking](https://openrouter.ai/docs/guides/features/server-tools/web-search)）：

```json
{
  "usage": {
    "input_tokens": 105,
    "output_tokens": 250,
    "server_tool_use": {
      "web_search_requests": 2
    }
  }
}
```

**A.5 Messages API 的 `web_search_result_location`**（[Create a message](https://openrouter.ai/docs/api/api-reference/anthropic-messages/create-a-message)，OpenAPI schema `AnthropicCitationWebSearchResultLocationParam` 的 example）：

```yaml
cited_text: Example cited text
encrypted_index: enc_idx_0
title: Example Page
type: web_search_result_location
url: https://example.com
```

### B. 阿里云百炼

**B.1 DashScope 原生协议的流式响应**（`prepend_search_result: true`，[联网搜索 · 提前返回搜索来源](https://help.aliyun.com/zh/model-studio/web-search)，原文照录，中间的 `...` 是原文省略）：

```
id:1
event:result
:HTTP_STATUS/200
data:{"output":{"choices":[{"message":{"content":"","role":"assistant"},"finish_reason":"null"}],"search_info":{"search_results":[{"site_name":"百家号","icon":"https://baijiahao.baidu.com/favicon.ico","index":1,"title":"全年高温日数可能创新高,杭州何时能“熄火”?","url":"https://baijiahao.baidu.com/s?id=1843390963791748953&wfr=spider&for=pc"},{"site_name":"eastday","icon":"https://img.alicdn.com/imgextra/i3/O1CN01kr9teP1wlRD8OH6TO_!!6000000006348-73-tps-16-16.ico","index":2,"title":"杭州天气预报杭州2025年09月17日天气","url":"https://tianqi.eastday.com/tianqi/hangzhou/20250917.html"}]}},"usage":{},"request_id":"785ed962-fa29-4c7e-bed2-7fe0fdbfdc6c"}
id:2
event:result
:HTTP_STATUS/200
data:{"output":{"choices":[{"message":{"content":"根据","role":"assistant"},"finish_reason":"null"}],"search_info":{"extra_tool_info":[],"search_results":[]}},"usage":{"total_tokens":2941,"output_tokens":1,"input_tokens":2940,"plugins":{"search":{"count":1}},"prompt_tokens_details":{"cached_tokens":0}},"request_id":"785ed962-fa29-4c7e-bed2-7fe0fdbfdc6c"}
...
id:66
event:result
:HTTP_STATUS/200
data:{"output":{"choices":[{"message":{"content":"","role":"assistant"},"finish_reason":"stop"}],"search_info":{"extra_tool_info":[],"search_results":[]}},"usage":{"total_tokens":3224,"output_tokens":284,"input_tokens":2940,"plugins":{"search":{"count":1}},"prompt_tokens_details":{"cached_tokens":0}},"request_id":"785ed962-fa29-4c7e-bed2-7fe0fdbfdc6c"}
```

（id:1 的 `search_results` 原文有 10 条，这里只留前 2 条。）

**B.2 DashScope 原生协议带角标的非流式响应**（`enable_citation: true`、`citation_format: "[ref_<number>]"`，同页「获取并标注引用来源」，节选）：

```json
{
  "output": {
    "choices": [
      {
        "message": {
          "content": "…建议穿着清凉透气的衣物，如棉麻面料的衬衫、薄长裙或薄T恤等[ref_1][ref_5]。…",
          "role": "assistant"
        },
        "finish_reason": "stop"
      }
    ],
    "search_info": {
      "extra_tool_info": [],
      "search_results": [
        {
          "icon": "https://mbs1.bdstatic.com/searchbox/mappconsole/image/20220307/88eb511c-5c51-448a-a9b5-df6b24cda8c7.png",
          "site_name": "新浪网",
          "index": 1,
          "title": "直降近10℃!刚刚确认:冷空气即将抵达,这波很猛",
          "url": "https://cj.sina.com.cn/articles/view/1665450974/6344c3de01901avjw"
        }
      ]
    }
  }
}
```

**B.3 OpenAI 兼容 Chat Completions 的联网请求**（同页「思考模型的联网搜索」的 curl 示例，原文照录）。官方没有给出这种调用的流式 chunk 原文，只有 SDK 打印出来的正文和 usage：

```bash
curl -X POST https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions \
-H "Authorization: Bearer $DASHSCOPE_API_KEY" \
-H "Content-Type: application/json" \
-d '{
    "model": "qwen-plus",
    "messages": [
        {
            "role": "user",
            "content": "请你结合近期的AI热点新闻，预测一下AI的发展趋势"
        }
    ],
    "enable_thinking": true,
    "enable_search": true,
    "search_options": {
        "forced_search": true
    },
    "stream": true,
    "stream_options": {
        "include_usage": true
    }
}'
```

**B.4 Responses API 的 `web_search_call`**（[OpenAI 兼容 - Responses](https://help.aliyun.com/zh/model-studio/compatibility-with-openai-responses-api)，节选）：

```json
{
  "type": "web_search_call",
  "status": "completed",
  "action": {
    "query": "阿里云官网",
    "type": "search",
    "sources": [
      { "type": "url", "url": "https://cn.aliyun.com/" },
      { "type": "url", "url": "https://www.alibabacloud.com/zh" }
    ]
  }
}
```
