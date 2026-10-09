# Chatbot

一个 macOS 菜单栏常驻的 AI 聊天助手：用快捷键唤起，直接对屏幕上的内容提问，问完就走。

## Language

### 模型接入

**Provider**:
一种模型 API 协议族，目前固定三种：OpenAI 兼容、Anthropic Messages、Google Gemini。用户不能新增 Provider。
_Avoid_: 服务商、后端、API 类型

**Connection**:
用户配置的一条模型接入，包括名称、所属 Provider、base URL、API key 和可用的 Model 列表。例如「DeepSeek」是一条走 OpenAI 兼容 Provider 的 Connection。
_Avoid_: 配置实例、Service、Account、Endpoint

**Model**:
某个 Connection 下可调用的一个具体模型，用 API 中的模型 ID 标识，例如 `deepseek-flash`。界面上显示为「Connection / Model」。

**Default Model**:
用户在设置里指定的一个 Model。新建 Conversation 时默认使用它。

**Model Capabilities**:
一个 Model 能接受什么输入、能做什么：是否支持图片、PDF、tool calling。决定截图和上传入口是否可用。
_Avoid_: Provider 能力（能力属于 Model，不属于 Provider）

### 对话

**Conversation**:
一段可以持续多轮的对话，本地保存。每个 Conversation 在创建时选定一个 Model，之后不再更换；想换 Model 就开新的 Conversation。
_Avoid_: 会话、Chat、Thread

**Message**:
Conversation 里的一条消息，要么来自用户，要么来自模型（assistant）。一条 assistant Message 就是一次 Turn 的完整回答，可以包含多次工具调用和工具结果，最后才是正文。
_Avoid_: tool 消息（工具调用和结果是 assistant Message 的一部分，不单独成为 Message）

**Turn**:
从用户发出一条 Message 开始，到模型给出最终回答为止的整个过程。中间可能包含多次模型调用和工具调用。

**Interrupted**:
Message 的一种状态：Turn 被用户取消或中途出错，但已经收到的部分内容保留了下来。用户取消不算错误。
_Avoid_: 失败、Cancelled Message

**Retry**:
当 Conversation 的最后一条 assistant Message 是 Interrupted 或出错时，用同一条用户 Message 重新执行一次 Turn，新的回答替换旧的。只能对最后一条使用。
_Avoid_: 重新生成、Regenerate
