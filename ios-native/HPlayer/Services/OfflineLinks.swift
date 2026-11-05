import Foundation

/// 115 离线下载支持的链接类型
enum OfflineLinkKind: Equatable {
    case magnet
    case http
    case ed2k
    case ftp

    /// 提示条里的简称
    var shortName: String {
        switch self {
        case .magnet: return "磁力"
        case .http: return "HTTP"
        case .ed2k: return "电驴"
        case .ftp: return "FTP"
        }
    }
}

struct OfflineLink: Equatable, Identifiable {
    let text: String
    let kind: OfflineLinkKind

    var id: String { text }
}

/// 添加离线任务时，把输入框里的文字整理成链接：一行一条，去掉空行和重复，裸的 BT 哈希补成磁力链接。
struct OfflineLinkBatch: Equatable {
    var links: [OfflineLink]
    /// 无法识别的行（原文，已去掉首尾空白）
    var rejected: [String]
    /// 重复而被忽略的条数
    var duplicates: Int

    var isEmpty: Bool { links.isEmpty }

    /// 例如「磁力 1 · HTTP 1」
    var kindSummary: String {
        let order: [OfflineLinkKind] = [.magnet, .http, .ed2k, .ftp]
        return order.compactMap { kind -> String? in
            let count = links.filter { $0.kind == kind }.count
            return count > 0 ? "\(kind.shortName) \(count)" : nil
        }.joined(separator: " · ")
    }

    static func parse(_ raw: String) -> OfflineLinkBatch {
        var links: [OfflineLink] = []
        var rejected: [String] = []
        var seen = Set<String>()
        var duplicates = 0
        for line in raw.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let link = classify(text) else {
                rejected.append(text)
                continue
            }
            if seen.insert(link.text).inserted {
                links.append(link)
            } else {
                duplicates += 1
            }
        }
        return OfflineLinkBatch(links: links, rejected: rejected, duplicates: duplicates)
    }

    static func classify(_ text: String) -> OfflineLink? {
        guard !text.contains(where: { $0.isNewline }), text.count <= 8_000 else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("magnet:?") {
            guard lower.contains("xt=urn:btih:") || lower.contains("xt=urn:btmh:") else { return nil }
            return OfflineLink(text: text, kind: .magnet)
        }
        if lower.hasPrefix("ed2k://") {
            return lower.count > "ed2k://".count ? OfflineLink(text: text, kind: .ed2k) : nil
        }
        for prefix in ["https://", "http://"] where lower.hasPrefix(prefix) {
            return hasHost(text, after: prefix.count) ? OfflineLink(text: text, kind: .http) : nil
        }
        for prefix in ["ftps://", "ftp://"] where lower.hasPrefix(prefix) {
            return hasHost(text, after: prefix.count) ? OfflineLink(text: text, kind: .ftp) : nil
        }
        // 只贴了 BT 哈希：40 位十六进制，或 32 位 base32
        if text.count == 40, text.allSatisfy({ $0.isHexDigit && $0.isASCII }) {
            return OfflineLink(text: "magnet:?xt=urn:btih:\(text)", kind: .magnet)
        }
        if text.count == 32, text.allSatisfy({ $0.isASCII && ($0.isLetter || "234567".contains($0)) }) {
            return OfflineLink(text: "magnet:?xt=urn:btih:\(text)", kind: .magnet)
        }
        return nil
    }

    /// 链接里要有主机名，且没有空格
    private static func hasHost(_ text: String, after prefixLength: Int) -> Bool {
        let rest = text.dropFirst(prefixLength)
        guard let first = rest.first, first != "/", first != "?", first != "#" else { return false }
        return !rest.contains(where: { $0.isWhitespace })
    }
}
