import Foundation

/// system prompt（SPEC §3）。用户可以在设置的高级页修改，也可以恢复默认，存在 UserDefaults。
///
/// 当前日期不在可编辑的文本里：发送时由 app 加在最前面，这样用户改了 prompt 也不会把日期弄丢。
enum SystemPrompt {
    static let defaultsKey = "systemPrompt"

    static let defaultText = """
        You are a concise assistant that helps the user solve problems quickly.
        Reply in the user's language. Use Markdown when it helps readability.
        If you are not sure about something or could not find it, say so plainly instead of making things up.
        When you search the web, cite your sources.
        """

    /// 用户的文本；没改过时是默认文本。
    static func text(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey) ?? defaultText
    }

    /// 发给模型的 system prompt：最前面一行是当前日期，后面是用户的文本。
    static func forRequest(now: Date = .now, defaults: UserDefaults = .standard) -> String {
        let date = now.formatted(.iso8601.year().month().day())
        let text = text(in: defaults).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Today is \(date)." : "Today is \(date).\n\n\(text)"
    }
}
