# Web Search 只用 Provider 的原生能力，DeepSeek 不联网

> 2026-10-09 修订（#48、#54）：除了 Provider 的原生搜索，也使用 **Platform 自带的搜索**。OpenAI 兼容 Connection 如果在 OpenRouter 或阿里云百炼上，就能联网：
> - **OpenRouter** 在 `tools` 里加 `{"type": "openrouter:web_search"}`，由模型决定搜不搜，引用从流里的 `annotations`（`url_citation`）取，正文里照常显示角标和来源列表。EU 端点（`eu.openrouter.ai`）上没有搜索引擎，不联网。
> - **阿里云百炼**发 `enable_search: true`。它的 OpenAI 兼容接口不返回来源，所以没有角标、来源列表和「正在搜索」。
> - **不是这两个平台上的所有 Model 都能联网**。OpenRouter 的 `openrouter:web_search` 引擎在平台侧，任何 Model 都能用（EU 端点除外）；百炼的清单按模型名给，而且**分地域**（北京、新加坡、全球三张表差别很大，全球地域上一个 DeepSeek 都没有），按模型名和地域查 `BailianModelTable`，查不到就置灰。其他 OpenAI 兼容 Connection（DeepSeek 官方、OpenAI 官方、普通中转）仍然不联网。
>
> 这仍然是「服务端执行的搜索」，app 不调用任何外部搜索服务，和下面的原则一致：搜索由 Provider 或 Platform 在服务端执行。调研见 `docs/research/third-party-web-search.md`。

用户不想接外部搜索服务，所以 Web Search 只使用 Provider 在服务端提供的原生搜索：Anthropic 的 `web_search` 工具，以及 Gemini 的 `google_search`。OpenAI 兼容 Provider 在 v1 不支持搜索。原因有两个：DeepSeek API 根本没有原生搜索（截至 2026-10 只支持 `function` 类型的工具）；OpenAI 官方只有专用的搜索模型，而且每次请求都会先搜一遍。

这意味着**用户主要使用的 DeepSeek 没有联网能力**（直连 DeepSeek 官方时如此；经 OpenRouter 或百炼使用 DeepSeek 时，按上面的修订可以联网）。「是否支持 Web Search」是 Model Capabilities 的一项，Model 不支持时，面板上的搜索开关会置灰。

## Considered Options

- **由模型发起 tool call，app 用 Tavily 执行搜索**（#1 开图时的原方案，研究见 #5）：否决。DeepSeek 也能搜，但要多接一个外部服务，多管理一个 key。
- **混合方案：有原生搜索就用原生，DeepSeek 用 Tavily**：否决。要维护两套搜索路径和两套来源格式。

## Consequences

- Gemini 的条款要求必须原样展示「搜索建议」组件（`searchEntryPoint.renderedContent`，一段 HTML），所以要在回答下方用 WebView 渲染它。另外 Gemini 的搜索次数无法限制。
- Anthropic 用 `max_uses: 3` 限制每个 Turn 的搜索次数，同时要处理 `pause_turn` 续接，以及搜索结果块的原样回传。
- 如果以后要让 DeepSeek 也能联网，从 `docs/research/search-providers.md` 开始，由 Turn 执行一个 app 侧的搜索工具即可，ADR-0001 的结构不需要改。
