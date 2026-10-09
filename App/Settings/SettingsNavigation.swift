import Foundation
import Observation

enum SettingsTab: Hashable {
    case general
    case connections
    case advanced
}

/// 设置窗口当前显示哪个标签页，以及 Connection 页要预选的模板。
/// 首次启动、还没有 Connection 时点「添加 Connection…」，都打开 Connection 页并预选 DeepSeek（SPEC §10）。
@MainActor
@Observable
final class SettingsNavigation {
    private static let launchedKey = "hasLaunchedBefore"

    var tab: SettingsTab = .general
    /// Connection 页出现时，用这个模板新建一个草稿，然后清空。
    var pendingTemplate: ConnectionTemplate?
    /// 这次是不是第一次启动 app。
    let isFirstLaunch: Bool
    @ObservationIgnored private var didShowFirstLaunchSettings = false

    init(defaults: UserDefaults = .standard) {
        isFirstLaunch = !defaults.bool(forKey: Self.launchedKey)
        defaults.set(true, forKey: Self.launchedKey)
    }

    func showConnections(template: ConnectionTemplate? = nil) {
        tab = .connections
        pendingTemplate = template
    }

    /// 首次启动时只自动打开一次设置。返回 true 表示这次需要打开。
    func takeFirstLaunchSettings() -> Bool {
        guard isFirstLaunch, !didShowFirstLaunchSettings else { return false }
        didShowFirstLaunchSettings = true
        showConnections(template: .deepSeek)
        return true
    }
}
