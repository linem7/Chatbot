/// ChatbotCore：不依赖 UI 的核心逻辑，可以用 `swift test` 单独测试。
/// 目录划分见 docs/ARCHITECTURE.md §2。
public enum ChatbotCore {
    /// app 的 bundle id。Application Support 下的数据目录和 Keychain 的 service 都以它命名。
    public static let bundleIdentifier = "com.linem7.Chatbot"
}
