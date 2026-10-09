import SwiftUI

@main
struct ChatbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Chatbot", systemImage: "bubble.left.and.text.bubble.right") {
            Button("Quit Chatbot") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Settings {
            EmptyView()
        }
    }
}
