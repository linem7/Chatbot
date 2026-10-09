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
            SettingsWindow.open(with: openSettings)
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
                store.openSettings = { SettingsWindow.open(with: openSettings) }
            }
    }
}

/// 打开设置窗口并带到最前面。
///
/// 从 macOS 14 开始 `NSApp.activate()` 是协作式的，不保证激活；从不激活 app 的 Quick Panel 里点
/// 「添加 Connection…」时，设置窗口可能出现在别的 app 后面。所以打开后再找到它，强制前置并设为 key。
@MainActor
enum SettingsWindow {
    static func open(with openSettings: OpenSettingsAction) {
        NSApp.activate()
        openSettings()
        Task {
            // 设置窗口在 openSettings() 之后的下一轮才创建
            try? await Task.sleep(for: .milliseconds(100))
            guard let window = NSApp.windows.first(where: isSettingsWindow) else { return }
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    /// SwiftUI 设置窗口的 identifier；找不到时退而求其次，取一个可见的普通窗口（app 这时只有设置窗口是普通窗口）。
    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" { return true }
        return window.isVisible && window.canBecomeMain && !(window is NSPanel)
    }
}
