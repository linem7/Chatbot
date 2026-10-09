import SwiftUI

@main
struct ChatbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Quit Chatbot") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarIcon(state: appDelegate.chatStore.menuBarState)
        }

        Settings {
            EmptyView()
        }
    }
}
