import AppKit
import Highlighter
import MarkdownUI
import SwiftUI

/// 用 HighlighterSwift（highlight.js）给代码块着色，接到 MarkdownUI 的 `CodeSyntaxHighlighter`（ARCHITECTURE §8 第 1 条）。
///
/// `CodeSyntaxHighlighter` 的要求不是 MainActor 隔离的，而 Highlighter 只能在 MainActor 上用，所以这里是 isolated conformance。
@MainActor
struct HighlightedCodeSyntaxHighlighter: @MainActor CodeSyntaxHighlighter {
    let colorScheme: ColorScheme

    func highlightCode(_ code: String, language: String?) -> Text {
        guard let highlighted = CodeHighlightCache.shared.highlight(code, language: language, isDark: colorScheme == .dark) else {
            return Text(code)
        }
        return Text(highlighted)
    }
}

/// 深浅色各一个 Highlighter 实例，结果按 (code, language, colorScheme) 缓存。
@MainActor
final class CodeHighlightCache {
    static let shared = CodeHighlightCache()

    private struct Key: Hashable {
        let code: String
        let language: String
        let isDark: Bool
    }

    /// 流式生成时，未完成的代码块每次都不一样，缓存会涨得快，超过上限就整个清掉。
    private static let maxEntries = 256

    private var highlighters: [Bool: Highlighter] = [:]
    private var cache: [Key: AttributedString] = [:]

    /// 没有标注语言或语言不认识时返回 nil，按纯文本显示（不做自动检测，太慢）。
    func highlight(_ code: String, language: String?, isDark: Bool) -> AttributedString? {
        guard let language = language?.trimmingCharacters(in: .whitespaces).lowercased(), !language.isEmpty else {
            return nil
        }
        let key = Key(code: code, language: language, isDark: isDark)
        if let cached = cache[key] { return cached }

        guard
            let highlighter = highlighter(isDark: isDark),
            let result = highlighter.highlight(code, as: language, doFastRender: true, lineNumbering: nil)
        else {
            return nil
        }
        let highlighted = Self.foregroundColorsOnly(result)
        if cache.count >= Self.maxEntries { cache.removeAll() }
        cache[key] = highlighted
        return highlighted
    }

    private func highlighter(isDark: Bool) -> Highlighter? {
        if let existing = highlighters[isDark] { return existing }
        guard let highlighter = Highlighter() else { return nil }
        _ = highlighter.setTheme(isDark ? "atom-one-dark" : "atom-one-light")
        highlighters[isDark] = highlighter
        return highlighter
    }

    /// 只保留前景色；字体和字号交给 Markdown 主题。
    private static func foregroundColorsOnly(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        source.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            var run = AttributedString(source.attributedSubstring(from: range).string)
            if let color = value as? NSColor {
                run.swiftUI.foregroundColor = Color(nsColor: color)
            }
            result += run
        }
        return result
    }
}
