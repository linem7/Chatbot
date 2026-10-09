import AppKit
import ApplicationServices
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    /// 唤起 Quick Panel 的 Hotkey，默认 option+space（SPEC §2.1）。
    static let toggleQuickPanel = Self("toggleQuickPanel", initial: .init(.space, modifiers: [.option]))
}

/// 唤起 Quick Panel 的方式（SPEC §2.1、#64）。
enum HotkeyTrigger: String, CaseIterable, Identifiable {
    /// 一个按键组合，用 KeyboardShortcuts 注册（底层是 Carbon，不需要权限）。
    case shortcut
    /// 连按两次 ⌘。要读全系统的修饰键状态，需要「辅助功能」权限。
    case doubleCommand

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .shortcut: "Key combination"
        case .doubleCommand: "Press ⌘ twice"
        }
    }
}

/// Hotkey 的注册（SPEC §2.1）。按用户选的方式，要么注册一个组合键，要么盯着全局的 ⌘ 双击；
/// 两种不会同时生效，免得同一个动作触发两次。
///
/// 默认的组合键不需要任何系统权限；换成 ⌘ 双击之后需要「辅助功能」权限，没给之前组合键继续可用，
/// 免得用户既唤不起面板、又不知道为什么。
@MainActor
@Observable
final class HotkeyController {
    private static let triggerKey = "hotkeyTrigger"
    /// `kAXTrustedCheckOptionPrompt` 在 Swift 6 里是个全局 var，直接引用不算并发安全（#64 编译时撞到过）。
    /// 它的值就是这个固定不变的字符串，直接写出来。
    private static let promptOption = "AXTrustedCheckOptionPrompt"

    private let defaults: UserDefaults
    private var monitor: DoubleCommandMonitor?
    private var onToggle: (() -> Void)?

    private(set) var trigger: HotkeyTrigger
    /// 「辅助功能」权限有没有给。只有 ⌘ 双击需要它。
    private(set) var isTrusted = AXIsProcessTrusted()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        trigger = defaults.string(forKey: Self.triggerKey).flatMap(HotkeyTrigger.init(rawValue:)) ?? .shortcut
    }

    /// 接上切换面板的动作，并按当前选择注册。app 启动时调一次。
    func start(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        apply()
    }

    /// 设置里换了方式。
    func select(_ trigger: HotkeyTrigger) {
        guard trigger != self.trigger else { return }
        self.trigger = trigger
        defaults.set(trigger.rawValue, forKey: Self.triggerKey)
        apply(promptForPermission: true)
    }

    /// app 回到前台时调一次：用户可能刚在 System Settings 里把开关打开。
    func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        // 权限刚给上，⌘ 双击这才真的能用了
        if trigger == .doubleCommand { apply() }
    }

    /// 弹系统的授权提示，提示里自带打开 System Settings 的按钮。
    func requestPermission() {
        let options = [Self.promptOption: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func apply(promptForPermission: Bool = false) {
        monitor?.stop()
        monitor = nil

        guard trigger == .doubleCommand, isTrusted else {
            KeyboardShortcuts.enable(.toggleQuickPanel)
            if trigger == .doubleCommand, promptForPermission { requestPermission() }
            return
        }

        KeyboardShortcuts.disable(.toggleQuickPanel)
        let monitor = DoubleCommandMonitor { [weak self] in self?.onToggle?() }
        monitor.start()
        self.monitor = monitor
    }
}

/// 「连按两次 ⌘」的检测（SPEC §2.1、#64）。
///
/// 修饰键没有单独的按下事件，只能从 `flagsChanged` 推断：⌘ 的 keyCode 是 54（右）和 55（左），
/// 事件之后 flags 里带着 `.command` 就是按下了。两次按下之间混进别的键（⌘C 之类）或别的修饰键就作废，
/// 不然连着复制两次也会被当成唤起。
///
/// 全局监视器只看得到别的 app 的按键，本地的只看得到自己的，所以两边都装——面板开着的时候也要能双击收起。
@MainActor
final class DoubleCommandMonitor {
    /// 两次按下的最大间隔。
    private static let interval: TimeInterval = 0.35
    private static let commandKeyCodes: Set<UInt16> = [54, 55]
    /// 判断「按下的是一记干净的 ⌘」时看这些修饰键，大小写锁定和 fn 不算数。
    private static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private let onTrigger: () -> Void
    private var monitors: [Any] = []
    private var lastPress: Date?

    init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }

    func start() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        lastPress = nil
    }

    private func handle(_ event: NSEvent) {
        guard Self.commandKeyCodes.contains(event.keyCode) else {
            // 别的键或别的修饰键动过，这一轮到此为止
            lastPress = nil
            return
        }
        // ⌘ 抬手：不动计时，否则每次双击都会被自己的抬手清掉
        guard event.modifierFlags.contains(.command) else { return }
        // 按下 ⌘ 时还带着 ⇧⌥⌃，不算一记干净的按下
        guard event.modifierFlags.intersection(Self.relevant) == .command else {
            lastPress = nil
            return
        }

        let now = Date()
        if let last = lastPress, now.timeIntervalSince(last) <= Self.interval {
            lastPress = nil
            onTrigger()
        } else {
            lastPress = now
        }
    }
}

/// Hotkey 的冲突检测（SPEC §2.1）。
///
/// 只能检测和系统快捷键的冲突。其他 app 用 Carbon 注册的同一组合检测不到，
/// 所以在设置里 Hotkey 旁边放一句静态提示 `otherAppsHint`。
enum Hotkey {
    static let otherAppsHint: LocalizedStringResource =
        "If nothing happens when you press the Hotkey, it may conflict with another app such as ChatGPT. Try a different combination."

    private static let lastWarnedKey = "hotkeyConflictWarnedShortcut"

    /// 当前 Hotkey 和一个已启用的系统快捷键相同时弹窗提示。同一个组合只提示一次。
    @MainActor
    static func warnIfTakenBySystem() {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleQuickPanel) else { return }
        let defaults = UserDefaults.standard
        guard shortcut.isTakenBySystem else {
            defaults.removeObject(forKey: lastWarnedKey)
            return
        }
        guard defaults.string(forKey: lastWarnedKey) != shortcut.description else { return }
        defaults.set(shortcut.description, forKey: lastWarnedKey)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Hotkey \(shortcut.description) is used by macOS")
        alert.informativeText = String(localized: "Pressing it won't open the Quick Panel. Turn off that shortcut in System Settings › Keyboard › Keyboard Shortcuts, or choose another Hotkey in Chatbot's settings.")
        NSApp.activate()
        alert.runModal()
    }
}
