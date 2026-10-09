import ChatbotCore
import SwiftUI

/// Main Window：左边是历史列表和搜索，右边是选中 Conversation 的完整内容（SPEC §8）。
struct MainWindowView: View {
    @Bindable var model: HistoryModel
    let chat: ChatStore

    var body: some View {
        NavigationSplitView {
            ConversationList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let conversation = model.selectedConversation {
                ConversationDetail(
                    conversation: conversation,
                    messages: model.selectedMessages,
                    attachments: model.selectedAttachments,
                    chat: chat
                ) {
                    model.continueInQuickPanel(conversation.id)
                }
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(StaysVisibleWhenInactive())
        .task { model.reload() }
        .onChange(of: chat.historyRevision) { model.reload() }
    }
}

private struct ConversationList: View {
    @Bindable var model: HistoryModel

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(model.conversations) { conversation in
                ConversationListRow(conversation: conversation)
                    .tag(conversation.id)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button("Continue in Quick Panel") { model.continueInQuickPanel(id) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(id) }
            }
        } primaryAction: { ids in
            // 双击：回到 Quick Panel 继续
            if let id = ids.first { model.continueInQuickPanel(id) }
        }
        .onDeleteCommand {
            if let id = model.selectedID { model.delete(id) }
        }
        .searchable(text: $model.query, placement: .sidebar)
        .overlay {
            if model.conversations.isEmpty {
                if model.query.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
    }
}

private struct ConversationListRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ConversationTitle(conversation: conversation)
                .lineLimit(1)
            Text(conversation.lastMessageAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ConversationTitle: View {
    let conversation: Conversation

    var body: some View {
        if conversation.title.isEmpty {
            Text("Untitled")
        } else {
            Text(verbatim: conversation.title)
        }
    }
}

private struct ConversationDetail: View {
    let conversation: Conversation
    let messages: [Message]
    let attachments: [UUID: Attachment]
    let chat: ChatStore
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        MessageRow(message: message, attachments: message.attachmentIDs.compactMap { attachments[$0] })
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            Divider()
            HStack {
                Text(verbatim: modelLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Continue in Quick Panel", action: onContinue)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
        .navigationTitle(conversation.title.isEmpty ? String(localized: "Untitled") : conversation.title)
    }

    /// 「Connection / Model」。Connection 已经删除时只显示 Model。
    private var modelLabel: String {
        guard let connection = chat.connections.connection(id: conversation.connectionID) else {
            return conversation.modelID
        }
        return "\(connection.name) / \(conversation.modelID)"
    }
}
