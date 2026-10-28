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

struct FileListResponse: Codable {
    let cid: String
    let files: [P115File]
}

struct LoginResponse: Codable {
    let ok: Bool
    let token: String
}

struct MeResponse: Codable {
    let authenticated: Bool
}

struct CookieResponse: Codable {
    let ok: Bool
    let userName: String
}

struct ErrorResponse: Codable {
    let error: String
}

struct QuotaResponse: Codable {
    let usedText: String
    let totalText: String
    let usedBytes: Int
    let totalBytes: Int
}

struct SearchResponse: Codable {
    let files: [P115File]
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
