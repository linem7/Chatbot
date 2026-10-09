import AppKit

/// Quick Panel 的窗口：不激活 app 的浮动面板。配置见 `QuickPanelController`。
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 面板不激活 app，key equivalent 不一定能走到主菜单，所以编辑命令在这里直接发给响应链。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector? = switch (modifiers, event.charactersIgnoringModifiers) {
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"), ([.command, .shift], "Z"): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}
