import AppKit
import SwiftUI

/// 让面板控制器能把焦点放进输入框。
@MainActor
final class ComposerHandle {
    fileprivate weak var textView: NSTextView?
    /// 要求聚焦时输入框还没创建或还不在窗口里，等它进入窗口时再补一次。
    fileprivate var pendingFocus = false

    func focus() {
        guard let textView, let window = textView.window else {
            pendingFocus = true
            return
        }
        pendingFocus = false
        window.makeFirstResponder(textView)
    }
}

/// 输入框用的 NSTextView。进入窗口时，补上之前没做成的聚焦。
final class ComposerNSTextView: NSTextView {
    weak var handle: ComposerHandle?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let handle, handle.pendingFocus else { return }
        handle.pendingFocus = false
        window.makeFirstResponder(self)
    }
}

/// Quick Panel 的输入框。用 NSTextView 而不是 SwiftUI 的 TextEditor，原因有两个：
/// - ⏎ 发送、⇧⏎ 换行，并且输入法正在组字时按 ⏎ 不发送（组字时 ⏎ 由输入法消费，不会走到 `doCommandBy`）；
/// - 面板显示时可以直接 `makeFirstResponder`。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// 文字内容的高度，由外层决定显示多高。
    @Binding var contentHeight: CGFloat
    let handle: ComposerHandle
    let onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.handle = handle
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        handle.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            context.coordinator.updateContentHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateContentHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func updateContentHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
                return
            }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height)
            guard height != parent.contentHeight else { return }
            // 不在视图更新过程中直接改 SwiftUI 状态。
            Task { @MainActor in
                self.parent.contentHeight = height
            }
        }
    }
}
