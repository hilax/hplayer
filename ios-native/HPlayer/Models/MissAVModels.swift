import Foundation

/// MissAV 专区分组
enum MissAVCategory: String, CaseIterable, Identifiable {
    case todayHot = "today-hot"
    case weeklyHot = "weekly-hot"
    case monthlyHot = "monthly-hot"
    case new = "new"
    case release = "release"
    case chineseSubtitle = "chinese-subtitle"
    case uncensoredLeak = "uncensored-leak"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todayHot: return "今日热门"
        case .weeklyHot: return "本周热门"
        case .monthlyHot: return "本月热门"
        case .new: return "新片"
        case .release: return "发行"
        case .chineseSubtitle: return "中字"
        case .uncensoredLeak: return "无码"
        }
    }

    var path: String { rawValue }
}

/// MissAV 视频卡片信息
struct MissAVVideoCard: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let url: String
    let coverUrl: String
    let duration: String
    let views: String

    init(id: String, title: String, url: String, coverUrl: String, duration: String = "", views: String = "") {
        self.id = id
        self.title = title
        self.url = url
        self.coverUrl = coverUrl
        self.duration = duration
        self.views = views
    }
}

/// MissAV 视频详情
struct MissAVVideoDetail: Identifiable, Hashable {
    let id: String
    let title: String
    let coverUrl: String
    let hlsUrl: String
    let models: [String]
    let tags: [String]
    let related: [MissAVVideoCard]

    init(id: String, title: String, coverUrl: String, hlsUrl: String, models: [String] = [], tags: [String] = [], related: [MissAVVideoCard] = []) {
        self.id = id
        self.title = title
        self.coverUrl = coverUrl
        self.hlsUrl = hlsUrl
        self.models = models
        self.tags = tags
        self.related = related
    }
}

/// MissAV 视频播放引用，存入历史播放记录
struct MissAVVideoRef: Hashable {
    let videoId: String
    let title: String
    let coverUrl: String

    var id: String { "missav|\(videoId)" }
    var episodeTitle: String { title }
    var recordURL: String { "\(Self.scheme)://video/\(videoId)" }

    static let scheme = "hpmissav"

    init(videoId: String, title: String, coverUrl: String = "") {
        self.videoId = videoId
        self.title = title
        self.coverUrl = coverUrl
    }

    /// 从播放记录的占位地址还原
    init?(recordURL: String, title: String) {
        guard let url = URL(string: recordURL), url.scheme == Self.scheme, url.host == "video" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let videoId = parts.first, !videoId.isEmpty else { return nil }
        self.init(videoId: videoId, title: title)
    }

    func rememberAsLastWatched() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "missav.last_watched.\(videoId)")
    }
}
