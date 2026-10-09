import AppKit
import ChatbotCore
import SwiftUI

/// Quick Panel 的内容，按 #15 选定的「聊天窗式」：顶栏、消息区、输入区（SPEC §2.2）。
struct QuickPanelView: View {
    @Bindable var store: ChatStore
    let composer: ComposerHandle

    /// 最后一条回答中断或出错时，它下面的操作按钮（SPEC §7）。
    private var lastAnswerActions: AnswerActionHandler? {
        guard store.lastAnswerNeedsAction else { return nil }
        return AnswerActionHandler { [store] action in
            switch action {
            case .openSettings: store.openSettingsForCurrentConnection()
            case .retry: store.retry()
            case .newConversation: store.newConversation()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            QuickPanelHeader(store: store)
            Divider()
            if store.hasConnection {
                Group {
                    if store.messages.isEmpty {
                        EmptyConversationView(notice: store.notice, openSettings: store.openSettingsForCurrentConnection)
                    } else {
                        MessageList(
                            messages: store.messages,
                            attachments: store.attachmentsByID,
                            lastAnswerActions: lastAnswerActions,
                            notice: store.notice,
                            openSettings: store.openSettingsForCurrentConnection
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ComposerView(store: store, composer: composer)
                    .padding([.horizontal, .bottom], 10)
            } else {
                // 还没有任何 Connection 时，面板里只显示「添加 Connection」（SPEC §10）
                Button("Add Connection…") { store.openSettings() }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 文件拖到面板任何地方都作为附件（拖到输入框上的由 ComposerNSTextView 处理）
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard store.hasConnection, !files.isEmpty else { return false }
            store.addAttachments(fromFiles: files)
            return true
        }
    }
}

private struct QuickPanelHeader: View {
    let store: ChatStore

    var body: some View {
        HStack(spacing: 8) {
            ModelPicker(store: store)
                .frame(width: 190, alignment: .leading)
            Spacer(minLength: 0)
            Button {
                store.togglePanelPinned()
            } label: {
                Image(systemName: store.isPanelPinned ? "pin.fill" : "pin")
                    .foregroundStyle(store.isPanelPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help(store.isPanelPinned
                ? "Unpin: hide the panel when it loses focus"
                : "Pin: keep the panel in front of other windows")
            Button {
                store.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("New Conversation (⌘N)")
            Button {
                store.openInMainWindow()
            } label: {
                Image(systemName: "macwindow")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Open in Main Window")
            .disabled(!store.canOpenInMainWindow)
        }
        .frame(maxWidth: .infinity)
        .overlay {
            // 标题居中于整个顶栏，不受两侧宽度影响
            Text(store.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 210)
                // 标题压在拖动手柄上，别把鼠标事件吃掉（#63）
                .allowsHitTesting(false)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
        // 顶栏的空当兼作拖动手柄（#63）。放在 background 里：NSView 没有固有高度，直接塞进 HStack
        // 会在竖直方向被拉伸，把顶栏撑得很高。按钮盖在上面照常接点按，点到空当才落到这里
        .background { HeaderDragArea { store.hasMovedPanel = true } }
    }
}

/// 顶栏上按住就能拖动 Quick Panel 的区域（#63）。
///
/// 面板是 `.borderless` 的无边框窗口，系统不给标题栏，所以自己接住 `mouseDown` 交给
/// `NSWindow.performDrag(with:)`，剩下的交给系统。只有这一处能拖：消息区、输入框的选字和点按都不受影响
/// （`isMovableByWindowBackground` 保持 false）。
private struct HeaderDragArea: NSViewRepresentable {
    /// 拖动开始时回调一次，用来记下「面板被拖过了」（SPEC §2.2）。
    let onDragStart: () -> Void

    func makeNSView(context: Context) -> NSView { DragView(onDragStart: onDragStart) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        private let onDragStart: () -> Void

        init(onDragStart: @escaping () -> Void) {
            self.onDragStart = onDragStart
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseDown(with event: NSEvent) {
            onDragStart()
            window?.performDrag(with: event)
        }

        // 整条顶栏空当都是拖动区，鼠标移上去给个能抓的手型，比无边框窗口默认的箭头好认
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// 顶栏左侧的模型选择器，显示「Connection / Model」，按 Connection 分组。
private struct ModelPicker: View {
    let store: ChatStore

    var body: some View {
        Menu {
            ForEach(store.connections.connections) { connection in
                Section(connection.name) {
                    ForEach(store.connections.visibleModels(of: connection)) { model in
                        Button {
                            store.selectModel(ModelRef(connectionID: connection.id, modelID: model.id))
                        } label: {
                            Text(verbatim: model.displayName ?? model.id)
                            // 能力按 Connection 算：OpenRouter、百炼上的 Model 都能联网（ADR-0003）
                            let capabilities = connection.capabilities(ofModel: model.id)
                            if capabilities.imageInput { Image(systemName: "photo") }
                            if capabilities.webSearch { Image(systemName: "globe") }
                        }
                    }
                }
            }
        } label: {
            Text(verbatim: label)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var label: String {
        guard let model = store.currentModel, let connection = store.connections.connection(id: model.connectionID) else {
            return "—"
        }
        return "\(connection.name) / \(model.modelID)"
    }
}

private struct EmptyConversationView: View {
    let notice: String?
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("What can I help with?")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            if let notice { SendNotice(text: notice, openSettings: openSettings) }
        }
    }
}

/// 发送前的问题（目前都和 API key 有关），旁边给「打开设置」。
private struct SendNotice: View {
    let text: String
    let openSettings: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NoticeText(text: text)
            AnswerActionButton(action: .openSettings, isPrimary: true) { openSettings() }
        }
    }
}

/// 消息列表。内容增长时保持贴在底部。
private struct MessageList: View {
    let messages: [Message]
    /// 已经发出的附件，用户消息按 `attachmentRef` 查这里显示。
    let attachments: [UUID: Attachment]
    /// 只给最后一条回答。
    let lastAnswerActions: AnswerActionHandler?
    let notice: String?
    let openSettings: @MainActor () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(messages) { message in
                    MessageRow(
                        message: message,
                        attachments: message.attachmentIDs.compactMap { attachments[$0] },
                        actions: message.id == messages.last?.id ? lastAnswerActions : nil
                    )
                }
                if let notice { SendNotice(text: notice, openSettings: openSettings) }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}

/// 输入区：多行输入框和工具行。
private struct ComposerView: View {
    @Bindable var store: ChatStore
    let composer: ComposerHandle
    @State private var contentHeight: CGFloat = 0

    private static let lineHeight = ceil(ComposerTextView.font.boundingRectForFont.height)
    private static let maxHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = store.attachmentNotice ?? store.imageNotAcceptedWarning {
                Text(verbatim: notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if !store.draftAttachments.isEmpty {
                DraftAttachmentStrip(attachments: store.draftAttachments, remove: store.removeDraftAttachment(id:))
            }
            ZStack(alignment: .topLeading) {
                if store.draft.isEmpty {
                    Text("Ask anything")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $store.draft,
                    contentHeight: $contentHeight,
                    handle: composer,
                    onSubmit: { store.send() },
                    onAttachFiles: { store.addAttachments(fromFiles: $0) },
                    onAttachImage: { store.addAttachment(imageData: $0) }
                )
                .frame(height: min(max(contentHeight, Self.lineHeight), Self.maxHeight))
            }
            HStack(spacing: 8) {
                Button {
                    store.presentFilePicker()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("Add Files…")
                WebSearchButton(store: store)
                Spacer(minLength: 0)
                Text("⏎ Send · ⇧⏎ New Line")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                SendButton(isGenerating: store.isGenerating, canSend: store.canSend, send: store.send, stop: store.stop)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 10))
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SendButton: View {
    let isGenerating: Bool
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void

    var body: some View {
        Button {
            if isGenerating { stop() } else { send() }
        } label: {
            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(isGenerating ? AnyShapeStyle(.primary) : canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isGenerating && !canSend)
        .help(isGenerating ? LocalizedStringKey("Stop (⌘.)") : "Send (⏎)")
    }
}

/// 输入区上方的附件缩略图条：图片显示缩略图，文件显示图标和文件名，每个都有 × 可以删除（SPEC §2.2）。
private struct DraftAttachmentStrip: View {
    let attachments: [DraftAttachment]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { draft in
                    AttachmentChip(name: draft.name, attachment: draft.attachment)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                remove(draft.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                            .offset(x: 5, y: -5)
                        }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }
}

/// 地球按钮：对当前 Conversation 开关 Web Search。Model 不支持搜索时置灰（SPEC §5）。
private struct WebSearchButton: View {
    let store: ChatStore

    var body: some View {
        let supported = store.currentModelSupportsWebSearch
        let isOn = store.isWebSearchOn
        Button {
            store.setWebSearchEnabled(!isOn)
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .disabled(!supported)
        .help(!supported ? LocalizedStringKey("The current model doesn't support web search.") : isOn ? "Web Search: On" : "Web Search: Off")
    }
}
