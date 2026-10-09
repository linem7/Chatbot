import Foundation

/// 把 OpenAI 格式的 `url_citation`（OpenRouter 的联网引用）换算成这次调用正文里的 UTF-16 范围（半开区间，和 `CitationSpan` 一致）。
///
/// `start_index`、`end_index` 的单位文档没说，`end_index` 也可能是闭区间（research §1.4），所以不直接用。
/// 和 Gemini 的 `GroundingLocator` 一样，用正文里的文字定位：
/// 1. 正文里出现了这条来源的 URL（OpenRouter 的搜索提示会让模型用 Markdown 链接引用）：取离 `start_index` 最近的一处，
///    范围一直延伸到链接语法结束（`[标题](URL)` 的 `)`、`<URL>` 的 `>`）。角标插在范围结尾，
///    停在链接语法中间的话会把链接拆坏。
/// 2. 正文里没有 URL：把偏移按 UTF-16、Unicode 标量、UTF-8 字节，各自按半开和闭区间试一遍，
///    切出来的文字含有这条来源的域名就用它。
/// 3. 都不行就不给范围：来源仍然出现在回答末尾的来源列表里，只是不在正文里标角标，免得标错位置。
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
        where String(decoding: utf16[candidate], as: UTF16.self).lowercased().contains(host) {
            return candidate
        }
        return nil
    }

    private static let closeParen = UInt16(UInt8(ascii: ")"))
    private static let openBracket = UInt16(UInt8(ascii: "["))
    private static let newline = UInt16(UInt8(ascii: "\n"))
    private static let lessThan = UInt16(UInt8(ascii: "<"))
    private static let greaterThan = UInt16(UInt8(ascii: ">"))

    /// 正文里离 hint 最近的一处 URL，范围延伸到包住它的链接语法结束。
    private static func linkRange(of url: String, near hint: Int, in utf16: [UInt16]) -> Range<Int>? {
        let needle = Array(url.utf16)
        guard !needle.isEmpty, needle.count <= utf16.count else { return nil }
        var best: Int?
        for offset in 0...(utf16.count - needle.count) where utf16[offset..<(offset + needle.count)].elementsEqual(needle) {
            if best.map({ abs($0 - hint) > abs(offset - hint) }) ?? true { best = offset }
        }
        guard var start = best else { return nil }
        var end = start + needle.count
        let before = start >= 2 ? Array(utf16[(start - 2)..<start]) : []
        if before == Array("](".utf16), end < utf16.count, utf16[end] == Self.closeParen {
            // [标题](URL)：从同一行里前面的 [ 开始，到 ) 结束
            end += 1
            var bracket = start - 2
            while bracket > 0, utf16[bracket - 1] != Self.openBracket, utf16[bracket - 1] != Self.newline { bracket -= 1 }
            if bracket > 0, utf16[bracket - 1] == Self.openBracket { start = bracket - 1 }
        } else if start >= 1, utf16[start - 1] == Self.lessThan, end < utf16.count, utf16[end] == Self.greaterThan {
            start -= 1
            end += 1
        }
        return start..<end
    }

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
