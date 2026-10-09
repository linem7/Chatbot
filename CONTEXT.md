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

**Platform**:
提供模型 API 的平台，按 Connection 的 base URL 的 host 识别，目前认识 DeepSeek 官方、OpenRouter、阿里云百炼。同一个 Provider 下，不同 Platform 需要不同的非标准字段（例如关闭思考的写法）。自己部署的服务和不认识的中转不属于任何 Platform。
_Avoid_: 中转（中转是用户自建或第三方的转发服务，不一定是某个 Platform）、Provider（Provider 是协议族）

**Model**:
某个 Connection 下可调用的一个具体模型，用 API 中的模型 ID 标识，例如 `deepseek-flash`。界面上显示为「Connection / Model」。

**Default Model**:
用户在设置里指定的一个 Model。新建 Conversation 时默认使用它。

**Model Capabilities**:
一个 Model 能接受什么输入、能做什么：是否支持图片、tool calling、Web Search。决定粘贴图片和搜索开关是否可用。
_Avoid_: Provider 能力（能力属于 Model，不属于 Provider）

### 界面

**Hotkey**:
从任何 app 里唤起 Quick Panel 的全局快捷键，默认是 option+space，用户可以改。
_Avoid_: 快捷键（不加限定时容易和面板内的快捷键混淆）

**Quick Panel**:
按 Hotkey 唤起的浮动面板，不抢走前台 app 的激活状态，用来快速提问，问完就收起；也可以固定住，固定后一直保持在最前。
_Avoid_: 浮窗、弹窗、Popup

**Pinned**:
Quick Panel 的固定状态，由顶栏的图钉按钮开关。固定时失焦、Esc、Hotkey 都不再收起面板，切到别的 app 也保持在最前。只在本次运行内有效，不写进设置。
_Avoid_: 置顶、钉住、Always on top（说「固定」或 Pinned）

**Main Window**:
普通的 app 窗口，用来浏览历史 Conversation 和修改设置。
_Avoid_: 主界面

### 对话

**Conversation**:
一段可以持续多轮的对话，本地保存。每个 Conversation 在创建时选定一个 Model，之后不再更换；想换 Model 就开新的 Conversation。
_Avoid_: 会话、Chat、Thread

**Message**:
Conversation 里的一条消息，要么来自用户，要么来自模型（assistant）。一条 assistant Message 就是一次 Turn 的完整回答，可以包含多次工具调用和工具结果，最后才是正文。
_Avoid_: tool 消息（工具调用和结果是 assistant Message 的一部分，不单独成为 Message）

**Attachment**:
附在用户 Message 上的一个文件，类型是图片、PDF 或文本文件。可以通过「+」、粘贴或拖拽加入，三种方式按同一套规则处理。PDF 以抽取出的文本形式发给模型。
_Avoid_: 附件文件、Upload、截图（v1 没有内置截图，截图只是用户粘贴进来的一张图片）

**Web Search**:
模型在回答过程中自己发起的联网搜索，由 Provider 或 Platform 在服务端执行（Anthropic、Gemini 的原生搜索，OpenRouter、阿里云百炼自带的搜索），app 不调用任何外部搜索服务。只有 Model Capabilities 里支持 Web Search 的 Model 才能用。
_Avoid_: 联网问答、搜索工具、Tavily

**Citation**:
回答正文中某段内容所依据的一条网页来源，包括标题和 URL。在正文里显示为角标，并汇总在回答末尾。
_Avoid_: 引用链接、Source

**Turn**:
从用户发出一条 Message 开始，到模型给出最终回答为止的整个过程。中间可能包含多次模型调用和工具调用。

**Interrupted**:
Message 的一种状态：Turn 被用户取消，已经收到的部分内容保留了下来。用户取消不算错误。
_Avoid_: 失败、Cancelled Message

**Failed**:
Message 的一种状态：Turn 中途出错，已经收到的部分内容保留了下来，并记下错误类别（SPEC §7）。
_Avoid_: Interrupted（出错不是中断）、Error Message

**Retry**:
当 Conversation 的最后一条 assistant Message 是 Interrupted 或 Failed 时，用同一条用户 Message 重新执行一次 Turn，新的回答替换旧的。只能对最后一条使用。
_Avoid_: 重新生成、Regenerate
