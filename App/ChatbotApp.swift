import SwiftUI

@main
struct ChatbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(history: appDelegate.historyModel)
        } label: {
            MenuBarLabel(store: appDelegate.chatStore, history: appDelegate.historyModel)
        }

        Window("Chatbot", id: AppWindow.mainWindowID) {
            MainWindowView(model: appDelegate.historyModel, chat: appDelegate.chatStore)
        }
        .defaultSize(width: 900, height: 620)
        // 启动时不自动打开，只从菜单栏或 Quick Panel 打开
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(store: appDelegate.chatStore)
        }
    }
}

/// 菜单栏图标的菜单：打开主窗口、设置、退出（SPEC §1）。
private struct StatusMenu: View {
    let history: HistoryModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Main Window") {
            history.reload()
            AppWindow.openMainWindow(with: openWindow)
        }
        Button("Settings…") {
            AppWindow.openSettings(with: openSettings)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Chatbot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// 菜单栏图标。顺便把打开设置和主窗口的动作交给 store：Quick Panel 在 NSHostingView 里，拿不到场景的环境值。
private struct MenuBarLabel: View {
    let store: ChatStore
    let history: HistoryModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarIcon(state: store.menuBarState)
            .onAppear {
                let openSettings = openSettings
                let openWindow = openWindow
                store.openSettings = { AppWindow.openSettings(with: openSettings) }
                store.openMainWindow = { [history] conversationID in
                    history.select(conversationID)
                    AppWindow.openMainWindow(with: openWindow)
                }
            }
    }
}

/// 打开 app 的普通窗口并带到最前面。
///
/// 从 macOS 14 开始 `NSApp.activate()` 是协作式的，不保证激活；从不激活 app 的 Quick Panel 里打开窗口时，
/// 它可能出现在别的 app 后面。所以打开后再找到它，强制前置并设为 key。
@MainActor
enum AppWindow {
    static let mainWindowID = "main"

    static func openSettings(with openSettings: OpenSettingsAction) {
        NSApp.activate()
        openSettings()
        bringToFront { $0.identifier?.rawValue.contains("Settings") == true }
    }

    static func openMainWindow(with openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: mainWindowID)
        bringToFront { $0.identifier?.rawValue.hasPrefix(mainWindowID) == true }
    }

    /// 先按 identifier 找；SwiftUI 的窗口命名是内部细节，找不到时退而求其次，
    /// 取最前面的一个可见普通窗口（刚打开的窗口通常就在最前面）。
    private static func bringToFront(where matches: @escaping @MainActor (NSWindow) -> Bool) {
        Task {
            // 窗口在 open 之后的下一轮才创建
            try? await Task.sleep(for: .milliseconds(100))
            let window = NSApp.windows.first(where: { matches($0) })
                ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) })
            guard let window else { return }
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}
