import Foundation

/// 磁力搜索到的影视条目。
struct MagnetSearchItem: Identifiable, Equatable, Hashable {
    let id: String
    let code: String
    let title: String
    let coverURL: URL?
    let releaseDate: String?
    let detailPath: String

    init(
        id: String? = nil,
        code: String,
        title: String,
        coverURL: URL?,
        releaseDate: String? = nil,
        detailPath: String
    ) {
        self.id = id ?? code
        self.code = code
        self.title = title
        self.coverURL = coverURL
        self.releaseDate = releaseDate
        self.detailPath = detailPath
    }
}

/// 某部影片下的具体磁力资源。
struct MagnetTorrentItem: Identifiable, Equatable, Hashable {
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
}
