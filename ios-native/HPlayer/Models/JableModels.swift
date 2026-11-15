import Foundation

/// Jable 专区分组
enum JableCategory: String, CaseIterable, Identifiable {
    case latest = "latest-updates"
    case hot = "hot"
    case hotMonthly = "hot-monthly"
    case chineseSubtitle = "categories/chinese-subtitle"
    case censored = "categories/japanese-censored"
    case uncensored = "categories/japanese-uncensored"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最新"
        case .hot: return "热门"
        case .hotMonthly: return "月榜"
        case .chineseSubtitle: return "中字"
        case .censored: return "有码"
        case .uncensored: return "无码"
        }
    }

    var path: String { rawValue }
}

/// Jable 视频卡片信息
struct JableVideoCard: Identifiable, Hashable, Codable {
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

/// Jable 视频详情
struct JableVideoDetail: Identifiable, Hashable {
    let id: String
    let title: String
    let coverUrl: String
    let hlsUrl: String
    let models: [String]
    let tags: [String]
    let related: [JableVideoCard]

    init(id: String, title: String, coverUrl: String, hlsUrl: String, models: [String] = [], tags: [String] = [], related: [JableVideoCard] = []) {
        self.id = id
        self.title = title
        self.coverUrl = coverUrl
        self.hlsUrl = hlsUrl
        self.models = models
        self.tags = tags
        self.related = related
    }
}

/// Jable 视频播放引用，存入历史播放记录
struct JableVideoRef: Hashable {
    let videoId: String
    let title: String
    let coverUrl: String

    var id: String { "jable|\(videoId)" }
    var episodeTitle: String { title }
    var recordURL: String { "\(Self.scheme)://video/\(videoId)" }

    static let scheme = "hpjable"

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
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "jable.last_watched.\(videoId)")
    }
}

extension JableVideoCard {
    /// 轮播用的大图：列表里是 320×180 的截图（…/320x180/1.jpg），同一目录下的 preview.jpg 是大图。
    /// 不是这种地址时原样返回；大图取不到时轮播会退回列表里的小图。
    var largeCoverURL: String {
        guard let range = coverUrl.range(of: #"/\d+x\d+/\d+\.jpg"#, options: .regularExpression) else { return coverUrl }
        return coverUrl.replacingCharacters(in: range, with: "/preview.jpg")
    }
}
