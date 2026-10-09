// 调试用的命令行：用真实的 key 拉一次 Model 列表，再流式跑一次 Turn。
//
// 用法（在 Mac 上，仓库根目录）：
//   DEEPSEEK_API_KEY=sk-... swift run --package-path Packages/ChatbotCore chatbot-debug "用一句话介绍你自己"
//   ANTHROPIC_API_KEY=sk-ant-... swift run --package-path Packages/ChatbotCore chatbot-debug "今天东京天气怎样"
//   GEMINI_API_KEY=AIza... swift run --package-path Packages/ChatbotCore chatbot-debug "今天东京天气怎样"
// 设了多个 key 时按 Anthropic、Gemini、DeepSeek 的顺序选。可选环境变量 DEEPSEEK_MODEL / ANTHROPIC_MODEL / GEMINI_MODEL
// 指定 Model，默认 deepseek-flash / claude-opus-5-5 / gemini-2.5-flash。Model 支持时会开 Web Search，回答末尾列出 Citation。
// 流式输出期间按 Ctrl-C 会直接结束进程。

import ChatbotCore
import Foundation

/// 不经过 print 的缓冲，流式片段到了就立刻显示。
func write(_ text: some StringProtocol) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
var connection: Connection
let apiKey: String
let modelID: String
if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty {
    connection = .anthropic()
    apiKey = key
    modelID = environment["ANTHROPIC_MODEL"] ?? "claude-opus-5-5"
} else if let key = environment["GEMINI_API_KEY"], !key.isEmpty {
    connection = .gemini()
    apiKey = key
    modelID = environment["GEMINI_MODEL"] ?? "gemini-2.5-flash"
} else if let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty {
    connection = .deepSeek()
    apiKey = key
    modelID = environment["DEEPSEEK_MODEL"] ?? "deepseek-flash"
} else {
    fail("请先设置环境变量 DEEPSEEK_API_KEY、ANTHROPIC_API_KEY 或 GEMINI_API_KEY")
}
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let question = prompt.isEmpty ? "用一句话介绍你自己。" : prompt
let adapter = connection.provider.makeAdapter()

write("== GET /models\n")
do {
    connection.models = try await adapter.listModels(connection, apiKey: apiKey)
    for model in connection.models {
        let capabilities = model.capabilities
        write("  \(model.id)  \(model.displayName ?? "")  图片:\(capabilities.imageInput) tools:\(capabilities.toolCalling) 搜索:\(capabilities.webSearch)\n")
    }
} catch {
    fail("拉取 Model 列表失败：\(error)")
}

write("== \(modelID)：\(question)\n")
let store = InMemoryMessageStore()
let runner = TurnRunner(store: store, makeAdapter: { _ in adapter })
let handle = runner.run(TurnInput(
    conversation: Conversation(connectionID: connection.id, modelID: modelID),
    connection: connection,
    apiKey: apiKey,
    systemPrompt: "",
    history: [],
    userMessage: .user(question)
))

var printed = ""
for await update in handle.updates {
    switch update {
    case .updated(let message):
        let text = message.markdownText
        write(text.dropFirst(printed.count))
        printed = text
    case .finished(let message):
        write(message.markdownText.dropFirst(printed.count) + "\n")
        for block in message.content {
            switch block.kind {
            case .webSearch(let query):
                write("== 搜索：\(query)\n")
            case .text(_, let citations):
                for span in citations { write("== 引用：\(span.citation.title) \(span.citation.url)\n") }
            default:
                break
            }
        }
        write("== 状态：\(message.status)\n")
        if case .failed = message.status { exit(1) }
    }
}
