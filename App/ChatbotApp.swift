import SwiftUI

@main
struct ChatbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu()
        } label: {
            MenuBarLabel(store: appDelegate.chatStore)
        }

        Settings {
            SettingsView(store: appDelegate.chatStore)
        }
    }
}

/// 菜单栏图标的菜单（SPEC §1）。「打开主窗口」在 #20 里加。
private struct StatusMenu: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Chatbot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// 菜单栏图标。顺便把打开设置的动作交给 store：Quick Panel 在 NSHostingView 里，拿不到场景的 `openSettings`。
private struct MenuBarLabel: View {
    let store: ChatStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarIcon(state: store.menuBarState)
            .onAppear {
                let openSettings = openSettings
                store.openSettings = {
                    NSApp.activate()
                    openSettings()
                }
            }
    }
}
