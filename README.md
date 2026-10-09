# Chatbot

一个 macOS 上的 AI 聊天助手，目标是**随手就能叫出来**：按一个快捷键唤起，问完就走，不打断手头的事。

## 为什么做这个

现在用 AI 的流程太碎了：切到浏览器 → 打开网页 → 粘贴内容 → 等回答 → 再切回来。屏幕上的东西（报错信息、图表、一段代码、一个弹窗）还得手动描述，或者截图再上传。

这个 app 想去掉的就是这段摩擦：**看到什么就直接问什么**。

## v1.0 功能范围

完整规格见 [docs/SPEC.md](docs/SPEC.md)。

### 1. 快速调用
- 按 **option+space**（可以改）从任何 app 里唤起 Quick Panel，它出现在当前屏幕的偏上居中位置。
- 失焦、按 Esc 或再按一次快捷键就收起。回答在后台继续生成，菜单栏图标会提示状态。
- 10 分钟内再次唤起会接着上一段对话，超过 10 分钟就自动新开。
- 常驻菜单栏，不占 Dock，不抢焦点，也不弹通知。

### 2. 图片和文件
- 把用任意截图工具截的图**直接粘贴**进来提问。也可以用「+」或拖拽加入图片、PDF、文本和代码文件。
- 典型用法：
  - 粘贴一段报错的截图 →「这是什么问题，怎么修」
  - 粘贴一张图表 →「这张图说明了什么」
  - 粘贴一段外文 →「翻译并解释」

### 3. 联网问答
- 使用支持原生搜索的模型（Claude、Gemini）时，模型会自己决定是否搜索网页，回答里带来源角标和链接。
- 拿不准的答案应该明确说「没查到」，或者给出链接让人自己核对，而不是编一个。
- DeepSeek 的 API 没有原生搜索，所以用 DeepSeek 时不联网。

### 4. 多模型与本地历史
- 支持三种 API 协议：OpenAI 兼容（包括 DeepSeek）、Anthropic、Google Gemini。用户自带 API key，key 存在系统钥匙串里。
- 对话保存在本地，可以在主窗口里全文搜索。最后一条消息在 30 天前的对话会被自动删除。

## v1.0 明确不做

划清边界，避免一上来铺得太大：

- 不做内置截图：用系统或其他截图工具截好后粘贴进来
- 不接外部搜索服务
- 不开模型「思考」，也不展示推理过程：这是一个快速解决问题的工具
- 不做对话导出、团队协作、分享、iCloud 同步
- 不做插件系统或自定义工作流
- 不做移动端，不跨平台，不上 Mac App Store；v1 也不对外发布，不做更新检查

## 技术栈

- 原生 **Swift 6 + SwiftUI**（系统集成用 AppKit），最低支持 **macOS 26 Tahoe**
- 用 XcodeGen 生成工程；核心逻辑放在本地 SPM 包 `ChatbotCore` 里，可以单独测试
- 依赖：KeyboardShortcuts（全局快捷键）、GRDB（本地历史）、MarkdownUI（回答渲染）、HighlighterSwift（代码高亮）
- 三家模型 API 都是基于 URLSession 自己实现的流式客户端，不使用任何 LLM SDK

架构细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，关键决策见 [docs/adr/](docs/adr/)。

## AI 后端

日常主要用 **DeepSeek**（OpenAI 兼容协议），同时支持 Anthropic 和 Gemini。所有请求都关闭思考模式，优先保证回答速度。是否支持图片、是否能联网，以各家模型列表接口返回的能力为准。

## 安装

v1 只自用，不对外发布：在本机构建后安装。app 用一张固定的自签名证书签名，没有经过 Apple 公证（[ADR-0005](docs/adr/0005-self-signed-certificate-no-notarization.md)）。首次启动会打开设置，选择 DeepSeek 模板，粘贴 API key 即可开始使用。

### 准备

- macOS 26 和 Xcode 26
- XcodeGen：`brew install xcodegen`

### 创建自签名证书（只需做一次）

API key 存在钥匙串里，钥匙串按签名身份判断访问权限。所以每次构建都要用**同一张**证书签名，否则重新构建后读 key 时会反复弹窗。

1. 打开「钥匙串访问」，菜单选「钥匙串访问 → 证书助理 → 创建证书…」。
2. 名称填 `Chatbot Self-Signed`（必须和 `project.yml` 里的 `CODE_SIGN_IDENTITY` 一致），身份类型选「自签名根证书」，证书类型选「代码签名」。
3. 勾选「让我覆盖这些默认值」，有效期填 `7300`（20 年），其余一路默认，钥匙串选「登录」。
4. 在「登录」钥匙串里双击这张证书，展开「信任」，把「代码签名」设为「始终信任」，关闭窗口并输入密码确认。
5. 在终端确认它能用于签名：

   ```sh
   security find-identity -v -p codesigning
   ```

   输出里应该有一行 `"Chatbot Self-Signed"`。
6. **备份**：在钥匙串里右键这张证书 →「导出」，存成 `.p12` 并设密码，放到安全的地方。私钥丢了就只能换证书，换证书后第一次读 key 会再弹一次钥匙串授权。

### 构建和安装

在仓库里运行：

```sh
./scripts/install.sh
```

脚本会依次：检查 Xcode、XcodeGen 和签名证书 → 生成工程 → 构建 Release → 退出正在运行的 Chatbot → 删掉旧的 `/Applications/Chatbot.app` 并装上新的 → 校验签名 → 启动。任何一步失败都会停下来，并说明原因。第一次构建要下载依赖，会慢一些。

装好之后，Chatbot 只出现在菜单栏，不出现在 Dock。第一次启动时：

- 会自动打开设置的 Connection 页，并选好 DeepSeek 模板。粘贴 API key 后点「保存」，app 会拉取 Model 列表，这一步同时就是连接测试。
- 会打开「开机时启动」。macOS 会弹一条「已添加后台项目」的系统通知，这是系统行为，不是 app 发的。
- 如果 option+space 已经被系统快捷键占用，会弹窗提示。

本机构建的 app 没有隔离标记（quarantine），不会被 Gatekeeper 拦下。以后对外分发时，下载的人第一次打开需要到「系统设置 › 隐私与安全性」里点「仍要打开」（ADR-0005）。

手动构建的步骤（和脚本做的事一样）：

```sh
xcodegen generate                    # 由 project.yml 生成 Chatbot.xcodeproj
xcodebuild -project Chatbot.xcodeproj -scheme Chatbot -configuration Release \
  -derivedDataPath build build
rm -rf /Applications/Chatbot.app      # 先删掉旧版本，避免旧 bundle 里多出的文件让签名失效
ditto build/Build/Products/Release/Chatbot.app /Applications/Chatbot.app
```

也可以 `open Chatbot.xcodeproj` 后在 Xcode 里构建运行。改了 `project.yml` 或增删了源文件后，要重新执行 `xcodegen generate`。

### 升级

拉取最新代码后，再运行一次 `./scripts/install.sh`。证书没变，所以钥匙串不会再要求授权。如果还是弹了，选「始终允许」，之后就不会再弹。设置、历史和 key 都会保留。

### 卸载

先在设置的「通用」页关掉「开机时启动」，从菜单栏退出 Chatbot，再执行：

```sh
rm -rf /Applications/Chatbot.app
rm -rf ~/Library/Application\ Support/com.linem7.Chatbot     # 历史和附件副本
defaults delete com.linem7.Chatbot                            # 设置
rm -rf ~/Library/Caches/com.linem7.Chatbot                    # 缓存
rm -rf ~/Library/HTTPStorages/com.linem7.Chatbot              # 网络请求的存储
# 钥匙串里的 API key：每个 Connection 一条，删到没有为止
while security delete-generic-password -s com.linem7.Chatbot.apikey >/dev/null 2>&1; do :; done
```

自签名证书如果不再需要，可以在「钥匙串访问」里删掉。

### 常见问题

- **构建时报找不到签名身份「Chatbot Self-Signed」**：证书没有建好，或者没有设成「始终信任」。按上面「创建自签名证书」检查，`security find-identity -v -p codesigning` 里要能看到它。
- **每次重新安装后，钥匙串都要求授权**：说明签名身份变了，例如重建了证书，或者没用脚本、而是用 Xcode 的「Sign to Run Locally」构建的。选「始终允许」一次即可；以后一直用同一张证书构建。
- **按 option+space 没反应**：可能和系统快捷键冲突（启动时会提示），也可能和 ChatGPT 等别的 app 冲突（检测不到）。在设置的「通用」页换一个 Hotkey。
- **运行脚本时弹出「“终端”想要控制“Chatbot”」**：这是 macOS 的自动化授权，脚本要用它退出正在运行的旧版本。点「允许」即可。如果点了「不允许」，脚本会停下来，提示你从菜单栏手动退出 Chatbot，退出后再运行一次就行；以后想改，可以到「系统设置 › 隐私与安全性 › 自动化」里调整。

只跑核心逻辑的测试：

```sh
swift test --package-path Packages/ChatbotCore
```

CI（`.github/workflows/ci.yml`）在 push 到 main 和 PR 时执行同样的生成、构建和测试，但不签名。

## 项目状态

v1 的功能都已经实现（规格见 [docs/SPEC.md](docs/SPEC.md)，实现见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)），正在 Mac 上逐项验证，见 #39。

## Roadmap

- [x] 技术选型与 v1 规格
- [x] 工程骨架与 CI
- [x] 最小可用版本：快捷键唤起 + Quick Panel + DeepSeek 流式对话
- [x] 本地历史与主窗口
- [x] 图片和文件附件
- [x] 设置与首次启动引导
- [x] Anthropic、Gemini 接入与联网搜索
- [x] 错误展示与本机安装脚本
- [ ] v1.0 完成（自用）：在 Mac 上通过 #39 的验证清单
