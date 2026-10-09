import Foundation

/// 新 Conversation 的地球按钮默认开还是关（SPEC §5、#68）。在设置的通用页修改，存在 UserDefaults，默认关。
enum WebSearchDefault {
    static let defaultsKey = "webSearchOnByDefault"

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
