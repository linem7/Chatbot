# 研究：全局 Hotkey 与非激活 Quick Panel

- 对应 issue：[#4 研究：全局快捷键与非激活浮窗](https://github.com/linem7/Chatbot/issues/4)（Part of #1）
- 日期：2026-10-08
- 前提：原生 Swift/SwiftUI、macOS 14+、App Store 外分发、**不启用 App Sandbox**（见 README）
- 术语按 `CONTEXT.md`：**Hotkey** = 全局快捷键；**Quick Panel** = Hotkey 唤起的不抢焦点浮窗

## TL;DR

1. **Hotkey 用 Carbon `RegisterEventHotKey`**（直接调用或经 `sindresorhus/KeyboardShortcuts` 封装）。它是唯一**不需要任何 TCC 权限**（既不需要 Accessibility，也不需要 Input Monitoring）的全局快捷键方式；`NSEvent.addGlobalMonitorForEvents` 要 Accessibility，`CGEventTap` 要 Input Monitoring / Accessibility。
2. **ctrl+space 默认会被系统「选择上一个输入源」占用**（Apple 文档确认该快捷键存在）。Apple 没有任何一手文档说明 app 注册的 Hotkey 能否压过系统 symbolic hotkey；Raycast、Alfred 的做法都是**引导用户去 System Settings 关闭/改掉系统快捷键**，而不是在 app 侧"抢"。用 `CopySymbolicHotKeys()` 可以在运行时检测"是否存在已启用的系统快捷键 = ctrl+space"。
3. **Quick Panel 用 `NSPanel`**：`styleMask` 含 `.nonactivatingPanel`，`level = .floating`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`，`hidesOnDeactivate = false`，子类 `override canBecomeKey { true }`；用 `NSHostingView` 装 SwiftUI 内容；监听 `windowDidResignKey` 自动隐藏；Esc 用 SwiftUI `.onExitCommand` 或本地 `NSEvent` monitor。
4. **SwiftUI 生命周期**：`App` 里放 `MenuBarExtra`（macOS 13+）+ `Settings` scene，Info.plist 设 `LSUIElement = true`；AppKit 的 Hotkey 注册与 `NSPanel` 由 `@NSApplicationDelegateAdaptor` 注入的 delegate 持有。SwiftUI 自带的 `Window` + `.windowLevel(.floating)` 要 macOS 15 且做不到 nonactivating，不适用。

---

## 1. Hotkey 注册方式对比

### 1.1 Carbon `RegisterEventHotKey`

- 行为：按虚拟键码 + 修饰键注册"global hot key"；同一进程内同一组合只能注册一次，**但多个 app 可以注册同一组合，都会收到通知**；10.5+ 可传 `kEventHotKeyExclusive` 请求独占——独占注册期间非独占注册者收不到事件，若已有另一进程独占同一组合则返回 `eventHotKeyExistsErr`。（来源：SDK 头文件 `HIToolbox/CarbonEvents.h` 中 `RegisterEventHotKey()` / `HotKeyOptions` 的注释，[phracker/MacOSX-SDKs 镜像](https://raw.githubusercontent.com/phracker/MacOSX-SDKs/master/MacOSX11.3.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/CarbonEvents.h)）
- 退出时无需手动 `UnregisterEventHotKey`，系统会清理；用户改键时才需要（同上来源，`UnregisterEventHotKey()` 注释）。
- 事件到达方式：`InstallEventHandler(GetEventDispatcherTarget(), ...)` 监听 `kEventClassKeyboard / kEventHotKeyPressed`（同上头文件；实际用法见 [KeyboardShortcuts `HotKey.swift`](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/HotKey.swift) 与 [soffes/HotKey `HotKeysController.swift`](https://github.com/soffes/HotKey/blob/main/Sources/HotKey/HotKeysController.swift)）。
- 权限：**无 TCC 权限对话框**。KeyboardShortcuts README FAQ "Does this package cause any permission dialogs?" 回答 "No"，且声明 "fully sandboxed and Mac App Store compatible"（[readme](https://github.com/sindresorhus/KeyboardShortcuts#readme)）。
- 可用性：`AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER`，未标记 deprecated（CarbonEvents.h）。KeyboardShortcuts README FAQ："Most of the Carbon APIs were deprecated years ago, but there are some left that Apple never shipped modern replacements for. This includes registering global keyboard shortcuts."（[readme](https://github.com/sindresorhus/KeyboardShortcuts#readme)）
- 重要限制：**注册成功并不代表这个组合可用**。`RegisterEventHotKey` 不会对系统快捷键做冲突检查，状态码只在"另一进程已独占"时报错（CarbonEvents.h）；第三方封装 [go-macos/hotkey](https://pkg.go.dev/github.com/go-macos/hotkey) 的文档也明确写 "RegisterEventHotKey does NOT conflict-check against system shortcuts"（二手来源，与头文件一致）。

### 1.2 `CGEvent.tapCreate`（CGEventTap）

- 行为：在 HID / session / annotated-session 三个位置之一插入 tap；`listenOnly` 只能观察，`defaultTap`（active filter）可以修改或丢弃事件（[CGEventTapOptions](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions)、[CGEventTapLocation](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation)）。只有 root 才能把 tap 放在 HID 入口（[tapCreate 文档](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))）。
- 权限：Apple 文档原文仍是旧措辞 "Event taps receive key up and key down events if ... The current process is running as the root user [or] Access for assistive devices is enabled"（同上）。Apple DTS（Quinn "The Eskimo!"）在论坛的权威说明：**"Rather than using an `NSEvent` global event monitor, use a `CGEventTap`. For weird historical reasons, the former requires the Accessibility privilege whereas the latter requires the Input Monitoring privilege."** 并指出 Input Monitoring 有 `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` 可检查与申请（[Accessibility permission in sandboxed app](https://developer.apple.com/forums/thread/707680)）。这两个函数 macOS 10.15+ 可用（[CGPreflightListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())、[CGRequestListenEventAccess](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess())）。
- 社区观察（非 Apple 官方，仅供参考）：`defaultTap` 触发 Accessibility 申请，`listenOnly` 触发 Input Monitoring 申请；已有 Accessibility 的 app 不会再弹 Input Monitoring（[论坛 thread 122492](https://developer.apple.com/forums/thread/122492)）。
- 结论：只为了一个 Hotkey 不值得让用户开 Input Monitoring / Accessibility；但如果以后 Quick Panel 需要"吞掉"按键（例如即使系统快捷键存在也要抢 ctrl+space），active tap 是唯一能 *丢弃* 事件的 API。

### 1.3 `NSEvent.addGlobalMonitorForEvents(matching:handler:)`

- 行为：接收**其他 app** 收到的事件副本，只能观察不能拦截："you cannot modify or otherwise prevent the event from being delivered to its original target application"；且 "your handler will not be called for events that are sent to your own application"（[Apple 文档](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))）。
- 权限：**"Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access (see AXIsProcessTrusted)"**（同上）。检查/申请用 [`AXIsProcessTrusted()`](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted) 与 [`AXIsProcessTrustedWithOptions(_:)`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)（`kAXTrustedCheckOptionPrompt` 可弹系统提示）。
- 结论：权限要求最重、能力最弱（不能吞键），不适合做 Hotkey。配套的 `addLocalMonitorForEvents` 只看本 app 事件、可返回 `nil` 吞掉事件（[Apple 文档](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))），适合在 Quick Panel 内处理 Esc。

### 1.4 `sindresorhus/KeyboardShortcuts`

- 版本/活跃度：最新 release 3.1.0（2026-09-11），2.7k stars，仍在活跃维护（GitHub API，2026-10-08 查询）。要求 macOS 10.15+（[readme](https://github.com/sindresorhus/KeyboardShortcuts#readme)）。
- 底层：Carbon `RegisterEventHotKey` + `InstallEventHandler(GetEventDispatcherTarget(), ...)`，`inOptions` 传 `0`（非独占）（[HotKey.swift](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/HotKey.swift)）。
- API：`extension KeyboardShortcuts.Name { static let x = Self("x") }` 定义名字；`KeyboardShortcuts.Recorder("…", name: .x)` 是 SwiftUI 录制控件，自动存 `UserDefaults`（前缀 `KeyboardShortcuts_`）；监听用 `KeyboardShortcuts.onKeyDown(for:)` / `onKeyUp(for:)` 或 `for await _ in KeyboardShortcuts.events(for: .x)`（readme；[KeyboardShortcuts.swift](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift)）。
- 冲突处理（对本题关键）：Recorder 用 `CopySymbolicHotKeys` 读出所有 **enabled** 的系统快捷键做比对（`HotKeyCenter.systemShortcuts`，HotKey.swift）；命中时按 `ConflictPolicy.systemShortcut` 处理，**默认 `.warn`**，即弹 "This keyboard shortcut cannot be used as it's already a system-wide keyboard shortcut." + "Most system-wide keyboard shortcuts can be changed in "System Settings › Keyboard › Keyboard Shortcuts"." 并给 "Use Anyway" 按钮；可用 `.keyboardShortcutsConflictPolicy(.init(systemShortcut: .block/.warn/.allow))` 调整（[ConflictPolicy.swift](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/ConflictPolicy.swift)、[RecorderCocoa.swift](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/RecorderCocoa.swift)、[en.lproj/Localizable.strings](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Localization/en.lproj/Localizable.strings)）。
- 默认快捷键：支持 `Name("x", initial: .init(.space, modifiers: [.control]))`，但 README 明确劝阻公开分发的 app 设默认值："Users find it annoying when random apps steal their existing keyboard shortcuts. It's generally better to show a welcome screen on the first app launch that lets the user set the shortcut."（readme "Initial keyboard shortcuts"）
- 其他：README 列出优点 "Works when `NSMenu` is open"（菜单栏 app 场景有用）；不支持媒体键、Caps Lock。

### 1.5 `soffes/HotKey`

- 底层同样是 Carbon：README "wraps the Carbon APIs for dealing with global hot keys"；源码 `RegisterEventHotKey` / `UnregisterEventHotKey` / `InstallEventHandler(GetEventDispatcherTarget(), …, kEventHotKeyPressed/Released)`（[README](https://github.com/soffes/HotKey#readme)、[HotKeysController.swift](https://github.com/soffes/HotKey/blob/main/Sources/HotKey/HotKeysController.swift)）。
- API 极简：`HotKey(key: .space, modifiers: [.control])` + `keyDownHandler` / `keyUpHandler`，对象生命周期即注册生命周期。
- 活跃度：最新 tag v0.2.1，最后 push 2024-12-29，1.08k stars，32 open issues（GitHub API，2026-10-08 查询）。**没有**录制 UI、没有系统快捷键冲突检测、没有持久化。

### 1.6 对比表

| 方案 | 底层 | 需要的 TCC 权限 | 能否吞掉按键 | 能否被系统快捷键压制 | 自带改键 UI / 冲突检测 | 维护状态 |
|---|---|---|---|---|---|---|
| Carbon `RegisterEventHotKey`（直接调用） | HIToolbox | **无** | 否（只收通知） | 是（见 §2） | 无 | Apple 未 deprecated，无现代替代 |
| `CGEventTap` listenOnly | Quartz Event Services | Input Monitoring（Eskimo） | 否 | 需实测 | 无 | 活跃 |
| `CGEventTap` defaultTap | Quartz Event Services | Accessibility（社区观察，Apple 文档"assistive devices"） | **是** | 理论上可在到达系统处理前丢弃，需实测 | 无 | 活跃 |
| `NSEvent.addGlobalMonitorForEvents` | AppKit | Accessibility（Apple 文档） | 否 | 是 | 无 | 活跃 |
| `KeyboardShortcuts` | Carbon | **无** | 否 | 是，但 Recorder 会检测并提示 | **有**（SwiftUI Recorder + `CopySymbolicHotKeys` 检测 + ConflictPolicy） | 3.1.0, 2026-09 |
| `HotKey` | Carbon | **无** | 否 | 是 | 无 | v0.2.1, 2024-12 |

---

## 2. ctrl+space 与系统「选择上一个输入源」的冲突

### 2.1 系统侧事实

- Apple 官方快捷键清单：Control–Space bar / Control–Option–Space bar = "Select the previous or next input source, if you use multiple input sources to type in different languages."（[Mac keyboard shortcuts, HT102650](https://support.apple.com/102650)）。Mac 使用手册同样写 "Press Control-Space bar to select the last input source you used"（[Write in another language on Mac](https://support.apple.com/guide/mac-help/mchlp1406/mac)）。
- 用户可在 System Settings › Keyboard › Keyboard Shortcuts 改键，"Double-click the shortcut you want to change, then press the new key combination you want to use"，冲突项会显示警告图标（[Change a conflicting keyboard shortcut on Mac](https://support.apple.com/guide/mac-help/mchlp2864/mac)）。
- Apple 的措辞是"if you use multiple input sources"；**只有一个输入源时该快捷键是否仍会吞掉 ctrl+space，Apple 没有文档说明**，需要实测（见 §6）。实践上中文用户几乎必然有 ≥2 个输入源，应按"默认冲突"设计。
- 社区已知（非官方）：该快捷键对应 `~/Library/Preferences/com.apple.symbolichotkeys.plist` 中 `AppleSymbolicHotKeys` 的 ID **60**（previous input source）与 **61**（next source in Input menu），参数为 `[32, 49, 262144]` 即 space / keycode 49 / Control；可用 `defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 60 "<dict><key>enabled</key><false/></dict>"` 关闭，但要重启/重登录才生效（[dev.to 命令整理](https://dev.to/dirtyhenry/command-line-instructions-to-uncheck-select-the-previous-input-source-on-macos-254g)；[Apple 论坛 FB24297598](https://developer.apple.com/forums/thread/841799) 里的用户也写明 "AppleSymbolicHotKeys ID 60 is the only enabled system hotkey bound to keycode 49 with Control alone"）。**不建议 app 替用户改这个 plist**：无公开 API，且生效需要重登录。

### 2.2 app 注册的 Hotkey 能否"赢"过系统快捷键

- **Apple 没有任何一手文档定义系统 symbolic hotkey 与 `RegisterEventHotKey` 之间的优先级**。CarbonEvents.h 只描述 app 之间的非独占/独占语义（§1.1），`kEventHotKeyExclusive` 只对"其他进程的 Carbon 注册者"生效，不涉及系统快捷键。
- 事实证据都指向"系统先吃掉，app 收不到"：
  - Raycast 官方手册：如果 ⌘Space 不工作 "that hotkey is assigned to another feature on your Mac"，解决办法是去 System Settings › Keyboard › Keyboard Shortcuts › Spotlight 关闭；对输入源冲突："If you use or have previously used multiple languages on your Mac, you will most likely have a conflicting setup. Go to System Settings > Keyboard > Keyboard Shortcuts > Input Sources and disable or change the shortcut."（[manual.raycast.com/v1/hotkey](https://manual.raycast.com/v1/hotkey)）。
  - Alfred 官方帮助：同样要求用户关闭 Spotlight 快捷键，并检查 "Keyboard > Keyboard Shortcuts > Input Sources" 里没有同样的组合；还提到 "macOS may be reserving it behind the scenes"，有时需要先勾选某项再取消才能释放组合（[Using Cmd + Space as Alfred hotkey](https://www.alfredapp.com/help/troubleshooting/cmd-space/)）。
  - KeyboardShortcuts 的 Recorder 把"系统已启用的快捷键"视为冲突并默认 `.warn`（§1.4）。
  - go-macos/hotkey 文档："RegisterEventHotKey does NOT conflict-check against system shortcuts"，注册返回 0 但事件永远不会到达（[pkg.go.dev](https://pkg.go.dev/github.com/go-macos/hotkey)，二手）。
- 因此 v1 应当假设：**系统快捷键启用时，ctrl+space 不会送到我们的 Hotkey**。唯一在 app 侧"硬抢"的路线是 `CGEventTap`（`defaultTap`，需要 Accessibility，且是否能在 symbolic hotkey 处理之前拦截也需实测）——不推荐 v1 做。

### 2.3 如何程序化检测冲突

用 Carbon `CopySymbolicHotKeys(&array)`：返回 `CFArray<CFDictionary>`，每个字典有 `kHISymbolicHotKeyCode`（虚拟键码）、`kHISymbolicHotKeyModifiers`（Carbon 修饰键位）、`kHISymbolicHotKeyEnabled`；它只覆盖 "system-wide hotkeys such as the Screen Capture, Universal Access, and Keyboard Navigation keys"，**"There is currently no way to determine which hotkey in the Keyboards preference pane corresponds to a specific dictionary"**，并且是 O(n) 调用，不要频繁调用（CarbonEvents.h `CopySymbolicHotKeys()` 注释，10.3+）。

- ctrl+space 的比对值：`kVK_Space = 0x31`（49），`controlKey = 1 << controlKeyBit`（[HIToolbox/Events.h](https://raw.githubusercontent.com/phracker/MacOSX-SDKs/master/MacOSX11.3.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h)）。
- 现成实现：KeyboardShortcuts 的 `Shortcut.isTakenBySystem`（内部即上述逻辑，并会去掉合成的 Fn 位）（[Shortcut.swift](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Shortcut.swift)）。
- 结论：我们能知道"**有一个已启用的系统快捷键等于 ctrl+space**"，但按 Apple 注释无法从 API 得知它就是"选择上一个输入源"——不过 ctrl+space 在系统默认快捷键里只有这一处，提示文案可以直接点名。
- 另一种思路是读 `com.apple.symbolichotkeys` plist，但它只是"用户改动的覆盖层"而非完整目录（go-macos 文档观察；二手），不如 `CopySymbolicHotKeys` 可靠。

### 2.4 让用户改键的产品做法（Raycast / Alfred / KeyboardShortcuts 共识）

1. 首次启动显示欢迎页让用户确认/录制 Hotkey，而不是静默抢键（KeyboardShortcuts README 建议；与 CONTEXT.md "默认 ctrl+space" 不冲突——可以把 ctrl+space 作为**推荐值预填**，但启动时检测冲突）。
2. 检测到 ctrl+space 被系统快捷键占用时，弹说明：到 System Settings › Keyboard › Keyboard Shortcuts › Input Sources 取消勾选「选择上一个输入源」，或在 app 里换一个 Hotkey（Raycast/Alfred 文案模式）。
3. 录制控件直接用 `KeyboardShortcuts.Recorder`，`ConflictPolicy.systemShortcut` 保持默认 `.warn`（允许"Use Anyway"，因为用户可能随后去关系统快捷键）。
4. 不要在 app 里写 `com.apple.symbolichotkeys`。

---

## 3. Quick Panel：`NSPanel` 技术要点

### 3.1 为什么是 `NSPanel` 而不是 `NSWindow`/SwiftUI `Window`

- `NSWindow.StyleMask.nonactivatingPanel`："The window is a panel or a subclass of NSPanel that does not activate the owning app."（[Apple 文档](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)）——这正是"不抢焦点"的定义，只有 `NSPanel` 支持。
- Apple 自己给的"面板可以 float"的条件与 Quick Panel 完全吻合：小、偏鼠标操作或仅在需要时成为 key、用户在其它窗口工作时仍要可见、app 失活时隐藏（[isFloatingPanel](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel)）。
- SwiftUI 的 `Window` scene 虽有 `.windowLevel(.floating)`，但 **macOS 15+** 才可用，且没有 nonactivating 语义（[windowLevel(_:)](https://developer.apple.com/documentation/swiftui/scene/windowlevel(_:))）；`MenuBarExtra` 的 `.window` 样式是锚定在状态栏图标下的 popover 式窗口（[menuBarExtraStyle .window](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window)），不是 Hotkey 唤起的居中浮窗。所以 Quick Panel 必须是 AppKit `NSPanel`。

### 3.2 关键属性与依据

| 需求 | 设置 | 依据 |
|---|---|---|
| 不激活 owning app | `styleMask` 含 `.nonactivatingPanel` | [nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel) |
| 无标题栏时仍能接收键盘 | 子类 `override var canBecomeKey: Bool { true }` | `canBecomeKey` 默认仅当 styleMask 含 `.titled` 才为 true；"To make a window key without including the titled flag… override this property in an NSWindow subclass to return true"（[canBecomeKey](https://developer.apple.com/documentation/appkit/nswindow/canbecomekey)） |
| 浮在普通窗口之上 | `level = .floating` | "Floating windows… appear in front of all normal-level windows"（[level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.property)、[NSWindow.Level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct)） |
| 在每个 Space / 全屏 app 上方出现 | `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` | `canJoinAllSpaces`："The window can appear in all spaces. The menu bar behaves this way."；`fullScreenAuxiliary`："The window displays on the same space as the full screen window."；`fullScreenPrimary/Auxiliary/None` 互斥（[CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)） |
| 不进 Mission Control / ⌘` 循环 | `.transient`（level ≠ normal 时已是默认）、`.ignoresCycle` | `transient`："This is the default behavior if windowLevel isn't equal to normal."（同上） |
| app 失活时不被 AppKit 自动藏掉 | `hidesOnDeactivate = false` | NSPanel 默认 **true**（[hidesOnDeactivate](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate)）。我们的 app 几乎永远不是 active app，交给自己的 resignKey 逻辑控制更可预期（推断） |
| 关闭后可复用 | `isReleasedWhenClosed` 对 NSPanel 默认 false；显示/隐藏用 `orderFrontRegardless()` / `orderOut(nil)` 而非 `close()` | [isReleasedWhenClosed](https://developer.apple.com/documentation/appkit/nswindow/isreleasedwhenclosed) |
| 显示且成为 key | `makeKeyAndOrderFront(nil)`（panel 是 nonactivating，不会激活 app） | [makeKeyAndOrderFront](https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront(_:))；对照 `orderFrontRegardless()` 只前置不改 key（[orderFrontRegardless](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())） |
| 失焦自动隐藏 | `NSWindowDelegate.windowDidResignKey(_:)` / `NSWindow.didResignKeyNotification` → `orderOut(nil)` | [windowDidResignKey](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidresignkey(_:))、[didResignKeyNotification](https://developer.apple.com/documentation/appkit/nswindow/didresignkeynotification) |
| Esc 关闭 | SwiftUI `.onExitCommand { hide() }`（"the escape key on macOS"）；或 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 里判断 `keyCode == 0x35`（`kVK_Escape`）并返回 nil 吞掉 | [onExitCommand](https://developer.apple.com/documentation/swiftui/view/onexitcommand(perform:))、[addLocalMonitorForEvents](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))、Events.h；另：带 close 按钮的 key panel 本身就会在 Esc 时自关（[How Panels Work](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/WinPanel/Concepts/UsingPanels.html)），但我们是无边框面板，需自己处理 |
| 出现在"当前"显示器 | 用 `NSEvent.mouseLocation` 在 `NSScreen.screens` 中找包含鼠标的屏幕；或 `NSScreen.main`（含键盘焦点窗口的屏幕） | [mouseLocation](https://developer.apple.com/documentation/appkit/nsevent/mouselocation)、[NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)、[NSScreen.main](https://developer.apple.com/documentation/appkit/nsscreen/main)（注意 `main` ≠ 菜单栏所在屏幕） |
| 文本框在非激活面板里拿焦点 | 默认即可；`becomesKeyOnlyIfNeeded` 为 true 时非激活面板只在 hit view 的 `needsPanelToBecomeKey` 为 true 时成为 key | [becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)、[needsPanelToBecomeKey](https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey)。Quick Panel 以输入为主，保持默认 false |

### 3.3 参考骨架（未编译，仅示意）

```swift
final class QuickPanel: NSPanel {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: content.onExitCommand { [weak self] in self?.orderOut(nil) })
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        if isKeyWindow { orderOut(nil); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2 + f.height * 0.1))
        }
        makeKeyAndOrderFront(nil)
    }
}
// delegate: windowDidResignKey -> orderOut(nil)
```

`NSHostingView` 是 "An AppKit view that hosts a SwiftUI view hierarchy… The hosting view also coordinates event delivery."（[NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview)）；若要 view controller 形态用 [`NSHostingController`](https://developer.apple.com/documentation/swiftui/nshostingcontroller)。

---

## 4. 在 SwiftUI 生命周期中承载

- `MenuBarExtra`（macOS 13+）："Use a MenuBarExtra when you want to provide access to commonly used functionality, even when your app is not active." 仅菜单栏的 app 若用户把图标从菜单栏移除会被自动终止；要不显示 Dock 图标与 app switcher，"set the LSUIElement flag in your app's Information-Property-List file to true"（[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)）。`LSUIElement`："A Boolean value indicating whether the app is an agent app that runs in the background and doesn't appear in the Dock."（[LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)）；运行时等价物是 `NSApp.setActivationPolicy(.accessory)`，`.accessory` "corresponds to value of the LSUIElement key… being 1"，"may be activated programmatically or by clicking on one of its windows"（[ActivationPolicy.accessory](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)、[setActivationPolicy](https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:))）。
- `@NSApplicationDelegateAdaptor`（macOS 11+）："SwiftUI instantiates the delegate and calls the delegate's methods in response to life cycle events. Define the delegate adaptor only in your App declaration, and only once for a given app." delegate 若遵循 `ObservableObject` 会自动进 Environment（[NSApplicationDelegateAdaptor](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor)）。Apple 建议能用 `ScenePhase` 就别用 delegate，但 Hotkey 注册与 `NSPanel` 持有没有 SwiftUI 等价物，放 delegate 的 `applicationDidFinishLaunching` 是合理归宿。
- 建议结构：

```swift
@main struct ChatbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        MenuBarExtra("Chatbot", systemImage: "bubble.left") { StatusMenu() }   // 打开 Main Window / Settings / Quit
        Settings { SettingsView() }       // 含 KeyboardShortcuts.Recorder("Hotkey:", name: .toggleQuickPanel)
        // Main Window 可用 Window("…", id:) 场景，由 openWindow 打开
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: QuickPanel!
    func applicationDidFinishLaunching(_: Notification) {
        panel = QuickPanel(content: QuickPanelView())
        KeyboardShortcuts.onKeyDown(for: .toggleQuickPanel) { [weak self] in self?.panel.toggle() }
    }
}
```

- 注意点：
  - Settings/Main Window 是常规窗口，accessory app 打开它们时要主动 `NSApp.activate()`（macOS 14+，"calling this method doesn't guarantee app activation"）或 `activate(ignoringOtherApps: true)`（[activate()](https://developer.apple.com/documentation/appkit/nsapplication/activate())、[activate(ignoringOtherApps:)](https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:))）；从视图里打开设置用 macOS 14 的 `@Environment(\.openSettings)`（[openSettings](https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings)）。
  - Quick Panel 是 `NSPanel`，AppKit 的"重新打开 app 时无可见窗口则新建窗口"逻辑只数 `NSWindow` 不数 `NSPanel`（[applicationShouldHandleReopen](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:))）；LSUIElement app 本来也没有 Dock 图标可点，影响不大。
  - `KeyboardShortcuts.Recorder` 放在 `Settings` 场景里；如果希望首次启动引导页也能录制，同样复用 Recorder。

---

## 5. v1 推荐

| 决策点 | 推荐 | 理由 |
|---|---|---|
| Hotkey 机制 | **`KeyboardShortcuts`**（Carbon 封装） | 零权限；自带 SwiftUI Recorder、UserDefaults 持久化、`CopySymbolicHotKeys` 冲突检测与 ConflictPolicy；活跃维护。`HotKey` 功能太少，直接写 Carbon 要自己做录制与检测 |
| 默认值 ctrl+space | 作为**推荐预填**而非静默 `initial:`；首次启动引导页让用户确认 | 系统「选择上一个输入源」默认占用 ctrl+space；库作者与 Raycast/Alfred 都不建议静默抢键 |
| 冲突处理 | 启动与录制时用 `Shortcut.isTakenBySystem`（或自己调 `CopySymbolicHotKeys`）检测；命中则展示"去 System Settings › Keyboard › Keyboard Shortcuts › Input Sources 关闭，或换键"的说明；`ConflictPolicy.systemShortcut = .warn` | 无 API 能压制系统快捷键；不要改 `com.apple.symbolichotkeys` |
| Quick Panel | `NSPanel` 子类：`.nonactivatingPanel + .borderless`、`canBecomeKey = true`、`level = .floating`、`[.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`、`hidesOnDeactivate = false`、`NSHostingView` 内容、`windowDidResignKey → orderOut`、`.onExitCommand` 处理 Esc、按鼠标所在屏幕居中 | 见 §3 |
| SwiftUI 承载 | `MenuBarExtra` + `Settings` + `LSUIElement = true`；`@NSApplicationDelegateAdaptor` 的 delegate 持有 panel 与 Hotkey 注册 | 见 §4 |
| 不做 | `CGEventTap` / `NSEvent` global monitor；不请求 Accessibility 或 Input Monitoring | 为一个 Hotkey 要权限体验差；且 Screenshot（#3）若需权限应单独评估，不要混在一起 |

## 6. 需要在真机实测的未定项

1. 只有 **1 个输入源**时，系统是否仍吞掉 ctrl+space（Apple 文案 "if you use multiple input sources" 暗示不会，但未明说）。
2. 用户在 System Settings 关闭「选择上一个输入源」后，`CopySymbolicHotKeys` 的 `kHISymbolicHotKeyEnabled` 是否立刻变 false（Alfred 文档提到 "macOS may be reserving it behind the scenes"）。
3. `nonactivatingPanel` + `NSHostingView` 中 SwiftUI `TextField` 的首次焦点（`@FocusState`）是否可靠；panel 成为 key 时前台 app 的 key window 是否保留（预期：前台 app 仍是 active app，但其窗口暂时非 key）。
4. 全屏 app 之上 `.floating` 级别是否足够，不够则试 `.statusBar`/`.popUpMenu`（Apple 只给了级别顺序，没写与全屏的交互）。
5. macOS 26 上 ctrl+space 的输入源切换有已知回退 bug（[FB24297598](https://developer.apple.com/forums/thread/841799)），与本项目无直接关系，但测试时别误判为我们的问题。

## 来源索引

Apple 文档（通过 developer.apple.com 的 JSON 数据端点读取原文）：
- https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
- https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
- https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)
- https://developer.apple.com/documentation/coregraphics/cgeventtapoptions
- https://developer.apple.com/documentation/coregraphics/cgeventtaplocation
- https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()
- https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess()
- https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted
- https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- https://developer.apple.com/documentation/appkit/nspanel
- https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel
- https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded
- https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey
- https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel
- https://developer.apple.com/documentation/appkit/nswindow/canbecomekey
- https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate
- https://developer.apple.com/documentation/appkit/nswindow/isreleasedwhenclosed
- https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct
- https://developer.apple.com/documentation/appkit/nswindow/level-swift.property
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct
- https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront(_:)
- https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless()
- https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidresignkey(_:)
- https://developer.apple.com/documentation/appkit/nswindow/didresignkeynotification
- https://developer.apple.com/documentation/appkit/nsscreen/main
- https://developer.apple.com/documentation/appkit/nsscreen/screens
- https://developer.apple.com/documentation/appkit/nsevent/mouselocation
- https://developer.apple.com/documentation/appkit/nsapplication/activate()
- https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:)
- https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory
- https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:)
- https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)
- https://developer.apple.com/documentation/swiftui/menubarextra
- https://developer.apple.com/documentation/swiftui/menubarextrastyle/window
- https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor
- https://developer.apple.com/documentation/swiftui/nshostingview
- https://developer.apple.com/documentation/swiftui/nshostingcontroller
- https://developer.apple.com/documentation/swiftui/view/onexitcommand(perform:)
- https://developer.apple.com/documentation/swiftui/scene/windowlevel(_:)
- https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings
- https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/WinPanel/Concepts/UsingPanels.html（How Panels Work，archived）

Apple SDK 头文件（Carbon 无在线文档，取 SDK 镜像）：
- HIToolbox/CarbonEvents.h：https://raw.githubusercontent.com/phracker/MacOSX-SDKs/master/MacOSX11.3.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/CarbonEvents.h
- HIToolbox/Events.h：https://raw.githubusercontent.com/phracker/MacOSX-SDKs/master/MacOSX11.3.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h

Apple Support / 论坛：
- https://support.apple.com/102650（Mac keyboard shortcuts）
- https://support.apple.com/guide/mac-help/mchlp1406/mac（Write in another language on Mac）
- https://support.apple.com/guide/mac-help/mchlp2864/mac（Change a conflicting keyboard shortcut on Mac）
- https://developer.apple.com/forums/thread/707680（Apple DTS：global monitor 需 Accessibility，CGEventTap 需 Input Monitoring）
- https://developer.apple.com/forums/thread/676422（Apple DTS：哪些 API 触发 Input Monitoring 提示）
- https://developer.apple.com/forums/thread/122492（社区观察：defaultTap vs listenOnly 权限）
- https://developer.apple.com/forums/thread/841799（FB24297598，AppleSymbolicHotKeys ID 60）

库：
- https://github.com/sindresorhus/KeyboardShortcuts（readme、HotKey.swift、Shortcut.swift、ConflictPolicy.swift、RecorderCocoa.swift、Localizable.strings）
- https://github.com/soffes/HotKey（README、HotKeysController.swift）

产品实践 / 二手：
- https://manual.raycast.com/v1/hotkey
- https://manual.raycast.com/troubleshooting.md（Raycast 要求 Accessibility "needed for hotkeys and snippet expansion"——Raycast 自身走的是更重的路线）
- https://www.alfredapp.com/help/troubleshooting/cmd-space/
- https://pkg.go.dev/github.com/go-macos/hotkey
- https://dev.to/dirtyhenry/command-line-instructions-to-uncheck-select-the-previous-input-source-on-macos-254g
