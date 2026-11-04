import Foundation

/// 分类浏览类型：最新、专题（按片商）、女优、最热。
enum MagnetCategory: String, CaseIterable, Identifiable, Sendable {
    case latest
    case topics
    case actresses
    case hot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最新"
        case .topics: return "专题"
        case .actresses: return "女优"
        case .hot: return "最热"
        }
    }
}

/// 专题：JavBus 上的五家主流片商。`javbusPath` 是站点的片商页地址（用真实页面核对过，
/// 比用番号前缀去搜更完整：同一片商的各个系列都在里面）。
enum MagnetStudio: String, CaseIterable, Identifiable, Sendable {
    case s1
    case moodyz
    case ideaPocket
    case sod
    case prestige

    var id: String { rawValue }

    var title: String {
        switch self {
        case .s1: return "S1"
        case .moodyz: return "MOODYZ"
        case .ideaPocket: return "IdeaPocket"
        case .sod: return "SOD"
        case .prestige: return "PRESTIGE"
        }
    }

    /// 卡片左边方块里的字样。
    var monogram: String {
        switch self {
        case .s1: return "S1"
        case .moodyz: return "M"
        case .ideaPocket: return "IP"
        case .sod: return "SOD"
        case .prestige: return "P"
        }
    }

    /// 站点里的片商页路径（不带域名和页码）。
    var javbusPath: String {
        switch self {
        case .s1: return "studio/7q"
        case .moodyz: return "studio/4v"
        case .ideaPocket: return "studio/1"
        case .sod: return "studio/ca"
        case .prestige: return "studio/75"
        }
    }

    /// 卡片上的副标题：这家常见的番号前缀，帮助认人。
    var codeHint: String {
        switch self {
        case .s1: return "SONE · SSIS · SNOS"
        case .moodyz: return "MIDA · MIMK · MIDV"
        case .ideaPocket: return "IPZZ · IPX · IPBZ"
        case .sod: return "STARS · START · SDAB"
        case .prestige: return "ABF · ABW · ABP"
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

    /// 换上已知的主演名单（最热榜用它标出这部片是哪位女优带来的）。
    func withStars(_ stars: [MagnetStarItem]) -> MagnetSearchItem {
        MagnetSearchItem(
            id: id,
            code: code,
            title: title,
            coverURL: coverURL,
            releaseDate: releaseDate,
            detailPath: detailPath,
            stars: stars
        )
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
    func fetchStudio(_ studio: MagnetStudio, page: Int) async throws -> [MagnetSearchItem]
    func fetchHot() async throws -> [MagnetSearchItem]
    func fetchActresses(page: Int) async throws -> [MagnetStarItem]
    func searchActresses(name: String) async throws -> [MagnetStarItem]
    func fetchStarDetail(starPath: String, page: Int) async throws -> (star: MagnetStarItem?, movies: [MagnetSearchItem])
    func fetchDetailInfo(for item: MagnetSearchItem) async throws -> (stars: [MagnetStarItem], magnets: [MagnetTorrentItem])
}
