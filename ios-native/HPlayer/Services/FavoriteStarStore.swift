import Foundation

/// 一位喜欢的女优：只存列表和抬头要用的几项，保存在本机。
struct FavoriteStar: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var avatarURL: String?
    var detailPath: String
    var addedAt: Date

    init(star: MagnetStarItem, addedAt: Date = Date()) {
        id = star.id
        name = star.name
        avatarURL = star.avatarURL?.absoluteString
        detailPath = star.detailPath
        self.addedAt = addedAt
    }

    /// 还原成浏览页用的女优条目，点开就是她的作品页
    var item: MagnetStarItem {
        MagnetStarItem(id: id, name: name, avatarURL: avatarURL.flatMap(URL.init(string:)), detailPath: detailPath)
    }
}

/// 磁力「女优」里点了喜欢的人。最近喜欢的排在最前面，出现在女优列表顶部的「我喜欢的」一行。
@MainActor
final class FavoriteStarStore: ObservableObject {
    static let shared = FavoriteStarStore()

    /// 按喜欢的时间倒序
    @Published private(set) var items: [FavoriteStar] = []

    private let defaults: UserDefaults
    private let storageKey = "hplayer.magnet.favoriteStars"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FavoriteStar].self, from: data) else { return }
        items = decoded.sorted { $0.addedAt > $1.addedAt }
    }

    func contains(_ star: MagnetStarItem) -> Bool {
        items.contains { $0.id == star.id }
    }

    /// 喜欢 / 取消喜欢，返回操作后的状态
    @discardableResult
    func toggle(_ star: MagnetStarItem) -> Bool {
        if contains(star) {
            items.removeAll { $0.id == star.id }
            save()
            return false
        }
        items.insert(FavoriteStar(star: star), at: 0)
        save()
        return true
    }

    /// 女优页拿到了更完整的资料（比如头像）时顺手更新，不改变喜欢的时间和顺序
    func refresh(_ star: MagnetStarItem) {
        guard let index = items.firstIndex(where: { $0.id == star.id }) else { return }
        var entry = items[index]
        let avatar = star.avatarURL?.absoluteString
        guard entry.name != star.name || (avatar != nil && entry.avatarURL != avatar) else { return }
        entry.name = star.name
        if let avatar { entry.avatarURL = avatar }
        items[index] = entry
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
