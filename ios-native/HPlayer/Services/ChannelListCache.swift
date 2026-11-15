import Foundation

/// Jable、MissAV 各分类第一页列表的本地缓存：打开频道时先显示上次的列表，后台再刷新最新的，
/// 不用每次都对着转圈等网页加载（这两个站有时还要先过人机验证）。存在 Caches 目录，系统空间紧张时可能被清掉。
enum ChannelListCache {
    /// 超过这么久的缓存不再拿来先显示
    static let maxAge: TimeInterval = 3 * 24 * 3600

    private struct Entry<Item: Codable>: Codable {
        let savedAt: Date
        let items: [Item]
    }

    /// 刚存的缓存在这段时间内直接当最新的用，不再去网页重新取：
    /// 两个站的列表都走同一个后台网页排队取，频道首页一屏好几排，每排都重取会把点进详情的请求堵在后面
    static let freshAge: TimeInterval = 20 * 60

    static func load<Item: Codable>(_ key: String, as type: Item.Type = Item.self) -> [Item]? {
        loadWithAge(key, as: type)?.items
    }

    /// 缓存的列表和它存了多久
    static func loadWithAge<Item: Codable>(_ key: String, as _: Item.Type = Item.self) -> (items: [Item], age: TimeInterval)? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry<Item>.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(entry.savedAt)
        guard age < maxAge, !entry.items.isEmpty else { return nil }
        return (entry.items, age)
    }

    static func save<Item: Codable>(_ items: [Item], key: String) {
        guard !items.isEmpty, let url = fileURL(key),
              let data = try? JSONEncoder().encode(Entry(savedAt: Date(), items: items)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(_ key: String) -> URL? {
        let name = key.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ChannelLists", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }
}
