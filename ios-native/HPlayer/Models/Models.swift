import Foundation

struct P115File: Identifiable, Codable, Hashable {
    let id: String
    let parentId: String
    let name: String
    let isDir: Bool
    let kind: String
    let size: Int
    let pickCode: String
    let sha1: String
    let updatedAt: String
    let thumbUrl: String

    var isVideo: Bool { kind == "video" }
}

extension P115File {
    /// 更新时间。115 不同接口返回的格式不一样：秒或毫秒时间戳，或者「2024-05-01 12:30」这样的文本。
    var updatedDate: Date? {
        let text = updatedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let number = Double(text) {
            guard number > 0 else { return nil }
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        for formatter in Self.dateParsers {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let dateParsers: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map { (format: String) -> DateFormatter in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter
    }
}

struct MediaInfo: Codable {
    let container: String
    let videoCodec: String
    let audioCodec: String
    let duration: Double
    let width: Int
    let height: Int
    let directPlay: Bool
    let fileName: String
    let fileSize: Int
}

struct P115Status: Codable {
    let configured: Bool
    let userId: Int?
    let userName: String?
    let vip: Int?
    let error: String?
    let message: String?
}

struct QuotaResponse: Codable {
    let usedText: String
    let totalText: String
    let usedBytes: Int
    let totalBytes: Int
}

func formatSize(_ bytes: Int) -> String {
    guard bytes > 0 else { return "" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024 && index < units.count - 1 {
        value /= 1024
        index += 1
    }
    let decimals = value >= 10 || index == 0 ? 0 : 1
    return String(format: "%.\(decimals)f %@", value, units[index])
}
