import Foundation

/// 把 OpenAI 格式的 `url_citation`（OpenRouter 的联网引用）换算成这次调用正文里的 UTF-16 范围（半开区间，和 `CitationSpan` 一致）。
///
/// `start_index`、`end_index` 的单位文档没说，`end_index` 也可能是闭区间（research §1.4），所以不直接用。
/// 和 Gemini 的 `GroundingLocator` 一样，用正文里的文字定位。角标插在范围结尾，所以结尾必须是能安全插入的位置：
/// 不能在 Markdown 链接语法中间，也不能紧跟在裸 URL 后面（GFM 的扩展自动链接会把角标一起吞进链接，
/// 中文回答里「来源：https://…。」这种 URL 后面直接跟中文标点的写法尤其常见）。
///
/// 1. 正文里有这条来源的 URL，并且是链接语法 `[标题](URL)`、`[标题](<URL>)` 或 `<URL>`：
///    取离 `start_index` 最近的一处，范围从 `[`（或 `<`）到链接语法结束。URL 后面必须紧跟 `)` 或 `>`，
///    所以来源是 `/x`、正文里是 `/x/y` 时不会命中。
/// 2. 否则把偏移按 UTF-16、Unicode 标量、UTF-8 字节，各自按半开和闭区间试一遍：切出来的文字含有来源域名，
///    并且结尾是安全的插入位置，就用它。裸 URL 只能走这一层，结尾落在裸 URL 上的都不要。
/// 3. 都不行就不给范围：来源仍然出现在回答末尾的来源列表里，只是不在正文里标角标。
enum URLCitationLocator {
    static func range(start: Int?, end: Int?, url: String, in text: String) -> Range<Int>? {
        let utf16 = Array(text.utf16)
        if let link = linkRange(of: url, near: start ?? 0, in: utf16) { return link }

        guard let start, let end, start >= 0, end >= start,
              let host = URL(string: url)?.host()?.lowercased().replacingOccurrences(of: "www.", with: "")
        else { return nil }
        let offsets = Offsets(text)
        let candidates = [
            offsets.utf16Range(start..<end, count: utf16.count),
            offsets.utf16Range(start..<(end + 1), count: utf16.count),
            offsets.scalarRange(start..<end),
            offsets.scalarRange(start..<(end + 1)),
            offsets.utf8Range(start..<end),
            offsets.utf8Range(start..<(end + 1)),
        ]
        for case let candidate? in candidates
        where String(decoding: utf16[candidate], as: UTF16.self).lowercased().contains(host)
            && isSafeInsertionPoint(candidate.upperBound, in: utf16) {
            return candidate
        }
        return nil
    }

    // MARK: 第 1 层：链接语法

    /// 正文里离 hint 最近的一处链接语法里的 URL，范围覆盖整个链接语法。
    private static func linkRange(of url: String, near hint: Int, in utf16: [UInt16]) -> Range<Int>? {
        let needle = Array(url.utf16)
        guard !needle.isEmpty, needle.count <= utf16.count else { return nil }
        var best: Range<Int>?
        var bestDistance = Int.max
        for offset in 0...(utf16.count - needle.count) where utf16[offset..<(offset + needle.count)].elementsEqual(needle) {
            guard let link = linkSyntax(around: offset..<(offset + needle.count), in: utf16) else { continue }
            if abs(link.lowerBound - hint) < bestDistance {
                best = link
                bestDistance = abs(link.lowerBound - hint)
            }
        }
        return best
    }

    /// URL 两边是 `](…)`、`](<…>)` 或 `<…>` 时，返回整个链接语法的范围；否则（裸 URL、URL 只是更长 URL 的一部分）返回 nil。
    private static func linkSyntax(around url: Range<Int>, in utf16: [UInt16]) -> Range<Int>? {
        func matches(_ string: String, at offset: Int) -> Bool {
            let units = Array(string.utf16)
            return offset >= 0 && offset + units.count <= utf16.count && utf16[offset..<(offset + units.count)].elementsEqual(units)
        }
        let start = url.lowerBound
        let end = url.upperBound
        if matches("](<", at: start - 3), matches(">)", at: end) {
            return openingBracket(before: start - 3, in: utf16).map { $0..<(end + 2) }
        }
        if matches("](", at: start - 2), matches(")", at: end) {
            return openingBracket(before: start - 2, in: utf16).map { $0..<(end + 1) }
        }
        if matches("<", at: start - 1), matches(">", at: end) {
            return (start - 1)..<(end + 1)
        }
        return nil
    }

    /// `](` 前面、同一行里最近的 `[`。找不到就不算链接语法。
    private static func openingBracket(before offset: Int, in utf16: [UInt16]) -> Int? {
        var index = offset - 1
        while index >= 0, utf16[index] != Self.newline {
            if utf16[index] == Self.openBracket { return index }
            index -= 1
        }
        return nil
    }

    // MARK: 第 2 层的检查

    /// 在 offset 处插入角标是否安全：后面紧跟的不能是 URL 字符，前面也不能是一个裸 URL（GFM 自动链接会把角标吞进去）。
    private static func isSafeInsertionPoint(_ offset: Int, in utf16: [UInt16]) -> Bool {
        if offset < utf16.count, isURLCharacter(utf16[offset]) { return false }
        // 往前找到这一段没有空白的文字，看里面有没有裸 URL
        var runStart = offset
        while runStart > 0, !isWhitespace(utf16[runStart - 1]) { runStart -= 1 }
        let run = String(decoding: utf16[runStart..<offset], as: UTF16.self).lowercased()
        for marker in ["https://", "http://", "www."] {
            guard let found = run.range(of: marker, options: .backwards) else { continue }
            let before = run[run.startIndex..<found.lowerBound].last
            // https://www. 里的 www. 由上面的 https:// 判断
            if marker == "www.", before == "/" { continue }
            // 前面是 ( 或 < 的是链接语法的一部分，结尾在 ) 或 > 之后，不算裸 URL
            if before != "(" && before != "<" { return false }
        }
        return true
    }

    /// RFC 3986 的非保留字符和保留字符，加上 `%`。
    private static let urlCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%".utf16)

    private static func isURLCharacter(_ unit: UInt16) -> Bool {
        urlCharacters.contains(unit)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x3000
    }

    private static let openBracket = UInt16(UInt8(ascii: "["))
    private static let newline = UInt16(UInt8(ascii: "\n"))

    /// 正文在三种单位下的偏移对照表，只在 Unicode 标量的边界上有定义。
    private struct Offsets {
        /// 第 i 个 Unicode 标量开头的 UTF-16 偏移，最后多一项是结尾。
        private let scalarStarts: [Int]
        /// UTF-8 字节偏移 → UTF-16 偏移，只记标量边界。
        private let utf8Boundaries: [Int: Int]

        init(_ text: String) {
            var scalarStarts = [0]
            var utf8Boundaries = [0: 0]
            var utf16Offset = 0
            var utf8Offset = 0
            for scalar in text.unicodeScalars {
                utf16Offset += scalar.utf16.count
                utf8Offset += scalar.utf8.count
                scalarStarts.append(utf16Offset)
                utf8Boundaries[utf8Offset] = utf16Offset
            }
            self.scalarStarts = scalarStarts
            self.utf8Boundaries = utf8Boundaries
        }

        func utf16Range(_ range: Range<Int>, count: Int) -> Range<Int>? {
            range.upperBound <= count && !range.isEmpty ? range : nil
        }

        func scalarRange(_ range: Range<Int>) -> Range<Int>? {
            guard range.upperBound < scalarStarts.count, !range.isEmpty else { return nil }
            return scalarStarts[range.lowerBound]..<scalarStarts[range.upperBound]
        }

        func utf8Range(_ range: Range<Int>) -> Range<Int>? {
            guard let lower = utf8Boundaries[range.lowerBound], let upper = utf8Boundaries[range.upperBound], lower < upper
            else { return nil }
            return lower..<upper
        }
    }
}
