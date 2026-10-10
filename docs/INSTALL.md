# Chatbot 安装指引

## 系统要求

- macOS 26 或以上。
- Apple Silicon Mac（M 系列芯片）；v1.1.0 安装包不支持 Intel Mac。
- 自己的模型服务 API key，以及该服务的可用额度和网络连接。应用不附带 API key，模型调用费用由服务商收取。

在 **Apple menu › About This Mac** 查看系统版本和芯片。以下菜单名使用英文，界面语言会跟随系统。

## 下载和安装

1. 打开 [v1.1.0 Release](https://github.com/linem7/Chatbot/releases/tag/v1.1.0)，在 **Assets** 下载 `Chatbot-1.1.0-macOS-arm64.zip`。也可以[直接下载安装包](https://github.com/linem7/Chatbot/releases/download/v1.1.0/Chatbot-1.1.0-macOS-arm64.zip)。**Source code** 是开发者用的源码，不是安装包。
2. 双击 ZIP 解压，将 `Chatbot.app` 拖进 **Applications**。
3. 从 **Applications** 打开 Chatbot。
4. 应用使用自签名证书，没有经过 Apple 公证。如果首次打开提示 Apple 无法验证开发者或检查应用，在确认文件来自上述 Release 后，进入 **System Settings › Privacy & Security**，向下滚动，点击 **Open Anyway**，然后按提示确认 **Open**。需要先尝试打开一次，系统才会显示该入口。详见 [Apple 的打开说明](https://support.apple.com/en-us/102445)。

无需安装 Xcode、运行终端命令或导入开发者的签名证书。

## 第一次使用

1. 首次启动会打开 **Settings › Connections**，默认选好 DeepSeek 模板。填入自己的 API key，点 **Save**，应用会拉取模型列表。
2. 使用其他服务时，点击 Connections 页的 **+**，选择相应模板。内置 DeepSeek、Anthropic、Gemini、OpenAI、OpenRouter、Alibaba Cloud Model Studio，以及可填写地址和协议的 **Custom**。
3. 在 **Settings › General › Default Model** 选择默认模型。
4. 按 **Option + Space** 唤起 Quick Panel，输入问题并发送。可以粘贴截图，或通过 **+**、拖拽加入图片和文件。

Chatbot 平时在菜单栏里；只有打开 Settings 或主窗口时，才临时出现在 Dock 和 ⌘Tab。首次启动默认开启 **Launch at Login**，可在 **Settings › General** 关闭。系统可能显示 **Background Items Added** 通知。

## 快捷键和权限

- 默认 **Option + Space** 不需要 Accessibility 或 Screen Recording 权限。如果和其他应用冲突，在 **Settings › General › Combination** 换一个组合。
- 想用连按两次 ⌘，将 **Hotkey** 改为 **Press ⌘ twice**，并在 **System Settings › Privacy & Security › Accessibility** 允许 Chatbot。授权后回到 Chatbot；授权前仍可使用原来的组合键。
- 点击面板顶栏的图钉可以固定窗口。固定后，Esc、快捷键和失焦都不会收起面板，需要先取消固定。拖动顶栏空白处可以移动面板。

## 升级

应用不自动检查更新。到 [Releases](https://github.com/linem7/Chatbot/releases) 下载新版本，先从菜单栏选择 **Quit Chatbot**，再将解压后的 `Chatbot.app` 拖进 **Applications**，按 Finder 提示替换旧版本，然后重新打开。

替换应用会保留设置、API key 和本地历史，不要执行清理用户数据的卸载命令。API key 存在 macOS Keychain 中；如果从自行编译版切换到 Release 后出现 Keychain 授权，确认是 Chatbot 后允许访问。应用本身会自动清理超过 30 天没有新消息的对话。

## 卸载

在 **Settings › General** 关闭 **Launch at Login**，从菜单栏选择 **Quit Chatbot**，然后将 **Applications** 中的 `Chatbot.app` 移到废纸篓。这样会保留本地数据，方便重新安装。

如需连同历史、设置和 Keychain 中的 API key 一起删除，请参阅 [README 的完整卸载步骤](../README.md#卸载)；那些命令会永久删除用户数据。

## 常见问题

- **打开后看不到窗口**：查看屏幕顶部菜单栏，或按 **Option + Space**。
- **快捷键没反应**：检查是否与其他应用冲突、是否选择了另一种 Hotkey；使用 ⌘ 双击时检查 Accessibility 授权。
- **模型列表加载失败或回答报错**：检查服务商、API key、API 额度、网络和 Custom 的地址。API 服务的 key 与网页聊天账户订阅不是同一项配置。
- **某个模型不能看图或联网**：能力取决于模型和服务商；不是所有模型都支持这些功能。
- **系统不显示 Open Anyway**：先从 Applications 尝试打开一次，再查看 Privacy & Security；受组织管理的 Mac 可能限制此操作，需要联系管理员。
- **遇到其他问题**：到 [GitHub Issues](https://github.com/linem7/Chatbot/issues) 描述 macOS 版本、应用版本和复现步骤。截图或错误信息中请隐去 API key。
