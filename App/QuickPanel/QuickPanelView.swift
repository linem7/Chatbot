import ChatbotCore
import SwiftUI

/// Quick Panel 的内容，按 #15 选定的「聊天窗式」：顶栏、消息区、输入区（SPEC §2.2）。
struct QuickPanelView: View {
    @Bindable var store: ChatStore
    let composer: ComposerHandle

    var body: some View {
        VStack(spacing: 0) {
            QuickPanelHeader(store: store)
            Divider()
            if store.hasConnection {
                Group {
                    if store.messages.isEmpty {
                        EmptyConversationView(notice: store.notice)
                    } else {
                        MessageList(messages: store.messages, attachments: store.attachmentsByID, notice: store.notice)
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
                store.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("New Conversation (⌘N)")
        }
        .frame(maxWidth: .infinity)
        .overlay {
            // 标题居中于整个顶栏，不受两侧宽度影响
            Text(store.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 210)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
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
                            if model.capabilities.imageInput { Image(systemName: "photo") }
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

    var body: some View {
        VStack(spacing: 10) {
            Text("What can I help with?")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            if let notice { NoticeText(text: notice) }
        }
    }
}

/// 消息列表。内容增长时保持贴在底部。
private struct MessageList: View {
    let messages: [Message]
    /// 已经发出的附件，用户消息按 `attachmentRef` 查这里显示。
    let attachments: [UUID: Attachment]
    let notice: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(messages) { message in
                    MessageRow(message: message, attachments: message.attachmentIDs.compactMap { attachments[$0] })
                }
                if let notice { NoticeText(text: notice) }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}

private struct MessageRow: View {
    let message: Message
    let attachments: [Attachment]

    var body: some View {
        switch message.role {
        case .user:
            UserMessageBubble(text: message.markdownText, attachments: attachments)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.status == .streaming && message.content.isEmpty {
                    TypingIndicator()
                } else {
                    AssistantMessageView(markdown: message.markdownText, isStreaming: message.status == .streaming)
                        .equatable()
                }
                switch message.status {
                case .interrupted:
                    NoticeText(text: String(localized: "Interrupted"))
                case .failed(let error):
                    NoticeText(text: error.displayText)
                case .streaming, .complete:
                    EmptyView()
                }
            }
        }
    }
}

private struct NoticeText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }
}

private struct TypingIndicator: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tertiary)
            .symbolEffect(.variableColor.iterative)
            .padding(.vertical, 4)
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
