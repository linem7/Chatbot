/// 百炼（DashScope）的模型能力表：能用平台联网搜索的模型，和能接收图片的模型（`acceptsImages`）。
///
/// 百炼的联网不是「这个平台上的模型都能用」：清单按**模型名**给，而且**分地域**——
/// 北京、新加坡、全球三张表差别很大（全球地域上一个 DeepSeek 都没有）。`/models` 里看不出这个能力，
/// 所以只能查表，查不到就是不支持。
///
/// 依据：https://help.aliyun.com/zh/model-studio/web-search 的「支持的模型」（2026-10-09 抓取，
/// 整理见 `docs/research/third-party-web-search.md` §2.2）。百炼上新模型时按同一页更新。
///
/// 表里只收「本 app 现在发出去的请求能真正搜到」的模型：
/// - 需要 `search_strategy: agent` 的（千问 Omni、Omni-Realtime 系列）不收。客户端只发 `enable_search`，
///   策略走默认值，文档说这些模型必须设 agent 才会检索——收了按钮会亮，但搜不到；
/// - 只能走 Responses API 的（glm-5.2、kimi-k3）不收。这里走的是 Chat Completions。
///
/// 「联网搜索」页的清单会滞后：**模型页说支持的模型不一定出现在清单里**（`deepseek-v4.1-flash` 就是，
/// #62）。遇到这种矛盾以模型页为准把它补进来，不要默认它不支持。反过来说，清单里没有的模型也应该
/// 去模型页确认一遍再排除。
enum BailianModelTable {
    /// 一个地域上能联网的模型。第三方模型数量少、快照是固定的，写全名；
    /// 千问的快照版本按日期不断新增，写前缀族。
    private struct Entry {
        var names: Set<String> = []
        var prefixes: [String] = []
    }

    /// 能不能接收图片输入。百炼的 OpenAI 兼容 `/models` 没有文档说会报告 `input_modalities`，
    /// 只能按模型名查表，查不到就是不支持（保守默认，#70）。
    ///
    /// 依据：各模型详情页「模型能力」里的输入模态（2026-10-10 抓取，整理见
    /// `docs/research/bailian-vision-models.md`）。同一个模型的输入模态不分地域，只是上架的地域不同，
    /// 所以这张表不带地域。百炼上新模型时按模型详情页更新。
    ///
    /// 同一个系列里有的型号能看图、有的不能，所以前缀写到具体型号：
    /// - `qwen3.7-max` 是纯文本，只有 `qwen3.7-max-2026-06-08` 这一个快照加了视觉，写全名；
    /// - `qwen3.8-2.4t-a95b`、`qwen3.6-max-preview` 是纯文本，不能用 `qwen3-8-`、`qwen3-6-` 当前缀；
    /// - `glm-5.3` 是纯文本，只有 Flash、FlashX 能看图；
    /// - DeepSeek 只有 `deepseek-v4.1-flash` 能看图。
    static func acceptsImages(_ modelID: String) -> Bool {
        let modelID = normalized(modelID)
        // 实时语音、同传、向量和排序模型不走这里的 Chat Completions
        if ["realtime", "livetranslate", "embedding", "rerank"].contains(where: modelID.contains) { return false }
        if imageModelNames.contains(modelID) { return true }
        // 前缀要么等于全名，要么后面跟 `-`（快照日期），`qwen3-5-flash` 不会命中 `qwen3-5-flashx` 之类的别的型号
        return imageModelPrefixes.contains { modelID == $0 || modelID.hasPrefix($0 + "-") }
    }

    /// 能看图的单个型号（没有快照，或者同系列里只有这一个快照能看图）。
    private static let imageModelNames: Set<String> = [
        "qwen3-7-max-2026-06-08",
        "qwen3-8-27b", "qwen3-6-27b", "qwen3-6-35b-a3b",
        "qwen3-5-397b-a17b", "qwen3-5-122b-a10b", "qwen3-5-27b", "qwen3-5-35b-a3b",
        "deepseek-v4-1-flash",
        "glm-5-3-flash", "glm-5-3-flashx",
        "minimax-m3",
        "step-3-7-flash", "step-5-preview",
    ]

    /// 能看图的型号族，包括带日期的快照。
    private static let imageModelPrefixes: [String] = [
        "qwen3-8-max", "qwen3-8-flash", "qwen3-8-omni-flash",
        "qwen3-7-plus", "qwen3-7-flash",
        "qwen3-6-plus", "qwen3-6-flash",
        "qwen3-5-plus", "qwen3-5-flash", "qwen3-5-omni-plus", "qwen3-5-omni-flash", "qwen3-5-ocr",
        "qwen3-vl", "qwen-vl", "qvq", "qwen3-omni-flash", "qwen-omni-turbo",
        "kimi-k3", "kimi-k2-5", "kimi-k2-6", "kimi-k2-7-code",
    ]

    static func supportsWebSearch(_ modelID: String, in region: Platform.BailianRegion) -> Bool {
        let modelID = normalized(modelID)
        // 千问 Omni / Omni-Realtime 系列要 search_strategy: agent 才会检索
        if modelID.contains("-omni") { return false }
        let entry = entries(for: region)
        return entry.names.contains(modelID) || entry.prefixes.contains { modelID.hasPrefix($0) }
    }

    /// 查表用的模型名：小写、去掉厂商前缀、点号写成连字符（文档里的 `deepseek-v3.2` 在这里写成 `deepseek-v3-2`）。
    /// 只做这一层归一化：百炼的模型 ID 本来就带点号，`deepseek-v4.1-flash` 归一化后是 `deepseek-v4-1-flash`，
    /// 不会撞上 `deepseek-v4-flash`。
    static func normalized(_ modelID: String) -> String {
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return name.lowercased().replacingOccurrences(of: ".", with: "-")
    }

    private static func entries(for region: Platform.BailianRegion) -> Entry {
        switch region {
        case .beijing: beijing
        case .singapore: singapore
        case .global: global
        }
    }

    /// 华北2（北京）。千问最全，第三方有 DeepSeek、Kimi、MiniMax。
    private static let beijing = Entry(
        names: [
            // deepseek-v4 系列同时支持 Responses API，这里走 Chat Completions
            "deepseek-v4-pro", "deepseek-v4-pro-0813", "deepseek-v4-flash", "deepseek-v4-flash-0731",
            // 不在「联网搜索」页的清单里，但 DeepSeek 模型页的「其它功能」写着支持，用户在用它（#62）
            "deepseek-v4-1-flash",
            "deepseek-v3-2", "deepseek-v3-2-exp", "deepseek-v3-1",
            "deepseek-r1-0528", "deepseek-r1", "deepseek-v3",
            // Kimi 的 kimi-k3 只能走 Responses API
            "moonshot-kimi-k2-instruct",
            // MiniMax 不支持 agent 策略，默认策略能搜
            "minimax-m2-1",
        ],
        prefixes: [
            "qwen3-8-max", "qwen3-8-flash", "qwen3-8-2-4t-a95b", "qwen3-8-27b",
            "qwen3-7-", "qwen3-6-", "qwen3-5-",
            "qwen3-max", "qwen-max", "qwen-plus", "qwen-flash", "qwen-turbo",
            "qwq",
        ]
    )

    /// 新加坡：千问只到 Qwen3-Max，没有 qwen-max/plus/flash/turbo；第三方只剩 v4 系列和 v3.2。
    private static let singapore = Entry(
        names: [
            "deepseek-v4-pro", "deepseek-v4-pro-0813", "deepseek-v4-flash", "deepseek-v4-flash-0731",
            "deepseek-v3-2",
        ],
        prefixes: [
            "qwen3-8-max", "qwen3-8-flash", "qwen3-8-2-4t-a95b", "qwen3-8-27b",
            "qwen3-7-", "qwen3-6-", "qwen3-5-",
            "qwen3-max",
        ]
    )

    /// 全球：美国（弗吉尼亚）、中国香港、日本（东京）、德国（法兰克福）。
    /// 只有 Qwen3.8 的三个模型（qwen3.8-omni-flash 因为要 agent 策略被排除），第三方模型一个都没有。
    private static let global = Entry(
        prefixes: ["qwen3-8-max", "qwen3-8-flash"]
    )
}
