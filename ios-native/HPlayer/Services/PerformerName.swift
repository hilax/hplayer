import Foundation

/// 演员名的整理。同一个人在不同来源、不同影片里的写法可能差一个空格、一个中点或者全角半角，
/// 分组时按「归一化后的名字」算同一个人，显示用整理过的原名。
enum PerformerName {
    /// 判断是不是同一个人：全半角统一、不分大小写、去掉空白和标点（「・」「·」「.」都算）。
    static func key(_ name: String) -> String {
        let folded = name.precomposedStringWithCompatibilityMapping.lowercased()
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !ignored.contains($0) }))
    }

    /// 显示用：去掉首尾空白，中间连续的空白合成一个空格。
    static func display(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 一份演员名列表去掉重复（按 key 判断）并整理写法，保持原来的先后顺序。
    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { raw in
            let shown = display(raw)
            let id = key(shown)
            return id.isEmpty || !seen.insert(id).inserted ? nil : shown
        }
    }
}
