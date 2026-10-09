import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 唤起 Quick Panel 的 Hotkey，默认 option+space（SPEC §2.1）。
    static let toggleQuickPanel = Self("toggleQuickPanel", initial: .init(.space, modifiers: [.option]))
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
