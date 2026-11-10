import Foundation

/// 在线短剧（首页「短剧」频道）。接口字段类型不稳定（同一个字段有时是数字有时是字符串），
/// 所以一律用宽松读取（AnimeJSON），不走 Codable。
///
/// 接口形状参考第三方移植版 stclock1988/hghub-ios（PolyForm Noncommercial 1.0.0，
/// Copyright (c) 2026 HGhub contributors）；这里是按接口重新写的实现，仅限个人非商业使用。
enum DramaCategory: String, CaseIterable, Identifiable {
    /// 只接入这两个纯 AI 生成内容的分类（见 DramaClient 的说明）。
    case series = "ai-duanju"
    case animated = "ai-manju"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .series: return "短剧"
        case .animated: return "漫剧"
        }
    }
}

struct DramaCard: Identifiable, Hashable {
    let id: Int
    let title: String
    let cover: String
    let tags: [String]
    let score: Double
    let episodeCount: Int
    let isFinished: Bool

    init?(json: [String: Any]) {
        guard let id = AnimeJSON.int(json, ["id", "video_id"]), id > 0 else { return nil }
        self.id = id
        title = AnimeJSON.string(json, ["title"]) ?? "未命名"
        cover = AnimeJSON.string(json, ["cover"]) ?? ""
        tags = (json["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        score = AnimeJSON.double(json["score"]) ?? 0
        episodeCount = AnimeJSON.int(json, ["episode_count", "total_episodes"]) ?? 0
        isFinished = DramaJSON.bool(json["is_finished"])
    }

    var statusText: String {
        guard episodeCount > 0 else { return "" }
        return isFinished ? "全 \(episodeCount) 集" : "更新至 \(episodeCount) 集"
    }
}

struct DramaPage {
    let items: [DramaCard]
    let page: Int
    let pages: Int
    var hasMore: Bool { page < pages }
}

struct DramaEpisode: Identifiable, Hashable {
    let number: Int
    let title: String
    var id: Int { number }
}

struct DramaDetail {
    let id: Int
    let title: String
    let summary: String
    let cover: String
    let tags: [String]
    let score: Double
    let isFinished: Bool
    let author: String
    let episodes: [DramaEpisode]

    init?(json: [String: Any]) {
        guard let id = AnimeJSON.int(json, ["id"]), id > 0 else { return nil }
        self.id = id
        title = AnimeJSON.string(json, ["title"]) ?? "未命名"
        summary = AnimeJSON.string(json, ["description"]) ?? ""
        cover = AnimeJSON.string(json, ["cover"]) ?? ""
        tags = (json["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        score = AnimeJSON.double(json["score"]) ?? 0
        isFinished = DramaJSON.bool(json["is_finished"])
        author = AnimeJSON.string(json["author"] as? [String: Any] ?? [:], ["name"]) ?? ""
        var list: [DramaEpisode] = []
        var seen = Set<Int>()
        for raw in (json["episodes"] as? [[String: Any]]) ?? [] {
            guard let number = AnimeJSON.int(raw, ["ep_num"]), number > 0, seen.insert(number).inserted else { continue }
            list.append(DramaEpisode(number: number, title: AnimeJSON.string(raw, ["title"]) ?? ""))
        }
        if list.isEmpty {
            // 有的条目不给分集列表，只给集数
            let count = AnimeJSON.int(json, ["episode_count", "total_episodes"]) ?? 0
            list = (0..<max(count, 0)).map { DramaEpisode(number: $0 + 1, title: "") }
        }
        episodes = list.sorted { $0.number < $1.number }
    }
}

/// 短剧的一集。播放地址带一小时左右的时效签名，所以播放列表和观看记录里存的是集数引用，打开时现取。
struct DramaEpisodeRef: Hashable {
    let videoId: Int
    let seriesName: String
    let episode: Int

    var id: String { "drama|\(videoId)|\(episode)" }
    var episodeTitle: String { "\(seriesName) 第\(episode)集" }

    /// 写进观看记录的占位地址；RecentItem.dramaRef 再把它解析回来。
    var recordURL: String { "\(Self.scheme)://video/\(videoId)/\(episode)" }

    static let scheme = "hpdrama"

    init(videoId: Int, seriesName: String, episode: Int) {
        self.videoId = videoId
        self.seriesName = seriesName
        self.episode = episode
    }

    /// 从观看记录还原：剧名从标题里取（标题固定是「剧名 第N集」）。
    init?(recordURL: String, title: String) {
        guard let url = URL(string: recordURL), url.scheme == Self.scheme, url.host == "video" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let videoId = Int(parts[0]), let episode = Int(parts[1]) else { return nil }
        let suffix = " 第\(episode)集"
        self.init(videoId: videoId,
                  seriesName: title.hasSuffix(suffix) ? String(title.dropLast(suffix.count)) : title,
                  episode: episode)
    }

    func rememberAsLastWatched() {
        UserDefaults.standard.set(episode, forKey: "drama.last_episode.\(videoId)")
    }

    static func lastWatched(videoId: Int) -> Int? {
        let value = UserDefaults.standard.integer(forKey: "drama.last_episode.\(videoId)")
        return value > 0 ? value : nil
    }
}

enum DramaJSON {
    static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = AnimeJSON.double(value) { return number != 0 }
        return false
    }
}
