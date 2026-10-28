import Foundation

/// 最近播放记录，只保存直接 URL 来源；115 的内容从文件库进入。
final class RecentStore: ObservableObject {
    @Published private(set) var items: [RecentItem] = []

    private let storageKey = "hplayer.recent"
    private let limit = 30

    init() {
        load()
    }

    func add(title: String, url: URL) {
        let item = RecentItem(
            id: UUID().uuidString,
            title: title,
            url: url.absoluteString,
            playedAt: Date()
        )
        items.removeAll { $0.url == item.url }
        items.insert(item, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save()
    }

    func remove(_ item: RecentItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
