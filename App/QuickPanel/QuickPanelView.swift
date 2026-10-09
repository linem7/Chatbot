import SwiftUI

/// Quick Panel 的内容，按 #15 选定的「聊天窗式」：顶栏、消息区、输入区（SPEC §2.2）。
struct QuickPanelView: View {
    @Bindable var store: ChatStore
    let composer: ComposerHandle

    var body: some View {
        VStack(spacing: 0) {
            QuickPanelHeader(store: store)
            Divider()
            EmptyConversationView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ComposerView(store: store, composer: composer)
                .padding([.horizontal, .bottom], 10)
        }
    }
}

private struct QuickPanelHeader: View {
    let store: ChatStore

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(store.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                store.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("New Conversation (⌘N)")
            .disabled(store.isGenerating)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
    }
}

private struct EmptyConversationView: View {
    var body: some View {
        Text("What can I help with?")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
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
            ZStack(alignment: .topLeading) {
                if store.draft.isEmpty {
                    Text("Ask anything")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $store.draft, contentHeight: $contentHeight, handle: composer) {
                    store.send()
                }
                .frame(height: min(max(contentHeight, Self.lineHeight), Self.maxHeight))
            }
            HStack(spacing: 8) {
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
