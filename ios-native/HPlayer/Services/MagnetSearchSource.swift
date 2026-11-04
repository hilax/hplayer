import Foundation

/// 分类浏览类型。
enum MagnetCategory: String, CaseIterable, Identifiable, Sendable {
    case latest
    case uncensored
    case actresses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最新发布"
        case .uncensored: return "无码最新"
        case .actresses: return "女优演员"
        }
    }
}

/// 演员/女优资料条目。
struct MagnetStarItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let avatarURL: URL?
    let detailPath: String
    let bio: String?

    init(
        id: String? = nil,
        name: String,
        avatarURL: URL?,
        detailPath: String,
        bio: String? = nil
    ) {
        self.id = id ?? detailPath
        self.name = name
        self.avatarURL = avatarURL
        self.detailPath = detailPath
        self.bio = bio
    }
}

/// 磁力搜索到的影视条目。
struct MagnetSearchItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let code: String
    let title: String
    let coverURL: URL?
    let releaseDate: String?
    let detailPath: String
    let stars: [MagnetStarItem]

    init(
        id: String? = nil,
        code: String,
        title: String,
        coverURL: URL?,
        releaseDate: String? = nil,
        detailPath: String,
        stars: [MagnetStarItem] = []
    ) {
        self.id = id ?? (detailPath.isEmpty ? code : detailPath)
        self.code = code
        self.title = title
        self.coverURL = coverURL
        self.releaseDate = releaseDate
        self.detailPath = detailPath
        self.stars = stars
    }
}

/// 某部影片下的具体磁力资源。
struct MagnetTorrentItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let magnetURL: String
    let name: String
    let size: String
    let date: String?
    let isHD: Bool
    let hasSubtitles: Bool

    init(
        id: String? = nil,
        magnetURL: String,
        name: String,
        size: String,
        date: String? = nil,
        isHD: Bool = false,
        hasSubtitles: Bool = false
    ) {
        self.id = id ?? magnetURL
        self.magnetURL = magnetURL
        self.name = name
        self.size = size
        self.date = date
        self.isHD = isHD
        self.hasSubtitles = hasSubtitles
    }
}

/// 磁力检索源通用协议。
protocol MagnetSearchSource: Sendable {
    var name: String { get }
    var currentHost: String { get }
    func search(keyword: String, page: Int) async throws -> [MagnetSearchItem]
    func fetchMagnets(for item: MagnetSearchItem) async throws -> [MagnetTorrentItem]
    func fetchCategory(_ category: MagnetCategory, page: Int) async throws -> [MagnetSearchItem]
    func fetchActresses(page: Int) async throws -> [MagnetStarItem]
    func searchActresses(name: String) async throws -> [MagnetStarItem]
    func fetchStarDetail(starPath: String, page: Int) async throws -> (star: MagnetStarItem?, movies: [MagnetSearchItem])
    func fetchDetailInfo(for item: MagnetSearchItem) async throws -> (stars: [MagnetStarItem], magnets: [MagnetTorrentItem])
}
