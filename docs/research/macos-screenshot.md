# 研究：macOS Screenshot 技术方案（ScreenCaptureKit vs `screencapture` CLI）

- 对应 issue：[#3 研究：macOS 截图技术方案](https://github.com/linem7/Chatbot/issues/3)（Part of #1）
- 日期：2026-10-08
- 前提：原生 Swift/SwiftUI、macOS 14+、App Store 外分发、**不启用 App Sandbox**（见 README）
- 术语按 `CONTEXT.md`：**Screenshot** = app 从屏幕捕获、挂到 Message 上的 Attachment，来源有「全屏 / 单窗口 / 自由框选」三种；**Quick Panel** / **Hotkey** 的实现见姊妹文档 [hotkey-and-panel.md](https://github.com/linem7/Chatbot/blob/research/hotkey-and-panel/docs/research/hotkey-and-panel.md)，本文不重复。

## TL;DR

1. **两条路都绕不开 Screen Recording（TCC）权限**。ScreenCaptureKit 由 app 自己持有权限；`screencapture` 是 Apple 的命令行工具，但 TCC 把子进程的请求记在"responsible code"（启动它的 app）头上，所以从 app 里 `Process` 调用时，**要授权的仍然是我们的 app**。权限成本上两者没有差别。
2. **macOS 15 的周期性复核弹窗（"…is requesting to bypass the system private window picker…" / "Allow For One Month"）同样落在 ScreenCaptureKit 头上**，不只是旧 CG API：Apple DTS 用 `SCShareableContent` + `SCScreenshotManager` 的最小代码复现了它。DTS 给出的规避办法只有两条：`SCContentSharingPicker`，或者 Persistent Content Capture entitlement（仅限 VNC/屏幕共享类产品，需要向 Apple 申请）。两条我们都用不上，所以 **v1 要按"每月会弹一次"来设计**。
3. **`SCContentSharingPicker` 不能自由框选**：它的模式只有 single/multiple window、single/multiple application、single display 这五种，没有任意矩形。因此 ScreenCaptureKit 路线必须**自己做框选 overlay 和窗口高亮 UI**，跨多显示器的坐标换算和 Retina 缩放也都要自己处理。
4. **`screencapture -i` 白送系统原生的框选 / 窗口选择 UI**（空格切换两种模式、Esc 取消、多显示器、Retina 都由系统处理），代码量最小；代价是 CLI 文档很薄（man page 自己写着 "not very well documented"），无法定制 UI，取消要靠"输出文件不存在"来判断，而且 Apple DTS 明确把 ScreenCaptureKit 当作未来方向。
5. **v1 建议**：三种 Screenshot 全部走 `screencapture` CLI，封装在一个 `ScreenshotCapturer` 接口后面；调用前用 `CGPreflightScreenCaptureAccess()` 检查权限，没有就走 `CGRequestScreenCaptureAccess()` 加"去 System Settings 打开"的引导流程。以后需要冻结帧、标注、自定义选区 UI 时，再在同一接口后换成 ScreenCaptureKit 实现。§8 末尾列出了上线前必须在真机上验证的几项。

---

## 1. 权限：Screen Recording（TCC）

### 1.1 ScreenCaptureKit

- Apple 框架文档原文："Request screen recording permission from the person before capturing content. In the Info pane of the Xcode target editor, add a `NSScreenCaptureUsageDescription` key…"（[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)）
- 首次调用时系统弹授权；**授权后需要重启 app 才能捕获**。官方 sample 原文："The first time you run this sample, the system prompts you to grant the app Screen Recording permission. After you grant permission, you need to restart the app to enable capture."（[Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)）
- 被拒时的行为：ScreenCaptureKit 返回 `SCStreamError.Code.userDeclined`，文档描述为 "the user didn't grant Screen Recording permission to your app"（[userDeclined](https://developer.apple.com/documentation/screencapturekit/scstreamerror/code/userdeclined)）。错误是带类型的，可以直接据此给用户提示。

### 1.2 `screencapture` CLI

- Apple 没有专门说明 `screencapture` 的权限归属，但 DTS（Quinn "The Eskimo!"）对 TCC 的通用解释是：隐私检查针对的是 **responsible code**。子进程触发提示时，系统要把外层 app 认定为 responsible code，用的是一套启发式规则，"works well in most cases"（[On File System Permissions](https://developer.apple.com/forums/thread/678819)）。他还说过 TCC 会找"用户认识的最近的祖先进程"，而这个算法 "is complex, changes over time"（[thread 751802](https://developer.apple.com/forums/thread/751802)）；从 Terminal 里运行工具时，Terminal 就是 responsible code（[thread 760964](https://developer.apple.com/forums/thread/760964)）。
- 实际观察（开发者论坛，非 Apple 结论）：
  - 有人从 Chrome native-messaging helper 里跑 `screencapture`，授权后仍反复要权限；改成用 shell 脚本包一层以后，系统转而对 `sh` 发起授权（[thread 668929](https://developer.apple.com/forums/thread/668929)）。这说明权限确实记在"上游进程"头上。
  - 在 macOS 26.1 上，从别的 app 内启动的可执行文件，Screen Recording 列表里显示的是父 app（[thread 807898](https://developer.apple.com/forums/thread/807898)）。
  - 在 macOS 15 beta 上，从 app 的 XPC service 或 Terminal 里跑 `screencapture -xio` 会反复弹 "Continue To Allow"，beta 5 修复。DTS 对只依赖 `screencapture` 的方案表态："I don't have a great path forward for you"，并说 "the path forward here is ScreenCaptureKit"（[thread 760112](https://developer.apple.com/forums/thread/760112)）。
- 没有权限时的表现：很多厂商的支持文档都描述了同一个现象，截到的图里只有桌面壁纸，其他 app 的内容被系统挡掉（例如 [WebWork 支持页](https://support.webwork-tracker.com/fix-screenshot-issues-on-mac)，二手）。**这是静默失败，CLI 不会报错**，所以调用前必须先做 preflight（见 1.3）。`screencapture -i` 在无权限时具体怎么表现（只给壁纸，还是触发授权弹窗），Apple 没有文档，需要实测（§8 验证清单）。

### 1.3 检查与申请：`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`

- 两个函数都是 macOS 10.15+，返回 `Bool`（[CGPreflightScreenCaptureAccess()](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess())、[CGRequestScreenCaptureAccess()](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess())）。Apple 文档页没有正文说明，下面的行为来自论坛 [thread 732726](https://developer.apple.com/forums/thread/732726)：
  - `CGRequestScreenCaptureAccess()` 在没有权限时弹出系统对话框，引导用户去 System Settings；函数**立即返回**，不会等用户操作。
  - 用户在 Settings 里打开开关以后，**同一进程里的 `CGPreflightScreenCaptureAccess()` 仍会返回 `false`**，楼主观察到这一点，DTS 也确认 "That's right"。DTS 的解释是："a single user-visible privilege can cover multiple APIs … the system can't tell whether your app will or won't see the new privilege immediately."
  - 系统对话框原文提示 app "may not be able to record the contents of your screen until it is quit"。
- 设计含义：授权流程要做成"检测到未授权 → 调 Request → 弹出我们自己的引导页（深链到 System Settings 的 Screen & System Audio Recording）→ 提示用户**重启 app**"。不要指望授权后能在进程内自动恢复。用户也可以手动在 System Settings › Privacy & Security › Screen & System Audio Recording 里给 app 开关权限（[Apple 支持文档](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)）。
- 签名：DTS 强调必须用**稳定的签名身份**，ad hoc 签名 "prevents TCC from doing its job"，否则每次重新构建都会被当成新 app（[thread 760112](https://developer.apple.com/forums/thread/760112)）。开发期也要注意这一点，可以用 `tccutil reset ScreenCapture <bundle-id>` 重置授权状态。

## 2. macOS 15 的周期性复核弹窗

- **Apple 一手说明**：
  - macOS 15 release notes（ScreenCaptureKit › Deprecations）原文："Applications utilizing deprecated APIs for content capture such as `CGDisplayStream` & `CGWindowListCreateImage` can trigger system alerts indicating they might be able to collect detailed information about the user. Developers need to migrate to `ScreenCaptureKit` and `SCContentSharingPicker`. (120910350)"（[macOS 15 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes)）
  - macOS 15.1 release notes："Users will see fewer dialogs if they regularly use apps in which they have already acknowledged and accepted the risks. (133431080)"；MDM 新增 `forceBypassScreenCaptureAlert`，允许受管设备关掉这个提示（[macOS 15.1 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-15_1-release-notes)；[Apple Deployment：Restrictions for Mac](https://support.apple.com/guide/deployment/restrictions-for-mac-depba790e53/web)）。这只对受管设备有用，我们的普通用户用不上。
- **它是否也落在 ScreenCaptureKit 上？是。** DTS 在 [thread 765103](https://developer.apple.com/forums/thread/765103) 里用 `SCShareableContent.current` + `SCScreenshotManager.captureImage` 的最小 app 在 macOS 15.0 上复现：第一次是常规授权提示，**第二次点击后**弹出：
  > "SomeApp" is requesting to bypass the system private window picker and directly access your screen and audio. …（按钮：Allow For One Month / Open System Settings）

  DTS 原话："AFAIK there are two ways to avoid that alert: Via the Persistent Content Capture (`com.apple.developer.persistent-content-capture`) entitlement … specifically intended for screen sharing products. Present the system picker UI, `SCContentSharingPicker`."
- Persistent Content Capture entitlement 的文档只写给 VNC app，并且要提交申请表（[entitlement 文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture)），**不适用于本项目**。
- 周期：beta 期间从每周改为每月，并且不再每次重启都问（[9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/)，二手）。Apple 没有公开具体周期，弹窗按钮写的是 "Allow For One Month"（见 thread 765103）。
- **`screencapture` CLI 会不会触发？** Apple 没有说明。因为权限记在 responsible app 头上，合理的推测是同样会对我们的 app 弹出，但这只是推测，需要实测（§8 验证清单）。有二手文章称系统自带的截图工具栏（⇧⌘5）不受这个弹窗影响（[screenify 博客](https://www.screenify.studio/blog/2026-04-10-screen-record-macos-sequoia)），但那是系统 app 自己的路径，不能等同于"第三方 app 调 CLI"。
- 结论：**选哪种方案都不能指望避开这个弹窗**。v1 的产品文案要预先说明"macOS 会定期请你确认截图权限"。

## 3. ScreenCaptureKit：macOS 14 / 15 / 26 API 差异

| API | 最低版本 | 作用 |
|---|---|---|
| `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)` | 12.3 | 枚举 displays / windows / applications（[doc](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getexcludingdesktopwindows(_:onscreenwindowsonly:completionhandler:))） |
| `SCContentFilter(display:excludingApplications:exceptingWindows:)` | 12.3 | 整屏，排除指定 app 的窗口（[doc](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:))） |
| `SCContentFilter(desktopIndependentWindow:)` | 12.3 | 只捕获单个窗口（[doc](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:))） |
| `SCStreamConfiguration.sourceRect` | 12.3 | 整屏捕获时裁剪区域；单窗口捕获时忽略（[doc](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)） |
| **`SCScreenshotManager.captureImage(contentFilter:configuration:)`** | **14.0** | 单帧截图，返回 `CGImage`（[doc](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(contentfilter:configuration:completionhandler:))） |
| `SCContentFilter.contentRect` / `.pointPixelScale` | 14.0 | 过滤内容的 point 尺寸和 point→pixel 倍率（[contentRect](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect)、[pointPixelScale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale)） |
| `SCStreamConfiguration.ignoreShadowsSingleWindow` | 14.0 | 单窗口截图去阴影（[doc](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/ignoreshadowssinglewindow)） |
| `SCContentSharingPicker` | 14.0 | 系统内容选择器（见 §4） |
| `SCShareableContent.currentProcess` | 14.4 | 只取本进程的可共享内容（[doc](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getcurrentprocessshareablecontent(completionhandler:))） |
| `SCStreamConfiguration.captureDynamicRange` | 15.0 | HDR 捕获（[doc](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturedynamicrange)） |
| **`SCScreenshotManager.captureImage(in:)`** | **15.2** | 按矩形截图："returns an image containing the contents of the rectangle in points, specified in display space"（[doc](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(in:completionhandler:))）。对应 2024-06 更新说明里的 "Capture screenshots across multiple displays"（[ScreenCaptureKit updates](https://developer.apple.com/documentation/updates/screencapturekit)） |
| `SCScreenshotManager.captureScreenshot(rect:configuration:)` / `(contentFilter:configuration:)` + `SCScreenshotConfiguration` / `SCScreenshotOutput` | 26.0 | 新版截图 API：同时输出 SDR/HDR、可直接写文件、`showsCursor`、`ignoreShadows` 等（[SCScreenshotConfiguration](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration)、[SCScreenshotOutput](https://developer.apple.com/documentation/screencapturekit/scscreenshotoutput)） |

要点：

- **macOS 14 基线**：截图只能用 `captureImage(contentFilter:configuration:)`。自由框选的做法是"整屏 filter + `sourceRect`"，或者截整屏后自己裁剪；跨屏选区需要每块屏各截一张再拼接。
- **macOS 15.2+**：`captureImage(in:)` 可以直接按 display space 矩形截图，并支持跨显示器。由于最低支持 14，需要 `if #available(macOS 15.2, *)` 分支。
- **旧 API 已不可用**：`CGWindowListCreateImage` 从 macOS 14 起 deprecated，用 macOS 15 SDK 编译时直接报错 "obsoleted in macOS 15.0"（[MacPorts ticket 71136](https://trac.macports.org/ticket/71136)，二手；与 macOS 15 release notes 里"迁移到 ScreenCaptureKit"的要求一致）。**不要考虑 CG 截图 API。**
- WWDC23 说明 `SCScreenshotManager` 是用来替代 `CGWindowListCreateImage` 的，原来的窗口图像选项都搬进了 `SCStreamConfiguration`，窗口列表选项搬进了 `SCShareableContent`（[WWDC23 10136 What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/)）。

## 4. `SCContentSharingPicker` 能否用于框选？不能

- 可选模式只有：`singleWindow`、`multipleWindows`、`singleApplication`、`multipleApplications`、`singleDisplay`（[SCContentSharingPickerMode](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickermode)）。`present(using:)` 的 `SCShareableContentStyle` 也只有 `window` / `application` / `display` / `none`（[SCShareableContentStyle](https://developer.apple.com/documentation/screencapturekit/scshareablecontentstyle)）。**没有任意矩形区域。**
- 配置项：`allowedPickerModes`、`excludedBundleIDs`、`excludedWindowIDs`、`allowsChangingSelectedContent`（[SCContentSharingPickerConfiguration](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickerconfiguration-swift.struct)）。结果通过 `SCContentSharingPickerObserver` 回调给出一个 `SCContentFilter`（[observer](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickerobserver)；WWDC23 10136）。
- 定位：Apple 把它当作 stream / 屏幕共享的"系统共享控件"（"the system screen-sharing control … for letting people select content sources and manage active streams"，[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)），并不是为一次性截图设计的。picker 选出的 filter 能否直接交给 `SCScreenshotManager` 截图、能否完全不经过 TCC 授权，Apple 都没有文档说明。DTS 也说过自己还没试过（"One day I'll have some time to play around with `SCContentSharingPicker`"，[thread 760112](https://developer.apple.com/forums/thread/760112)）。
- 可能的用途：**只用于"单窗口 / 全屏"两种模式**来规避 §2 的月度弹窗（依据是 DTS 在 thread 765103 的说法）。但它的交互是"先弹系统选择器、再点选"，比一个 Hotkey 直接截图多一步，而且自由框选仍然得走另一条路。**v1 不采用**，列为后续可评估项。

## 5. `screencapture` CLI

来源：`man screencapture`（[Xcode man pages 镜像](https://keith.github.io/xcode-man-pages/screencapture.1.html)）。与本需求相关的参数：

| 参数 | 含义（man page 原文要点） | 用途 |
|---|---|---|
| `-i` | "Capture screen interactively, by selection or window. … The space key will toggle between mouse selection and window selection modes. The escape key will cancel" | 框选 / 窗口选择的入口 |
| `-s` | "Only allow mouse selection mode" | 自由框选 |
| `-w` | "Only allow window selection mode" | 单窗口（禁止切换） |
| `-W` | "Start interaction in window selection mode" | 单窗口（允许空格切回框选） |
| `-o` | "In window capture mode, do not capture the shadow of the window" | 窗口截图去阴影 |
| `-c` | "Force screen capture to go to the clipboard" | **不用**：会覆盖用户剪贴板 |
| `-x` | "Do not play sounds" | 静音 |
| `-t <format>` | "Image format to create, default is png (other options include pdf, jpg, tiff…)" | 发给模型用 `png`；需要压缩体积可以用 `jpg` |
| `-m` / `-D <display>` | 只截主屏 / 指定显示器（1 = 主屏）；`-m` "undefined if -i is set" | 全屏模式选屏 |
| `-R x,y,w,h` | 截指定矩形 | 备用 |
| `-l <windowid>` | 按 window id 截窗口 | 备用 |
| `-r` | "Do not add screen dpi meta data to captured file" | 说明默认会写入 DPI 元数据 |
| `-J selection\|window\|video` / `-U` | 交互初始样式 / 显示交互工具栏 | 不需要 |
| `files` | "where to save the screen capture, 1 file per screen" | 非交互全屏时**每块屏一个文件名** |

要点和局限：

- **多显示器**：`-i` 的选择 UI 覆盖所有屏幕，由系统负责。非交互的全屏模式按 "1 file per screen" 输出，可以传多个路径，也可以用 `-D` 只截鼠标所在的屏。
- **Retina**：输出图片的像素尺寸、DPI 元数据都由系统处理（`-r` 的存在说明默认会写 DPI）。具体像素尺寸需要实测（§8 验证清单）。
- **取消**：man page 没有写 Esc 取消后的 exit status，**可靠的判断方法是看输出文件是否存在**。
- **隐藏自己的窗口**：CLI 不知道哪个窗口属于我们，必须先 `orderOut` 掉 Quick Panel / Main Window，等 WindowServer 刷新完再启动进程（等多久需要实测）。截完再恢复显示。
- **文档质量**：man page 自己写着 "The screencapture utility is not very well documented to date" 和 "Better documentation is needed for this utility"，参数行为可能随系统版本变化，没有 API 稳定性承诺。
- **权限**：见 §1.2。权限记在我们的 app 头上，调用前必须 preflight。

## 6. ScreenCaptureKit 自绘 UI 需要处理的问题

- **隐藏自身窗口**：不需要 `orderOut`，在 filter 里排除本 app 即可。官方 sample 的做法是按 `Bundle.main.bundleIdentifier` 找出自己的 `SCRunningApplication`，传给 `SCContentFilter(display:excludingApplications:exceptingWindows:)`（[Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)）。这样截全屏时 Quick Panel 不会闪烁。**不要用 `NSWindow.sharingType = .none`**：Apple 已把它标成 "A legacy constant that macOS no longer uses … Don't use this value to hide or omit content from being captured"（[NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)）。
- **Retina / 输出尺寸**：`SCDisplay.width` 的单位是 point（[SCDisplay.width](https://developer.apple.com/documentation/screencapturekit/scdisplay/width)），`SCStreamConfiguration.width/height` 是输出尺寸。官方 sample 用 `display.width * scaleFactor` 来设置（同上 sample）。macOS 14+ 可以用 `SCContentFilter.pointPixelScale` 或 `NSScreen.backingScaleFactor`（[doc](https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor)）换算。不设置的话可能得到 1x 的图。
- **坐标系**：ScreenCaptureKit 和 CG 用的是 global display space，原点在主屏**左上角**（[CGDisplayBounds](https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:))），AppKit 的 `NSScreen.frame` 原点在左下角。自绘 overlay 得到的选区要先翻转 y 轴，再交给 `sourceRect` 或 `captureImage(in:)`。多屏、屏幕排布不对齐、各屏 scale 不同时最容易出错。
- **框选 / 窗口选择 overlay 需要自己写**：每个 `NSScreen` 一个无边框全屏 overlay 窗口，负责十字光标、拖拽矩形、Esc 取消，以及窗口模式下根据鼠标位置命中 `SCShareableContent.windows` 并高亮。商用截图工具常见的"冻结帧"做法是先截全部屏幕，再在静态图上框选，然后裁剪。工作量明显大于 CLI 方案。
- **单窗口**：`SCContentFilter(desktopIndependentWindow:)`，配合 `ignoreShadowsSingleWindow` 去阴影。这种模式下 `sourceRect` 被忽略（[sourceRect](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)）。

## 7. 对比表

| 维度 | ScreenCaptureKit + 自绘选区 UI | `screencapture` CLI（`Process`） |
|---|---|---|
| Screen Recording TCC | 需要，记在 app 头上（§1.1） | 需要，**同样记在 app 头上**（responsible code，§1.2） |
| 未授权时 | 抛 `SCStreamError.userDeclined`，可以精确提示 | 静默得到"只有壁纸"的图（二手报告），必须先 preflight |
| macOS 15 月度复核弹窗 | **会触发**（DTS 复现，§2） | Apple 未说明，推测同样会触发，**需实测** |
| 全屏 | `SCContentFilter(display:excludingApplications:…)`，排除自身窗口，不闪烁 | `-x -D n` / 多文件；需要先隐藏自身窗口 |
| 单窗口 | 自绘窗口高亮 + `desktopIndependentWindow`；或用 `SCContentSharingPicker`（`singleWindow`） | `-i -w`（或 `-W`）+ `-o`，系统原生 UI |
| 自由框选 | **只能自绘 overlay**（picker 不支持区域）；macOS 15.2+ 可用 `captureImage(in:)` | `-i -s`，系统原生 UI |
| 多显示器 | 自己处理坐标翻转、跨屏选区、拼接（14.x）或 `captureImage(in:)`（15.2+） | 系统处理 |
| Retina | 自己设置 `width/height = points × scale` | 系统处理（需实测确认像素尺寸） |
| 隐藏自身窗口 | filter 排除，无需 orderOut | 必须 orderOut 后再延时 |
| 取消 / 错误处理 | 代码完全可控 | 只能看输出文件是否存在、看 exit code（未文档化） |
| UI 定制（冻结帧、标注、放大镜） | 完全可控 | 不可定制 |
| 工作量 | 大（overlay、多屏、坐标、Retina） | 小（几十行 + 权限引导） |
| 长期风险 | Apple 推荐路线，API 持续演进（15.2、26.0 都有新增） | CLI "not very well documented"，DTS 明确不推荐；macOS 15 beta 出过 prompt loop |

## 8. v1 建议

**v1 用 `screencapture` CLI，并把它放在一个 `ScreenshotCapturer` 接口后面。**

理由：两种方案的权限成本相同（都要 Screen Recording，都要面对 macOS 15 的月度复核），而 CLI 免费提供了系统原生、用户熟悉的框选和窗口选择 UI，多显示器、Retina 也都由系统处理。ScreenCaptureKit 的主要优势（排除自身窗口不闪烁、可定制 UI、类型化错误）在 v1「截图 → 挂到 Message」这个最小闭环里不是刚需，而自绘多屏 overlay 的工作量和出错面都很大。

v1 具体做法：

1. **权限闸门**：每次截图前调用 `CGPreflightScreenCaptureAccess()`。返回 `false` 时，调用 `CGRequestScreenCaptureAccess()`，同时在 Quick Panel / Main Window 里显示引导："去 System Settings › Privacy & Security › Screen & System Audio Recording 打开 Chatbot，然后重启 app"，并提供"重新启动"按钮。原因是授权后进程内的 preflight 仍可能返回 `false`（§1.3）。Info.plist 加上 `NSScreenCaptureUsageDescription`。
2. **三种模式到参数的映射**（输出到 `FileManager.temporaryDirectory` 下的唯一文件名，不使用 `-c`）：
   - 全屏：`screencapture -x -t png -D <鼠标所在屏的序号> <file>`
   - 单窗口：`screencapture -i -w -o -x -t png <file>`
   - 自由框选：`screencapture -i -s -x -t png <file>`
3. **隐藏自身**：先 `orderOut` Quick Panel（及 Main Window），短暂延时后再启动 `Process`。在 `terminationHandler` 里读取文件：文件不存在就当作用户取消；文件存在就生成 Screenshot Attachment，然后重新显示 Quick Panel。
4. **产品文案**：首次引导页说明 macOS 15+ 会定期弹出 "Allow For One Month"，属于系统行为。
5. **升级路径**：以下任一需求出现时，在同一个 `ScreenshotCapturer` 接口后新增 ScreenCaptureKit 实现：截图时 Quick Panel 不能闪烁、需要冻结帧、需要标注 / 放大镜、CLI 在新系统上行为变化。可以先从全屏模式迁移（`SCContentFilter` 排除自身，难度最低），框选最后迁移。届时再评估 `SCContentSharingPicker` 能否用于单窗口 / 全屏，以规避月度弹窗。

### 上线前必须在真机（macOS 14 与 15，最好再加 26）上验证

1. 未授权时从 app 内运行 `screencapture -i -s`：是只截到壁纸，还是触发 TCC 弹窗？Screen Recording 列表里出现的是不是我们的 app？
2. 已授权后，`screencapture` 是否同样触发 §2 的 "bypass the system private window picker" 月度弹窗？弹窗显示的是哪个 app？
3. 交互模式下按 Esc 取消时的 exit status 和文件行为。
4. `orderOut` 之后需要等多久，Quick Panel 才不会出现在截图里。
5. Retina 屏和非 Retina 外接屏混用时，输出 PNG 的像素尺寸，以及在跨屏位置框选时的结果。
6. 签名：用 Developer ID 稳定签名构建，确认重新构建后授权仍然保留（§1.3）。
