import Foundation

// MARK: - 统一 API 响应包装外壳

struct AnimeAPIResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T?
}

// MARK: - 分类与频道模型

struct AnimeChannel: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let types: [String]?
    let years: [String]?
    let areas: [String]?
    let oid: Int?
    let pid: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, types, years, areas, oid, pid
    }
}

// MARK: - 轮播 Banner

struct AnimeBanner: Identifiable, Codable, Hashable {
    let id: Int
    let vid: Int?
    let img: String
    let vname: String
    let continu: String?
    let content: String?
    let gold: Int?
    let oid: Int?
    let pid: Int?

    var displayTitle: String { vname }
    var displayImage: String { img }
    var displayRemarks: String { continu ?? "" }
    var displayDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

// MARK: - 视频条目模型（列表与搜索）

struct AnimeVideoListResult: Codable {
    let total: Int
    let items: [AnimeVideoItem]
}

struct AnimeVideoItem: Identifiable, Codable, Hashable {
    let id: Int
    let cid: Int?
    let name: String
    let ename: String?
    let pic: String?
    let year: String?
    let area: String?
    let continu: String?
    let total: Int?
    let isend: Int?
    let type: String?
    let actor: String?
    let director: String?
    let content: String?
    let updatedAt: String?
    let stars: String?

    enum CodingKeys: String, CodingKey {
        case id, cid, name, ename, pic, year, area, continu, total, isend, type, actor, director, content
        case updatedAt = "updated_at"
        case stars
    }

    var cleanDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var tags: [String] {
        (type ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - 详情与选集模型

struct AnimeVideoDetail: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let source: String?
    let parts: [AnimePlayRoute]
    let continu: String?
    let year: String?
    let area: String?
    let type: String?
    let actor: String?
    let director: String?
    let content: String?
    let stars: String?
    let autoPlay: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, source, parts, continu, year, area, type, actor, director, content, stars
        case autoPlay = "auto_play"
    }

    var cleanDesc: String {
        (content ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var tags: [String] {
        (type ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct AnimePlayRoute: Identifiable, Codable, Hashable {
    var id: String { play }
    let play: String
    let playZh: String
    let singleClarityDisplay: Int?
    let part: [String]

    enum CodingKeys: String, CodingKey {
        case play
        case playZh = "play_zh"
        case singleClarityDisplay = "single_clarity_display"
        case part
    }
}

// MARK: - 播放凭证响应模型

struct AnimePlayResponse: Codable {
    let url: String
    let parse: String?
    let play: String?
    let playZh: String?
    let part: String?
    let resolution: String?
    let singleClarityDisplay: Int?

    enum CodingKeys: String, CodingKey {
        case url, parse, play
        case playZh = "play_zh"
        case part, resolution
        case singleClarityDisplay = "single_clarity_display"
    }
}

// MARK: - 解析后的最终可用流地址

struct AnimeResolvedStream: Equatable {
    let url: URL
    let headers: [String: String]
    let format: String // "hls", "mp4", etc.
    let title: String
}
