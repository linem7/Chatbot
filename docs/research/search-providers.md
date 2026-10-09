# 研究：Web Search 服务商对比

- 对应 issue：[#5 研究：搜索服务商对比](https://github.com/linem7/Chatbot/issues/5)（Part of #1）
- 日期：2026-10-08（所有价格、限额均为当日官方页面所示，之后可能变动）
- 前提：模型（DeepSeek，OpenAI 兼容 Provider）通过 tool calling 调用 app 侧的 **Web Search**；app 是原生 Swift，只能用 `URLSession` 直接发 REST 请求；回答必须带来源链接（见 `CONTEXT.md`、README）
- 方法：只引用官方定价页、官方 API reference、官方 OpenAPI spec；第三方材料仅用于标注风险，并明确标出

## TL;DR

1. **默认：Tavily `POST /search`**。免费 1,000 credits/月且**不需要信用卡**；一次请求就返回 `title / url / content`（多段正文片段，约 500 字符/段）+ 可选 `published_date`，app 不用自己抓网页；`Authorization: Bearer`，纯 JSON，Swift 直接调；有 `country: "china"` 和 `language: "zh-cn"` 参数。按量 $0.008/credit，basic 搜索 1 credit → **约 $8 / 1k 次**。
2. **备选：Brave Search API**。$5 / 1k 次，自有索引（官方称 40B+ 页面），`search_lang=zh-hans`、`country=CN` 都在官方枚举里，结果带 `page_age`，`extra_snippets=true` 可多拿 5 段摘录；另有 LLM Context 端点直接返回为 LLM 抽好的正文片段。缺点：**免费额度（$5/月）也要绑信用卡**。
3. Exa 功能最强（`numResults` 可到 100、正文/highlights 可选、`publishedDate`），但带正文后约 $14–17 / 1k 次，适合作为"深度模式"而非默认。SerpAPI 只给 SERP 摘要且最贵（$25/1k 起），但它的 `engine=baidu` 是这几家里**唯一能直接拿百度结果**的，可作为中文兜底的可选项。Jina `s.jina.ai` 返回全文最省事，但按 token 计费且实际消耗不可控（见 §6），不建议默认。Perplexity Search API $5/1k（fast $1/1k），格式简洁，可作为第二备选。
4. **中文查询质量没有任何一家给出官方数据**，需要用一组中文 query 实测（见 §9）。

---

## 1. 对比总表

| | Tavily | Brave Search | Exa | SerpAPI | Jina `s.jina.ai` | Perplexity Search |
|---|---|---|---|---|---|---|
| 单价 / 1k 次（每次 ~10 条结果） | basic $8（PAYG $0.008/credit × 1）；advanced $16；订阅 $30/4,000 credits ≈ $7.5 [^tv-credits] | $5 [^brave-plans] | `auto`/`fast` $7、`instant` $4（≤10 条）；正文/highlights 另计 $1 / 1k 页 [^exa-pricing] | Starter $25/1,000 次；Developer $75/5,000 ≈ $15 [^serp-pricing] | 每次 ≥10,000 tokens；单 token 价格未在公开页面给出 [^jina-reader] | $5；`fast` $1 [^pplx-pricing] |
| 免费额度 | 1,000 credits/月 [^tv-pricing] | $5 credits/月（≈1,000 次）[^brave-plans] | $10/月（每月 1 日重置，≈2,500 次 instant）[^exa-pricing] | 250 次/月，50 次/小时 [^serp-pricing] | 新 key 送 10M tokens（≈≤1,000 次）[^jina-reader] | 官方未写免费额度 [^pplx-pricing] |
| 需要信用卡？ | 否（"No credit card required"）[^tv-pricing] | **是**（免费计划也要，用于反欺诈、不扣款）[^brave-plans] | 否（Free Tier 不需要付款方式）[^exa-pricing] | 否（官方博客）[^serp-blog] | 未说明 | 未说明 |
| 认证 | `Authorization: Bearer tvly-…` [^tv-search] | `X-Subscription-Token` header [^brave-query] | `x-api-key` 或 `Authorization: Bearer` [^exa-search] | `api_key` query 参数 [^serp-search] | `Authorization` header；无 key 直接 401 [^jina-probe] | `Authorization: Bearer` [^pplx-search] |
| 方法 / 端点 | `POST https://api.tavily.com/search` | `GET https://api.search.brave.com/res/v1/web/search` | `POST https://api.exa.ai/search` | `GET https://serpapi.com/search` | `GET/POST https://s.jina.ai/{q}` | `POST https://api.perplexity.ai/search` |
| 自带正文？ | 是：`content` = 1–3 段原文片段（~500 字符，advanced ~800）；可选 `raw_content` 全文 [^tv-search] | 默认只有 `description`；`extra_snippets` 最多 +5 段；LLM Context 端点返回抽好的 `snippets` [^brave-get][^brave-llm] | 可选 `text`（全文，可设 `maxCharacters`）/ `highlights` / `summary`，默认关闭 [^exa-search] | 否，只有 SERP `snippet` [^serp-search] | 是：默认对前几条结果跑 Reader，返回全文 `content` [^jina-readme] | `snippet`，可用 `max_tokens_per_page` 控制抽取量 [^pplx-search] |
| 来源 URL | `url` | `url` | `url` | `link` | `url` | `url` |
| 发布日期 | `published_date`（需 `include_published_date: true`，beta，可能为 null）[^tv-search] | `page_age`（发布或最后修改日期）；`age` 为人类可读 [^brave-get] | `publishedDate`（估计值，YYYY-MM-DD）[^exa-search] | Google `organic_results` 示例里无 `date` [^serp-search] | `publishedTime`（schema 字段，可能缺）[^jina-openapi] | `date`、`last_updated`，可为 null [^pplx-search] |
| 单次最多结果数 | `max_results` 0–20，默认 10 [^tv-search] | `count` 1–20，默认 20 [^brave-get] | `numResults` 1–100，默认 10 [^exa-search] | Baidu `rn` ≤ 50 [^serp-baidu] | `num`/`count` 0–20；README 说默认取前 5 条 [^jina-openapi][^jina-readme] | `max_results` 1–20，默认 10 [^pplx-search] |
| 速率限制 | dev key 100 RPM，prod key 1,000 RPM [^tv-rate] | Search 计划 50 QPS [^brave-plans] | `/search` 10 QPS（deep 类 5 QPS）[^exa-rate] | 按计划：免费 50/小时，Starter 200/小时 [^serp-pricing] | 免费/付费 key 100 RPM，Premium 1,000 RPM [^jina-rate] | 50 query units/秒，与 tier 无关 [^pplx-rate] |
| 官方延迟数据 | 未给数字；`fast`/`ultra-fast` 档位主打低延迟；响应带 `response_time` [^tv-search] | 未给数字；宣称第三方评测"lowest latency" [^brave-plans] | 仅 `deep-lite` 标"consistent 4-second latency"；响应带 `searchTime` [^exa-search] | 未说明 | 搜索平均 2.5s，Reader 平均 7.9s [^jina-rate] | 未给数字；`fast` 档主打低延迟 [^pplx-search] |
| 中文 / 地区参数 | `country` 枚举含 `china`、`taiwan`（无 hong kong）；`language` 可设 `zh-cn`（加权，非过滤）[^tv-search] | `country` 含 `CN/HK/TW`；`search_lang` 含 `zh-hans/zh-hant`；`ui_lang` 含 `zh-CN` 等 [^brave-get] | 仅 `userLocation`（ISO 国家码）；文档未提语言 [^exa-search] | Google `gl`/`hl`；另有 `engine=baidu`（`ct=2` 简体）[^serp-search][^serp-baidu] | `gl`、`hl`、`location`；底层 `engine` 可选 `google`/`bing` [^jina-openapi] | `country`（ISO alpha-2）、`search_language_filter`（ISO 639-1）[^pplx-search] |
| Swift 直接调 | 是（单个 JSON POST） | 是（GET + header） | 是 | 是（key 在 URL 里，日志易泄漏） | 是，但响应体可能很大 | 是 |

> "单价 / 1k 次"统一按"一次搜索拿 ~10 条且有足够正文喂模型"来算才公平：Tavily/Jina 一次就够；Brave 用 `extra_snippets` 不额外收费；Exa 若每条都要 highlights，10 条 × $1/1k 页 = 额外 $10/1k 次，合计 `auto` ≈ $17、`instant` ≈ $14（按 [^exa-pricing] 推算）；SerpAPI 只有摘要，要正文还得 app 自己抓页面。

---

## 2. Tavily

- **价格**：Researcher 免费 1,000 credits/月；Project $30/4,000；Bootstrap $100/15,000；Startup $220/38,000；Growth $500/100,000；PAYG $0.008/credit（[api-credits](https://docs.tavily.com/documentation/api-credits)）。免费层"No credit card required"（[pricing](https://www.tavily.com/pricing)）。
- **计费**：`search_depth` 为 `advanced` 2 credits，`basic` / `fast` / `ultra-fast` 1 credit（[search reference](https://docs.tavily.com/documentation/api-reference/endpoint/search)）。Extract 每 5 个成功 URL 1 credit（basic），失败不计费（[api-credits](https://docs.tavily.com/documentation/api-credits)）。
- **请求**：`query`、`search_depth`、`max_results`（0–20，默认 10）、`chunks_per_source`（1–3）、`topic`（`general`/`news`/`finance`）、`time_range`、`start_date`/`end_date`、`include_answer`、`include_raw_content`（`markdown`/`text`）、`include_published_date`、`country`、`language`、`include_domains`/`exclude_domains`（[search reference](https://docs.tavily.com/documentation/api-reference/endpoint/search)）。
- **响应**：`results[]` 含 `title`、`url`、`content`、`score`、`raw_content`、`published_date`、`favicon`；顶层 `answer`、`response_time`、`usage.credits`、`request_id`（同上）。
- **`content` 是什么**：basic/advanced/fast 下是多段原文片段用 `[...]` 拼接，每段约 500 字符（advanced 约 800），段数由 `chunks_per_source` 控制；`ultra-fast` 下是每个 URL 一段 NLP 摘要（同上）。→ 直接可作为模型上下文。
- **日期**：`published_date` 是 "Tavily's best estimate of when the source was published or last updated"，beta，取不到为 `null`；`topic=news` 时自动开启（同上）。
- **中文**：`country` 枚举含 `china`、`taiwan`；`language` 接受 `zh-cn` 等 ISO 639-1 码，作用是加权而非过滤，`filter_by_language: true` 才严格过滤；官方建议 query 本身用同一语言（同上）。
- **速率**：dev key 100 RPM，prod key 1,000 RPM（[rate-limits](https://docs.tavily.com/documentation/rate-limits)）。

## 3. Brave Search API

- **价格**：Search 计划 $5 / 1k 请求，每月自动送 $5 credits，50 QPS；Answers 计划 $4 / 1k + $5 / 百万 token，2 QPS；Enterprise 联系销售（[brave.com/search/api](https://brave.com/search/api/)）。
- **信用卡**：FAQ 原文 "The credit card requirement serves as an anti-fraud measure…" "For free plans, the card is only used to confirm your identity and will not be charged."（同上）。这对"让用户自带 key"的分发方式是一个门槛。
- **存储权**：要存储结果（例如用于训练/微调 LLM）需订阅明确授予 storage rights 的计划（同上）。app 只把结果当一次性上下文用，按字面理解不涉及，但若将来把搜索结果持久化进 Conversation 历史，需要再确认条款。
- **Web Search 请求**：`GET https://api.search.brave.com/res/v1/web/search`，header `X-Subscription-Token`；`count` 1–20（默认 20）、`offset` 最大 9、`freshness`（`pd`/`pw`/`pm`/`py` 或日期区间）、`extra_snippets`（最多 5 段额外摘录）（[query 文档](https://api-dashboard.search.brave.com/app/documentation/web-search/query)、[API reference](https://api-dashboard.search.brave.com/api-reference/web/search/get)）。
- **中文**：`country` 枚举含 `CN`、`HK`、`TW`；`search_lang` 枚举含 `zh-hans`、`zh-hant`；`ui_lang` 含 `zh-CN`、`zh-HK`、`zh-TW`（[API reference](https://api-dashboard.search.brave.com/api-reference/web/search/get)）。
- **响应**：`web.results[]` 含 `title`、`url`、`description`、`extra_snippets`、`page_age`（"The page's date, based on its published or last modified date"）（同上）。
- **LLM Context 端点**：`POST https://api.search.brave.com/res/v1/llm/context`，返回 `grounding.generic[]`，每项 `url`、`title`、`snippets`（与 query 相关的正文片段）；可用 `maximum_number_of_tokens`（1,024–32,768，默认 8,192）、`maximum_number_of_urls`（1–50）等控制体积；响应 schema 里没有逐条日期字段（[LLM Context reference](https://api-dashboard.search.brave.com/api-reference/summarizer/llm_context/post)）。Search 计划描述为 "Complete search results … with additional LLM context optimized for AI"（[brave.com/search/api](https://brave.com/search/api/)），LLM Context 端点本身的 reference 未写单价。
- **索引**：官方称 "40+ billion pages, kept fresh by 100+ million page updates every day"（[brave.com/search/api](https://brave.com/search/api/)）。

## 4. Exa

- **价格（/ 1k 请求，含 ≤10 条结果）**：`instant` $4，`fast`/`auto` $7，`deep-lite`/`deep` $12，`deep-reasoning` $15；超过 10 条每条 $1/1k；`text`、`highlights`、`summary` 各自 $1 / 1k 页，同一页要两种算两份（[exa.ai/pricing](https://exa.ai/pricing)）。
- **免费**：注册送 $10（≈2,500 次 instant），每月 1 日重置到 $10；Free Tier 不需要付款方式（同上）。
- **请求**：`POST https://api.exa.ai/search`，`x-api-key` 或 `Authorization: Bearer`；`type`、`numResults`（1–100，默认 10）、`contents.text`（可设 `maxCharacters`）/`highlights`/`summary`、`maxAgeHours`（取代已废弃的 `livecrawl`）、`userLocation`、`startPublishedDate`/`endPublishedDate`、`category`、`includeDomains`/`excludeDomains`（[search reference](https://exa.ai/docs/reference/search)）。`text`、`highlights` 作为布尔时默认 `false`，即不显式要就没有正文（同上）。
- **响应**：每条 `title`、`url`、`publishedDate`（估计值）、`author`、`text`、`highlights`、`summary`；顶层 `costDollars`（逐项计费明细）、`searchTime`（ms）（同上）。
- **速率**：`/search` 10 QPS，deep 类 5 QPS，`/contents` 100 QPS；超限返回 429，带 `Retry-After`（[rate-limits](https://exa.ai/docs/reference/rate-limits)）。
- **中文**：文档只有 `userLocation`，没有语言参数，也没有提多语言支持（[search reference](https://exa.ai/docs/reference/search)）。

## 5. SerpAPI

- **价格**：Free $0 / 250 次/月 / 50 次/小时；Starter $25 / 1,000；Developer $75 / 5,000；Production $150 / 15,000；之后阶梯到百万级（[pricing](https://serpapi.com/pricing)）。2026-04-17 官方博客："the free tier includes 250 searches per month, no credit card required"（[blog](https://serpapi.com/blog/introducing-serpapis-claude-code-plugin/)）。
- **缓存**："Cached searches are free, and are not counted towards your searches per month"（[search-api](https://serpapi.com/search-api)）。
- **请求/响应**：`GET https://serpapi.com/search?engine=google&q=…&api_key=…`，`gl`、`hl`、`location`、`google_domain`；`organic_results[]` 含 `position`、`title`、`link`、`snippet`、`source`，官方示例中无 `date`（同上）。**只给 SERP 摘要，不给正文**，要正文需 app 再抓页面。
- **百度**：`engine=baidu`，`ct=2` 只要简体中文，`rn` 最多 50 条；`organic_results` 含 `title`、`link`、`snippet`（[baidu-search-api](https://serpapi.com/baidu-search-api)）。这是六家中唯一能直接查百度的。
- **注意**：key 走 query string，容易出现在日志/代理里。

## 6. Jina（`s.jina.ai` / `r.jina.ai`）

- **用法**：`https://s.jina.ai/{url-encoded query}`；它取前几条搜索结果并对每个 URL 跑一次 `r.jina.ai`，所以返回的是全文而不是只有标题+摘要（[jina-ai/reader README](https://github.com/jina-ai/reader)）。
- **认证**：搜索端点**必须带 key**。实测无 key 请求返回 `401 AuthenticationRequiredError: … Please provide a valid API key via Authorization header.`（2026-10-08 本地 `curl https://s.jina.ai/?q=…` 实测）；官方限额表也标注无 key 为 "block"（[rate-limit](https://jina.ai/api-dashboard/rate-limit)）。
- **参数**（官方 OpenAPI，`https://s.jina.ai/openapi.json`）：`num`/`count` 0–20、`page`、`gl`、`hl`、`location`、`engine`/`provider`（`google`/`bing`/`reader`）、`site`、`type`（`web`/`images`/`news`）；header `Accept: application/json`、`X-Respond-With`、`X-Token-Budget`、`X-Max-Tokens` 等（[openapi.json](https://s.jina.ai/openapi.json)）。
- **响应**（JSON 模式）：信封 `{code, status, data[], meta}`；`data[]` 为 `FormattedPageDto`，含 `title`、`url`、`description`、`content`、`publishedTime` 等（同上）。
- **计费**：按 token；搜索 "Every request costs a fixed number of tokens, starting from 10,000 tokens"（[reader](https://jina.ai/reader/)、[api-dashboard/pricing](https://jina.ai/api-dashboard/pricing/)）；新 key 送 10M tokens（[reader](https://jina.ai/reader/)）。公开页面没写每 token 单价。
- **风险（非官方，用户报告）**：2026-04-09 有用户在官方仓库报告单次搜索最高消耗约 1.9M tokens、7 天平均约 159k tokens/次，加了 `X-Respond-With: no-content` 与 `X-Token-Budget` 仍超额，截至抓取时无维护者回复（[issue #1241](https://github.com/jina-ai/reader/issues/1241)）。→ 成本不可预测。
- **速率/延迟**：搜索免费/付费 key 100 RPM、Premium 1,000 RPM，平均 2.5s；Reader 无 key 20 RPM、有 key 500 RPM，平均 7.9s（[rate-limit](https://jina.ai/api-dashboard/rate-limit)）。同站 FAQ 的另一组数字与此表不一致（[reader](https://jina.ai/reader/)），以限额表为准。

## 7. Perplexity（Search API / Sonar，可选）

- **Search API**：`POST https://api.perplexity.ai/search`，`Authorization: Bearer`；`query`（字符串或最多 5 个 query 的数组）、`max_results` 1–20（默认 10）、`max_tokens`、`max_tokens_per_page`、`country`、`search_language_filter`（ISO 639-1，最多 10 个）、`search_domain_filter`、`search_type: "fast"`；响应 `results[]` 含 `title`、`url`、`snippet`、`date`、`last_updated`（日期可为 null）（[search quickstart](https://docs.perplexity.ai/guides/search-quickstart)）。
- **价格**：Search API $5 / 1k 请求，Fast Search $1 / 1k，仅成功请求计费、无 token 费（[pricing](https://docs.perplexity.ai/getting-started/pricing)）。
- **速率**：50 query units/秒，burst 50，与 usage tier 无关；多 query 数组按 query 数计入限额但按 1 次计费（[rate-limits](https://docs.perplexity.ai/guides/rate-limits-usage-tiers)）。Tier 0 描述为 "New accounts, limited access"，文档未写免费额度（同上）。
- **Sonar**：是"搜索 + 生成"一体的模型（Sonar 请求费 $5–12/1k + token 费，见 [pricing](https://docs.perplexity.ai/getting-started/pricing)），与本 app"DeepSeek 负责生成、app 侧提供搜索 tool"的架构重叠，不适合作为搜索 tool 的后端。

## 8. 推荐

**默认：Tavily（`search_depth: "basic"`, `max_results: 5–8`, `include_published_date: true`）**

- 不需要信用卡就能拿到每月 1,000 次免费额度——对"用户自带 key"的个人 app，注册门槛最低（[pricing](https://www.tavily.com/pricing)）。
- 一次请求即得到可直接喂模型的原文片段 + URL + 日期，省掉 app 侧抓页面/抽正文这整块（[search reference](https://docs.tavily.com/documentation/api-reference/endpoint/search)）。
- 有中文相关参数（`country: "china"`、`language: "zh-cn"`）（同上）。
- 响应自带 `usage.credits`、`response_time`，方便在设置页显示用量。

**备选：Brave Search API（Web Search + `extra_snippets=true`，或 LLM Context 端点）**

- 单价最低档之一（$5/1k），自有索引，与 Tavily 不同源，挂掉或质量不佳时切过去有意义（[brave.com/search/api](https://brave.com/search/api/)）。
- 中文参数最完整（`search_lang=zh-hans`、`country=CN`）且有 `page_age`（[API reference](https://api-dashboard.search.brave.com/api-reference/web/search/get)）。
- 代价：注册必须绑卡；默认响应只有摘要，要么开 `extra_snippets`，要么走 LLM Context。

**其余定位**

- Perplexity Search：格式与 Tavily 最接近、`fast` 档 $1/1k 最便宜，可作为第二备选（[pricing](https://docs.perplexity.ai/getting-started/pricing)）；但免费额度未写明。
- Exa：将来做"深度搜索"模式时考虑（`numResults` 到 100、按需全文）。
- SerpAPI `engine=baidu`：如果实测发现大陆中文内容召回明显不足，再作为可选 provider 引入；只返回摘要。
- Jina：只考虑 `r.jina.ai` 作为"模型想读某个 URL 全文"的第二个 tool；不用 `s.jina.ai` 做默认搜索（计费不可控）。

## 9. 抽象层需要归一化的内容

建议一个 `SearchProvider` 协议 + 统一结果类型，各家适配器负责映射：

| 统一字段 | Tavily | Brave（web） | Brave（LLM Context） | Exa | SerpAPI | Jina | Perplexity |
|---|---|---|---|---|---|---|---|
| `title` | `title` | `title` | `title` | `title` | `title` | `title` | `title` |
| `url` | `url` | `url` | `url` | `url` | `link` | `url` | `url` |
| `snippet`（短） | `content` 首段 | `description` | — | `highlights[0]` | `snippet` | `description` | `snippet` |
| `content`（喂模型的正文） | `content`（或 `raw_content`） | `description` + `extra_snippets[]` | `snippets[]` 拼接 | `text` / `highlights[]` | 无（需自己抓） | `content` | `snippet` |
| `publishedAt: Date?` | `published_date` | `page_age` | 无 | `publishedDate` | 通常无 | `publishedTime` | `date` / `last_updated` |
| `score` | `score` | 无（用名次） | 无 | 无 | `position` | 无 | 无 |

还需要统一的：

- **请求参数**：`query`、`maxResults`（各家上限不同：Tavily/Brave/Jina/Perplexity 20，Exa 100）、`recency`（Tavily `time_range` / Brave `freshness` / Exa `startPublishedDate`；Perplexity quickstart 未覆盖时间过滤参数，接入时再确认）、`region` / `language`（各家码表不同：Tavily 用英文国家名 `china`，Brave 用 `CN` + `zh-hans`，Perplexity 用 ISO 码）、`includeDomains` / `excludeDomains`。
- **日期解析**：格式不一（Tavily/Exa 字符串日期、Brave ISO 时间戳、Perplexity 可能为 null），全部解析成 `Date?`，解析失败当作 nil，不要让模型看到 "2 days ago" 这类相对时间。
- **正文截断**：各家正文长度差异极大（Jina 全文 vs Brave 摘要），适配层按 token 预算统一截断，避免撑爆 DeepSeek 上下文。
- **认证注入**：Bearer / `X-Subscription-Token` / `x-api-key` / query 里的 `api_key` 四种方式；key 从 Keychain 取。
- **错误**：401/403（key 错）、402/额度用尽、429（带 `Retry-After` 时遵守）统一成几种错误，额度用尽时自动切备选 provider。
- **用量**：Tavily `usage.credits`、Exa `costDollars`、Jina token 数可选上报给设置页。

## 10. 未验证 / 待实测

- **中文查询质量**：六家都没有公开中文检索质量数据。建议准备 20 条左右的中文 query（时效新闻、国内技术文档、知乎/CSDN 类问答、政府公告），对 Tavily / Brave / Perplexity 各跑一遍，看召回的中文站点比例与正文可用性。
- **大陆网络可达性与地区限制**：本次查阅的官方页面都没有写明是否限制中国大陆 IP 或账号注册地区，需实测（含是否需要代理）。
- **延迟**：只有 Jina 给了平均值（2.5s）；Tavily / Exa / Perplexity 响应里都带服务器耗时字段，实测时一并记录 p50/p95。
- **Brave LLM Context 计费**：Search 计划页面提到包含 LLM context，但 reference 未写单价，接入前在 dashboard 确认。

---

[^tv-pricing]: https://www.tavily.com/pricing
[^tv-credits]: https://docs.tavily.com/documentation/api-credits
[^tv-search]: https://docs.tavily.com/documentation/api-reference/endpoint/search
[^tv-rate]: https://docs.tavily.com/documentation/rate-limits
[^brave-plans]: https://brave.com/search/api/
[^brave-query]: https://api-dashboard.search.brave.com/app/documentation/web-search/query
[^brave-get]: https://api-dashboard.search.brave.com/api-reference/web/search/get
[^brave-llm]: https://api-dashboard.search.brave.com/api-reference/summarizer/llm_context/post
[^exa-pricing]: https://exa.ai/pricing
[^exa-search]: https://exa.ai/docs/reference/search
[^exa-rate]: https://exa.ai/docs/reference/rate-limits
[^serp-pricing]: https://serpapi.com/pricing
[^serp-blog]: https://serpapi.com/blog/introducing-serpapis-claude-code-plugin/
[^serp-search]: https://serpapi.com/search-api
[^serp-baidu]: https://serpapi.com/baidu-search-api
[^jina-reader]: https://jina.ai/reader/ ；https://jina.ai/api-dashboard/pricing/
[^jina-rate]: https://jina.ai/api-dashboard/rate-limit
[^jina-readme]: https://github.com/jina-ai/reader
[^jina-openapi]: https://s.jina.ai/openapi.json
[^jina-probe]: 2026-10-08 无 key 请求 `https://s.jina.ai/?q=…` 返回 HTTP 401 `AuthenticationRequiredError`
[^pplx-pricing]: https://docs.perplexity.ai/getting-started/pricing
[^pplx-search]: https://docs.perplexity.ai/guides/search-quickstart
[^pplx-rate]: https://docs.perplexity.ai/guides/rate-limits-usage-tiers
