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

/// 输入框用的 NSTextView。
///
/// - 进入窗口时，补上之前没做成的聚焦（#33）。
/// - 粘贴和拖放时先看是不是附件（SPEC §4）：
///   - 剪贴板里有文件（Finder 里复制的文件）→ 附件；
///   - 有文字 → 照常粘贴文字（从网页复制的图文混排也按文字处理）；
///   - 只有图片数据（截图工具复制的图片）→ 附件。
final class ComposerNSTextView: NSTextView {
    weak var handle: ComposerHandle?
    var onAttachFiles: (([URL]) -> Void)?
    var onAttachImage: ((Data) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let handle, handle.pendingFocus else { return }
        handle.pendingFocus = false
        window.makeFirstResponder(self)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = Self.fileURLs(in: pasteboard), !urls.isEmpty {
            onAttachFiles?(urls)
            return
        }
        if pasteboard.string(forType: .string) == nil, let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            onAttachImage?(image)
            return
        }
        super.paste(sender)
    }

    /// 文件拖到输入框上时作为附件，不插入文件路径。拖到面板其他地方的由 SwiftUI 的 dropDestination 处理。
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = Self.fileURLs(in: sender.draggingPasteboard), !urls.isEmpty {
            onAttachFiles?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
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
    /// 粘贴或拖进来的文件（Finder 里复制的文件、拖到输入框上的文件）。
    var onAttachFiles: ([URL]) -> Void = { _ in }
    /// 粘贴的图片数据（截图工具复制的图片）。
    var onAttachImage: (Data) -> Void = { _ in }

    static let font = NSFont.systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.handle = handle
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onAttachFiles = { [weak coordinator] in coordinator?.parent.onAttachFiles($0) }
        textView.onAttachImage = { [weak coordinator] in coordinator?.parent.onAttachImage($0) }
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
