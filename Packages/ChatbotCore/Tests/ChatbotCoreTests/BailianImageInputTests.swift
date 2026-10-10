@testable import ChatbotCore
import Foundation
import Testing

/// 百炼的图片能力按模型名查 `BailianModelTable`（#70）。
/// 模型名和能力来自各模型详情页的输入模态，见 `docs/research/bailian-vision-models.md`。
struct BailianImageInputTests {
    /// 用户的 Token Plan Connection（北京地域）
    private func connection(_ baseURL: String = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", models: [ModelInfo] = []) -> Connection {
        Connection(name: "bailian", provider: .openAICompatible, baseURL: URL(string: baseURL)!, models: models)
    }

    @Test(arguments: [
        // Token Plan 控制台标了「视觉理解」的
        "qwen3.8-max", "qwen3.8-flash", "qwen3.7-plus", "qwen3.6-flash", "deepseek-v4.1-flash",
        // 快照和同系列的其他型号
        "qwen3.8-max-0902", "qwen3.7-plus-2026-05-26", "qwen3.7-max-2026-06-08", "qwen3.8-27b",
        "qwen3.6-plus", "qwen3.5-plus-2026-02-15", "qwen3.5-flash", "qwen3.5-397b-a17b",
        "qwen3.8-omni-flash", "qwen3.5-omni-plus",
        "qwen3-vl-plus", "qwen-vl-max", "qvq-max", "qwen-omni-turbo",
        "kimi-k3", "kimi/kimi-k3", "kimi-k2.5", "kimi/kimi-k2.7-code-highspeed",
        "ZHIPU/GLM-5.3-Flash", "ZHIPU/GLM-5.3-FlashX", "MiniMax/MiniMax-M3", "stepfun/step-3.7-flash",
    ])
    func modelsTheDocsSayAcceptImages(modelID: String) {
        #expect(BailianModelTable.acceptsImages(modelID))
    }

    @Test(arguments: [
        // Token Plan 控制台没标「视觉理解」的
        "qwen3.7-max", "auto",
        // 和能看图的型号同系列、但只收文本的
        "qwen3.7-max-2026-05-20", "qwen3.7-max-preview", "qwen3.8-2.4t-a95b", "qwen3.6-max-preview",
        "qwen3-max", "qwen-max", "qwen-plus", "qwen-flash", "qwen-turbo", "qwq-plus",
        "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v3.2",
        "glm-5.3", "glm-5.2", "kimi-k2-thinking", "Moonshot-Kimi-K2-Instruct", "MiniMax-M2.7",
        // 实时和向量模型不走 Chat Completions
        "qwen3.8-omni-flash-realtime", "qwen3-vl-embedding",
    ])
    func textOnlyModelsDoNotAcceptImages(modelID: String) {
        #expect(!BailianModelTable.acceptsImages(modelID))
    }

    @Test func savedConnectionWithConservativeCapabilitiesStillAcceptsImages() {
        // #70 之前拉到的百炼 Model 都是保守默认，不用重新拉取
        let saved = connection(models: [
            ModelInfo(id: "qwen3.8-max", capabilities: .conservative),
            ModelInfo(id: "qwen3.7-max", capabilities: .conservative),
        ])
        #expect(saved.capabilities(ofModel: "qwen3.8-max").imageInput)
        #expect(!saved.capabilities(ofModel: "qwen3.7-max").imageInput)
        // 手动加的、不在缓存里的 Model 也一样
        #expect(saved.capabilities(ofModel: "qwen3.7-plus").imageInput)
    }

    @Test func otherPlatformsDoNotUseTheBailianTable() {
        let unknown = connection("https://relay.example.com/v1", models: [ModelInfo(id: "qwen3.8-max", capabilities: .conservative)])
        #expect(!unknown.capabilities(ofModel: "qwen3.8-max").imageInput)
    }

    @Test func bailianModelListWithoutModalitiesFallsBackToTheTable() async throws {
        // 构造的响应：标准 OpenAI `/models` 的形状，没有 input_modalities（百炼没有文档说会返回这个字段）
        let body = """
            {"object": "list", "data": [{"id": "qwen3.8-max", "object": "model", "owned_by": "system"}, \
            {"id": "qwen3.7-max", "object": "model", "owned_by": "system"}]}
            """
        let models = try await OpenAICompatibleAdapter(transport: StubTransport(body: body)).listModels(connection(), apiKey: "sk-test")
        #expect(models.first { $0.id == "qwen3.8-max" }?.capabilities.imageInput == true)
        #expect(models.first { $0.id == "qwen3.7-max" }?.capabilities.imageInput == false)
    }

    @Test func reportedModalitiesWinOverTheTable() async throws {
        // 构造的响应：接口报告了 input_modalities 时以接口为准
        let body = "{\"data\": [{\"id\": \"qwen3.7-max\", \"input_modalities\": [\"text\", \"image\"]}]}"
        let models = try await OpenAICompatibleAdapter(transport: StubTransport(body: body)).listModels(connection(), apiKey: "sk-test")
        #expect(models.first?.capabilities.imageInput == true)
    }
}
