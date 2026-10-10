# 研究：阿里云百炼上哪些模型能接收图片

- 对应 issue：[#70 修复：百炼上能看图的模型（如 qwen3.8-max）被判为不能接收图片](https://github.com/linem7/Chatbot/issues/70)
- 日期：2026-10-10
- 来源：只用 `help.aliyun.com/zh/model-studio/` 和国际站 `alibabacloud.com/help/zh/model-studio/` 的官方文档，主要依据是各模型详情页「模型能力」里的**输入模态**。下面的页面名都在 `https://help.aliyun.com/zh/model-studio/` 下。没有用 API key 发过请求。

## TL;DR

1. **百炼 OpenAI 兼容接口的 `GET {base}/compatible-mode/v1/models` 没有文档**，没有任何页面说它会返回 `input_modalities` 之类的字段。有文档的是原生接口 `GET /api/v1/models`（`list-models`）：输入模态在 `inference_metadata.request_modality`（Text / Image / Audio / Video），视觉理解在 `capabilities` 里的 `VU`。但它的 endpoint 不包括 Token Plan 的域名，Token Plan 的 key 和按量付费的 key、base URL 也「完全隔离，不可混用」。所以 app 只能按模型名查表（`BailianModelTable.acceptsImages`）。
   - 旁证：`add-vision-skill` 页要求在 OpenCode / OpenClaw 里**手动声明** `"input": ["text","image"]`，说明客户端拿不到自动的模态信息（这是推断，文档没有明说）。
2. **同一个模型的输入模态不分地域**。详情页按地域分别列出时，各地域写法一样；不同的只是哪些地域上架了这个模型（第三方托管的模型多数只在北京）。所以这张表不带地域。
3. **同系列里有的型号能看图、有的不能**，不能按系列前缀一刀切，见下面「不支持」一节。
4. 发图用 OpenAI 兼容接口的 `image_url` 就行（`vision`），base64 Data URL 上限 20MB，和 app 现在的发法一致。

## 支持图片输入

| 模型 | 来源页 | 依据 |
|---|---|---|
| qwen3.8-max（含 -0902）、qwen3.8-flash、qwen3.8-27b | `qwen3-8-max`、`qwen3-8-flash`、`qwen3-8-27b` | 输入模态「Image Text Video」 |
| qwen3.8-omni-flash | `qwen3-8-omni-flash`、`qwen-omni` | 「文本、图片、音频、视频」 |
| qwen3.7-plus、qwen3.7-flash（含快照） | `qwen3-7-plus`、`qwen3-7-flash` | 「Image Text Video」 |
| **只有 qwen3.7-max-2026-06-08 这一个快照** | `qwen3-7-max` | 「相较于 5 月 20 日快照增加了视觉模态理解能力」 |
| qwen3.6-plus、qwen3.6-flash（含快照）、qwen3.6-27b、qwen3.6-35b-a3b | 各自详情页 | 「Image Text Video」 |
| qwen3.5-plus、qwen3.5-flash（含快照）、qwen3.5-397b-a17b、122b-a10b、27b、35b-a3b | 各自详情页、`vision-model` | 「Text Image Video」 |
| qwen3.5-omni-plus、qwen3.5-omni-flash | 详情页 | 「Text Image Video Audio」 |
| qwen3-vl-plus / flash、qwen-vl-max / plus、qvq-max / plus、qwen3-omni-flash、qwen-omni-turbo（含快照） | 详情页 | 输入模态含 Image |
| qwen-vl-ocr、qwen3.5-ocr | `vision-model` | OCR 专用模型 |
| kimi-k3、kimi-k2.5、kimi-k2.6、kimi-k2.7-code（含 highspeed） | `kimi-k3`、`kimi-api` | 「Text Image」/「支持同时处理文本、图像或视频输入」 |
| deepseek-v4.1-flash | `deepseek-v4-1-flash` | 「具备原生多模态视觉理解能力」，输入模态「Text、Image」 |
| ZHIPU/GLM-5.3-Flash、ZHIPU/GLM-5.3-FlashX | `glm-zhipu` | 「原生支持图像、视频与文件输入」 |
| MiniMax/MiniMax-M3 | `minimax-m3` | 「Image Text Video」 |
| stepfun/step-3.7-flash、stepfun/step-5-preview | 详情页 | 「Text Image Video」 |

Token Plan 的模型表（`token-plan-personal-overview`、`token-plan-team-overview`，国际站 `token-plan-overview`）把 qwen3.8-max、qwen3.8-flash、qwen3.7-plus、qwen3.6-flash、deepseek-v4.1-flash 标为「视觉理解」，团队版另外列了 qwen3.6-plus、kimi-k2.5、kimi-k2.6、kimi-k2.7-code。qwen3.7-max 和 auto 没有标。和上表一致。

## 不支持（详情页输入模态只有 Text）

- 千问：qwen3.7-max 及 -preview、-2026-05-20、-2026-05-17 快照（「当前开放纯文本模型能力…等同于快照模型 qwen3.7-max-2026-05-20」）；qwen3.6-max-preview；**qwen3.8-2.4t-a95b**；qwen3-max 全系；qwen-max、qwen-plus、qwen-flash、qwen-turbo、qwen-long、qwq-plus；qwen3-coder 系列；开源 Qwen3。
- Token Plan 的 auto。
- DeepSeek：deepseek-v4-pro、deepseek-v4-flash（含快照）、deepseek-v3.x。
- GLM：glm-5.3、glm-5.2、glm-5.1、glm-5、glm-4.x。
- Kimi：kimi-k2-thinking、Moonshot-Kimi-K2-Instruct。
- 其他：MiniMax-M2 / M2.5 / M2.7、xiaomi/mimo-v2.5-pro。

## 一处矛盾

`deepseek-api` 的 FAQ 写「DeepSeek 模型仅支持文本输入，不支持图片或文档输入」，和 `deepseek-v4-1-flash` 详情页、Token Plan 模型表都冲突。按 #62 的做法以模型详情页为准，把 deepseek-v4.1-flash 算作能看图；FAQ 大概是旧内容。

## 没覆盖到的

- Qwen2.5-VL 在 `vision` 页提到过，没有看它的详情页，没有收进表里。
- QVQ 只支持流式、而且是仅思考模型；Qwen3-Omni-Flash 只支持「文本与单一其他模态」的组合。这些是能不能好好用的问题，不影响「能不能接收图片」，表里照收。
