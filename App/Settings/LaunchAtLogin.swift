import Observation
import ServiceManagement
import os

/// 开机启动（SPEC §9），用 `SMAppService.mainApp`。默认开启：首次启动时注册。
///
/// 注册时 macOS 会弹一条「已添加后台项目」的系统通知，这是系统行为，app 关不掉。
@MainActor
@Observable
final class LaunchAtLogin {
    private static let logger = Logger(subsystem: "com.linem7.Chatbot", category: "LaunchAtLogin")

    private(set) var status = SMAppService.mainApp.status

    var isEnabled: Bool { status == .enabled }
    /// 已经注册，但用户需要在「系统设置 › 通用 › 登录项」里允许。
    var requiresApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.logger.error("Couldn't change launch at login: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
