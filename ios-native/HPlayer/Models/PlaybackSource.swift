import Foundation

/// 播放源：既可以直接是一个 URL，也可以是 115 网盘里的文件。
/// 这样播放器本身不依赖 115，115 只是其中一种来源。
enum PlaybackSource: Identifiable, Hashable {
    case direct(title: String, url: URL)
    case p115(title: String, pickCode: String)

    var id: String {
        switch self {
        case .direct(let title, let url):
            return "direct|\(title)|\(url.absoluteString)"
        case .p115(_, let pickCode):
            return "p115|\(pickCode)"
        }
    }

    var title: String {
        switch self {
        case .direct(let title, _):
            return title
        case .p115(let title, _):
            return title
        }
    }
}

struct RecentItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let playedAt: Date
}
