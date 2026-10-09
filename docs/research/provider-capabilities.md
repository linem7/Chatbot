# 研究：三家 Provider 的 API 能力矩阵

> 对应 issue #6（属于 #1）。调研日期 2026-10-08，只用各家官方文档。
> 术语沿用 `CONTEXT.md`：**Provider** 指 API 协议族（OpenAI 兼容 / Anthropic Messages / Google Gemini）；DeepSeek 和 Ollama 是用 OpenAI 兼容 Provider 访问的**服务**，下表单列 DeepSeek 一列，只是为了标出它和标准格式的偏差。

## 先说结论

1. **DeepSeek 现在支持图片输入**：只有 `deepseek-flash` 支持，`deepseek-v4-pro` 不支持。图片用标准 `image_url` 传，base64 data URL 和 http(s) URL 都可以。PDF/文档输入仍不支持（Files API 只收图片）。[DS-Vision] [DS-Pricing]
2. **DeepSeek 默认开 thinking**，带来三个硬约束：
   - `temperature` 等采样参数被忽略；
   - `tool_choice: "required"` 或指定具体函数时返回 400；
   - **只要请求带 `tools`，历史里每一条 assistant 消息都必须回传 `reasoning_content`**，否则返回 400。[DS-Thinking] [DS-Chat]
3. **Google 已把 `generateContent` 叫作 "legacy"**，新功能优先上 Interactions API。但 Interactions 还是 Beta，官方仍建议生产环境用 `generateContent`，并说会继续维护。本项目先接 `generateContent` 没问题。[G-Interactions]
4. **最难统一的是流式 tool call**：
   - OpenAI 系按 `index` 发参数字符串片段；
   - Anthropic 按 content block 发 `input_json_delta`；
   - Gemini `generateContent` 的 `functionCall` 是带完整 `args` 对象的 Part，官方文档没有描述参数级增量。

## 能力矩阵

列说明：「OpenAI 兼容」指 OpenAI 官方 Chat Completions，Ollama 的差异在格内用 *Ollama:* 标出。「DeepSeek」只写它和 OpenAI 不同的地方，没写的就是和 OpenAI 一样。来源标记如 [OAI-Chat] 对应文末的链接表。

| 能力 | OpenAI 兼容（Chat Completions；含 Ollama） | DeepSeek（`api.deepseek.com`） | Anthropic Messages | Gemini `generateContent` |
|---|---|---|---|---|
| **端点** | `POST /v1/chat/completions` [OAI-Chat]；*Ollama:* `http://localhost:11434/v1/`，API key 必填但不校验 [Ollama] | `POST /chat/completions`（base_url 不带 `/v1`）；另有 Anthropic 兼容端点 `/anthropic` [DS-Quick] | `POST /v1/messages` [A-Msg] | `POST /v1beta/models/{model}:generateContent`；流式用 `:streamGenerateContent?alt=sse` [G-Gen] |
| **流式：事件结构** | 只有 `data:` 行，没有 `event:` 名。每行一个 `chat.completion.chunk`，文本在 `choices[].delta.content` 里 [OAI-Stream] | 同 OpenAI；thinking 内容在 `delta.reasoning_content` 里，和 `content` 交替出现。排队时会发 SSE 注释 `: keep-alive`，解析器要忽略 [DS-Chat] [DS-Rate] | 有名字的 SSE 事件，顺序是：`message_start` → 每个 block 的 `content_block_start` / `content_block_delta` / `content_block_stop` → `message_delta` → `message_stop`。文本是 `text_delta`，thinking 是 `thinking_delta` 加 `signature_delta`。中间可能夹 `ping`，以后还可能出现新的事件类型 [A-Stream] | 每个 `data:` 都是一个完整的 `GenerateContentResponse` 片段。文本在 `candidates[0].content.parts[].text` 里；thinking 是 `thought: true` 的 Part，需要设 `includeThoughts` [G-Gen] [G-Think] |
| **流式：结束标记** | `data: [DONE]` [OAI-Chat] | `data: [DONE]` [DS-Chat] | `event: message_stop`，没有 `[DONE]` [A-Stream] | 文档没定义结束哨兵，以最后一个带 `finishReason` 的 chunk 加连接关闭为准 [G-Gen] |
| **流式：错误** | Chat Completions 流式参考里没有定义流中错误事件；错误主要以 HTTP 状态码返回 [OAI-Stream] | 额外的 `finish_reason`：`insufficient_system_resource`、`aborted`；请求 10 分钟没开始推理就断开连接 [DS-Chat] [DS-Rate] | `event: error`，内容如 `{"type":"error","error":{"type":"overloaded_error",...}}`，对应非流式时的 HTTP 529 [A-Stream] | 文档没写流中错误格式（**需实测**）[G-Gen] |
| **流式：用量** | 设 `stream_options.include_usage: true` 后，`[DONE]` 前会多一个 `choices: []` 的 usage chunk；流被中断时可能收不到 [OAI-Chat] | **不同**：没有单独的 usage chunk，usage 挂在最后一个内容 chunk 上（该 chunk 的 `choices` 有 1 个元素，带 `finish_reason`）[DS-Chat]。*Ollama:* 支持 `include_usage` [Ollama] | `message_start` 里有 input 用量；`message_delta.usage` 是**累计值** [A-Stream] | 各 chunk 带 `usageMetadata`（以最后一个为准，需实测确认）[G-Gen] |
| **图片输入：格式** | PNG、JPEG、WEBP、非动图 GIF [OAI-Vision] | JPEG、PNG、GIF、WebP，按文件内容判断格式；**只有 `deepseek-flash` 支持**，图片只能放在 user 和 tool 消息里 [DS-Vision] [DS-Chat] | JPEG、PNG、GIF、WebP，动图只取第一帧 [A-Vision] | PNG、JPEG、WEBP、HEIC、HEIF（Blob schema 还列了 gif、avif）[G-Img] [G-Gen] |
| **图片输入：传法** | `{"type":"image_url","image_url":{"url": <https URL 或 data:image/...;base64>,"detail":...}}` [OAI-Chat]；*Ollama:* **只支持 base64，不支持图片 URL** [Ollama] | 同 OpenAI 的 `image_url`（base64 和 URL 都行，`detail` 可选 low/high/original/auto）；另外支持 `{"type":"file","file_id"}` 和 `file_data` [DS-Vision] | `{"type":"image","source":{"type":"base64","media_type","data"}}`，`source.type` 也可以是 `url` 或 `file`（Files API 的 `file_id`）[A-Vision] | Part 用 `inlineData{mimeType,data}`（base64）或 `fileData{mimeType,fileUri}`。`fileUri` 可以是 Files API 的 URI、GCS，或公开的 https/签名 URL [G-Files] |
| **图片输入：限制** | 每个请求最多 512 MB、1,500 张图 [OAI-Vision] | 请求体 48 MiB；单图 32 MiB（base64/URL）或 64 MiB（file_id）；最多 600 张；每边 8192 px，一个请求有 15 张及以上时降到 4096 px；单图最多约 1024 token [DS-Vision] | 单图 10 MB（base64），8000×8000 px；一个请求超过 20 张时单边要 ≤2000 px；最多 600 张（200k context 的模型是 100 张）；请求总大小 32 MB [A-Vision] | inline 方式：图片指南写请求总大小 20 MB，而文件输入指南写 100 MB（PDF 50 MB），**两份文档不一致**。外部 URL 每个文件 15 MB；Files API 每个文件 2 GB；每个请求最多 3,600 张 [G-Img] [G-Files] |
| **PDF / 文件输入** | 支持，但 Chat Completions **只收 PDF**：`{"type":"file","file":{"file_data" 或 "file_id","filename"}}`，不能用 URL；每个文件和整个请求合计都要 < 50 MB [OAI-File]。*Ollama:* 文档没列文件输入 [Ollama] | **不支持 PDF**。`file` block 和 Files API 只收图片格式 [DS-Files] [DS-Vision] | 原生支持：`{"type":"document","source":{base64 \| url \| file}}`；最多 600 页（context 不到 1M 时 100 页），请求 32 MB；纯文本可以通过 Files API 用 `text/plain` 传入 [A-PDF] | 原生支持：`inlineData` 或 `fileData` 设 `application/pdf`；最多 50 MB、1000 页，每页 258 token；Gemini 3 会抽取 PDF 原生文本，这部分不计费 [G-Doc] |
| **Tool 定义** | `tools:[{type:"function",function:{name,description,parameters(JSON Schema),strict?}}]`；`tool_choice` 可选 none/auto/required/指定函数 [OAI-Chat]；*Ollama:* 支持 `tools`，**不支持 `tool_choice`** [Ollama] | 同 OpenAI；`strict` 要走 `/beta` base_url；**thinking 模式下 `required` 和指定函数会返回 400** [DS-Tools] [DS-Chat] | `tools:[{name,description,input_schema,strict?}]`；`tool_choice` 可选 auto/any/tool/none（部分新模型禁止 any/tool）[A-Tools] | `tools:[{functionDeclarations:[{name,description,parameters}]}]`；`toolConfig.functionCallingConfig.mode` 可选 AUTO/ANY/NONE/VALIDATED，加 `allowedFunctionNames` [G-FC] |
| **Tool call 响应** | `message.tool_calls[]{id,type:"function",function:{name,arguments(JSON 字符串)}}`，`finish_reason:"tool_calls"` [OAI-Chat] | 同 OpenAI；thinking 模式下同一条消息里还有 `reasoning_content` [DS-Chat] | `content[]` 里的 `tool_use` block：`{id,name,input(对象)}`，`stop_reason:"tool_use"` [A-Tools] | `parts[]` 里的 `functionCall{id,name,args(对象)}`。Gemini 3 一定返回 `id`；Part 上还可能有 `thoughtSignature`，要原样回传 [G-FC] [G-Gen] |
| **并行调用** | 支持，`parallel_tool_calls:false` 可关 [OAI-Chat] [OAI-FC] | 一条消息可以有多个 `tool_calls`；参数表**没有列** `parallel_tool_calls` [DS-Chat] | 默认开启；`disable_parallel_tool_use:true` 可关；所有 `tool_result` 必须放在**同一条** user 消息里返回 [A-Tools] | 支持，一个 turn 里有多个 `functionCall` Part [G-FC] |
| **流式 tool call 分块** | `delta.tool_calls[]` 按 `index` 区分；第一片带 `id` 和 `function.name`，之后只有 `function.arguments` 片段，客户端负责拼接 [OAI-Stream] | 同 OpenAI（chunk 里有 `tool_calls[].index`）[DS-Chat] | 每个 `tool_use` 是一个独立 content block：`content_block_start` 带 id 和 name，`input_json_delta.partial_json` 是参数片段，到 `content_block_stop` 再解析 [A-Stream] | 文档没写参数级增量，`functionCall` 以带完整 `args` 的 Part 出现（**需实测**）[G-FC] |
| **Tool result 格式** | `{"role":"tool","tool_call_id","content"}`，content 只能是字符串或 text parts [OAI-Chat] | 同 OpenAI，另外 **tool 消息可以带图片** [DS-Chat]。thinking + tools 时要回传历史上所有的 `reasoning_content` [DS-Thinking] | user 消息里的 `{"type":"tool_result","tool_use_id","content","is_error?"}`；content 可以是字符串或 text/image/document blocks [A-Tools] | `role:"user"` 的 Part：`functionResponse{id,name,response(对象),parts?}`，`parts` 可以带多模态内容 [G-FC] [G-Gen] |
| **System prompt** | `messages` 里 `role:"system"` 或 `role:"developer"`（o1 及更新的模型推荐用 developer）[OAI-Chat] | `role:"system"`；Chat Completions 支持在对话中间插入 system 消息 [DS-Tools] | 顶层 `system`（字符串或 text block 数组），`messages` 里**没有** system role；较新的模型另外支持在 messages 中间插入 `role:"system"` [A-Msg] | 顶层 `systemInstruction`（一个 `Content`）[G-Gen] |
| **模型列表** | `GET /v1/models` → `{data:[{id,created,owned_by,shutdown_date}]}`，**没有能力字段** [OAI-Models]；*Ollama:* `/v1/models` 列出本地模型，`owned_by` 默认 `library` [Ollama] | `GET /models` → 除 OpenAI 的字段外，还有 `name`、`context_window`、`max_output_tokens`、`input_modalities`（text/image）、`effort` 等 [DS-Models] | `GET /v1/models`（`after_id`/`before_id`/`limit` 分页）→ `id`、`display_name`、`max_input_tokens`、`max_tokens`、`capabilities`（含 `image_input`、`pdf_input` 等）[A-Models] | `GET /v1beta/models`（`pageSize`/`pageToken`）→ `name`、`inputTokenLimit`、`outputTokenLimit`、`supportedGenerationMethods`、`thinking` [G-Models] |
| **用量字段** | `usage{prompt_tokens,completion_tokens,total_tokens,prompt_tokens_details.cached_tokens,completion_tokens_details.reasoning_tokens}` [OAI-Stream] | 在 OpenAI 字段基础上多了 `prompt_cache_hit_tokens`、`prompt_cache_miss_tokens`（两者相加等于 `prompt_tokens`）[DS-Chat] | `usage{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens}`，总输入是这三项 input 之和 [A-Msg] | `usageMetadata{promptTokenCount,candidatesTokenCount,thoughtsTokenCount,cachedContentTokenCount,toolUsePromptTokenCount,totalTokenCount}` [G-Gen] |
| **Reasoning / thinking** | Chat Completions 只返回 `reasoning_tokens` 计数，不返回推理文本 [OAI-Stream]；*Ollama:* 支持 `reasoning_effort`/`reasoning.effort`，响应里的推理字段文档没写 [Ollama] | **默认开启**。开关用 `thinking:{type}`（非 OpenAI 标准字段，SDK 里要放进 `extra_body`），力度用 `reasoning_effort`（none/low/high/max，其他值会被映射）。输出在 `reasoning_content` [DS-Thinking] | `thinking:{type:"adaptive",display?}` 加 `output_config.effort`；输出是 `thinking` block 和 signature，同一模型续聊时要原样回传 [A-Stream] | `thinkingConfig`，`includeThoughts` 返回思考摘要；`thoughtSignature` 要原样回传 [G-Think] [G-FC] |
| **上下文缓存** | 命中数在 `prompt_tokens_details.cached_tokens` [OAI-Stream] | 默认开启的磁盘缓存，不用改代码；按"前缀单元"完整匹配才算命中；看 `prompt_cache_hit_tokens` [DS-Cache] | 显式 `cache_control` 断点（也可以在顶层自动放置），看 `cache_read_input_tokens` [A-Msg] | 有显式 `cachedContent`，命中数在 `cachedContentTokenCount` [G-Gen] [G-Interactions] |

## DeepSeek 相对标准 OpenAI 格式的差异清单

来源：[DS-Chat] [DS-Thinking] [DS-Tools] [DS-Vision] [DS-Rate]

- **模型名**：目前只有 `deepseek-flash`（DeepSeek-V4.1-Flash，支持 Vision）和 `deepseek-v4-pro`（不支持 Vision）。旧名 `deepseek-v4-flash` 等仍然接受，但实际会路由到 Flash。context 1M，最大输出 384K。[DS-Pricing]
- **非标准请求字段**：
  - `thinking:{type:"enabled"|"disabled"}`，默认 enabled；
  - assistant 消息上的 `prefix: true`（Beta，续写）；
  - `user_id`（用于 KV cache 隔离和调度隔离）。
- **thinking 模式下被忽略的参数**：`temperature` 静默失效；`presence_penalty` 和 `frequency_penalty` 已标为 deprecated，传了也不生效；`top_p` 只在 thinking 模式下生效，而且下限会被抬到 0.95。
- **thinking 模式下会报 400 的情况**：
  - `tool_choice` 设为 `required` 或指定函数；
  - 请求带 `tools`，但历史里有 assistant 消息没回传 `reasoning_content`。
- **参数表没列出的 OpenAI 字段**：`n`、`seed`、`logit_bias`、`parallel_tool_calls`、`max_completion_tokens`，以及 `developer` role。文档没说传了会怎样，统一层应该**不发送**这些字段。
- **默认 `max_tokens`**：非 thinking 模式 8K，thinking 模式 64K。
- **额外的 `finish_reason`**：`insufficient_system_resource`、`aborted`。
- **流式**：会发 `: keep-alive` 注释行；usage 挂在最后一个内容 chunk 上，没有单独的 usage chunk。
- **多轮对话**：不带 tools 时，回传的 `reasoning_content` 会被忽略（可以不传）；带 tools 时必须全部回传。
- **context caching**：默认开启，无需任何参数；用量里看 `prompt_cache_hit_tokens` 和 `prompt_cache_miss_tokens`。
- **只有 Chat Completions 不支持的事**：在对话中间插入"非模型生成的 tool call"。Anthropic 兼容端点和 Responses 端点支持。[DS-Tools]

## 最难统一的差异（给 #7 / Provider 抽象的提示）

1. **流式 tool call 的拼装模型不同**：
   - OpenAI 系是"按 `index` 的扁平参数片段"，第一片带 id 和 name；
   - Anthropic 是"按 content block 的 start/delta/stop 生命周期"，文本、thinking、tool_use 共用同一个 index 空间；
   - Gemini（就目前文档而言）是"整块 Part"。

   统一层建议对外只暴露"tool call 开始（id、name）→ 参数片段（可选）→ tool call 完成（完整 JSON）"三种事件。Gemini 只发"开始"和"完成"即可。

2. **reasoning 的回传规则三家各不相同**，而且都和 tool calling 绑在一起：
   - DeepSeek 带 tools 时必须回传全部 `reasoning_content`，否则 400；
   - Anthropic 的 thinking block 要带 signature 原样回传，跨模型时会被丢弃；
   - Gemini 的 `thoughtSignature` 必须留在原来的 Part 上，不能合并 Part。

   结论：**Message 的持久化模型必须能逐字保存 Provider 原生的 reasoning 片段和签名**，不能只存渲染后的文本。

3. **tool result 的位置和形状**：
   - OpenAI 系：每个结果一条 `role:"tool"` 消息，OpenAI 官方只允许文本，DeepSeek 允许图片；
   - Anthropic：所有结果合并到同一条 user 消息里的多个 `tool_result` block，可以带图片和文档；
   - Gemini：`functionResponse.response` 必须是 JSON **对象**（不能是裸字符串），多模态要用 `parts` 加 `$ref`。

   Web Search 这种由 app 侧实现的工具，返回结果时要按 Provider 分别编码。

4. **System prompt 的位置**：OpenAI 系是消息数组里的一条，Anthropic 和 Gemini 是顶层字段。统一层把它当 Conversation 级别的属性，序列化时再按 Provider 放到对应位置即可。这一项最容易统一。

5. **Attachment 能力是"模型级"的，不是"Provider 级"的**：
   - 同为 DeepSeek，`deepseek-flash` 能看图，`deepseek-v4-pro` 不能；
   - Ollama 取决于本地模型，而且图片只能用 base64；
   - PDF 只有 OpenAI（仅 PDF）、Anthropic、Gemini 原生支持。

   建议优先用各家模型列表接口的能力字段来判断：DeepSeek 的 `input_modalities`、Anthropic 的 `capabilities.image_input/pdf_input`、Gemini 的 limits。OpenAI 的 `/v1/models` 没有能力字段，只能靠本地配置。

6. **Screenshot 尺寸**：几家的上限差距很大。Anthropic 单图 10 MB，超过 20 张图时单边要 ≤2000 px；Gemini inline 方式下请求总大小只有 20 MB（按较严的那份文档算）。统一在 app 侧把 Screenshot 缩放、压缩到**长边 ≤2000 px 的 JPEG/PNG**，再用 base64 发送，可以同时满足所有 Provider，也不需要依赖任何 URL 拉取（Ollama 不支持 URL）。

7. **流结束和错误的判定**：OpenAI 系靠 `[DONE]`，Anthropic 靠 `message_stop`，Gemini 靠 `finishReason` 加 EOF。Anthropic 会在流中途发 `event: error`。解析层必须容忍未知事件类型（Anthropic 明确说以后会加），以及 SSE 注释行（DeepSeek 的 keep-alive）。

### 仍需实测的点

- Gemini `streamGenerateContent` 在流中途出错时的格式；`usageMetadata` 是每个 chunk 都有，还是只在最后一个 chunk 有。
- Gemini 流式时 `functionCall` 会不会拆到多个 chunk 里。
- Ollama `/v1/chat/completions` 返回 thinking 内容时用的字段名。
- OpenAI Chat Completions 流中途出错时的具体表现。

## 来源

| 标记 | URL |
|---|---|
| OAI-Chat | https://developers.openai.com/api/reference/resources/chat （platform.openai.com/docs 已重定向到 developers.openai.com） |
| OAI-Stream | https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events |
| OAI-Vision | https://developers.openai.com/api/docs/guides/images-vision |
| OAI-File | https://developers.openai.com/api/docs/guides/file-inputs |
| OAI-FC | https://developers.openai.com/api/docs/guides/function-calling |
| OAI-Models | https://developers.openai.com/api/reference/resources/models/methods/list |
| Ollama | https://docs.ollama.com/api/openai-compatibility |
| DS-Quick | https://api-docs.deepseek.com/ |
| DS-Chat | https://api-docs.deepseek.com/api/create-chat-completion |
| DS-Thinking | https://api-docs.deepseek.com/guides/thinking_mode |
| DS-Tools | https://api-docs.deepseek.com/guides/tool_calls |
| DS-Vision | https://api-docs.deepseek.com/guides/vision |
| DS-Files | https://api-docs.deepseek.com/guides/files_api |
| DS-Cache | https://api-docs.deepseek.com/guides/kv_cache |
| DS-Models | https://api-docs.deepseek.com/api/list-models |
| DS-Pricing | https://api-docs.deepseek.com/quick_start/pricing |
| DS-Rate | https://api-docs.deepseek.com/quick_start/rate_limit |
| A-Msg | https://platform.claude.com/docs/en/api/messages/create |
| A-Stream | https://platform.claude.com/docs/en/build-with-claude/streaming |
| A-Vision | https://platform.claude.com/docs/en/build-with-claude/vision |
| A-PDF | https://platform.claude.com/docs/en/build-with-claude/pdf-support |
| A-Tools | https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview |
| A-Models | https://platform.claude.com/docs/en/api/models/list |
| G-Gen | https://ai.google.dev/api/generate-content |
| G-Models | https://ai.google.dev/api/models |
| G-Img | https://ai.google.dev/gemini-api/docs/generate-content/image-understanding |
| G-Doc | https://ai.google.dev/gemini-api/docs/generate-content/document-processing |
| G-Files | https://ai.google.dev/gemini-api/docs/generate-content/file-input-methods |
| G-FC | https://ai.google.dev/gemini-api/docs/generate-content/function-calling |
| G-Think | https://ai.google.dev/gemini-api/docs/generate-content/thinking |
| G-Interactions | https://ai.google.dev/gemini-api/docs/interactions |
