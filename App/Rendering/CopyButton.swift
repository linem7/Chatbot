import AppKit
import SwiftUI

/// 把文字复制到剪贴板，之后短暂显示「已复制」。
struct CopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Label(didCopy ? LocalizedStringKey("Copied") : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
