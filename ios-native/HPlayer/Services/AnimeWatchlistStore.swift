import Foundation
import Combine

struct AnimeWatchItem: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let pic: String?
    let lastContinu: String?
    let savedDate: Date
    var hasUpdate: Bool
}

@MainActor
final class AnimeWatchlistStore: ObservableObject {
    static let shared = AnimeWatchlistStore()

    @Published private(set) var items: [AnimeWatchItem] = []

    private let storageKey = "hplayer.anime.watchlist"

    private init() {
        load()
    }

    func isWatched(id: Int) -> Bool {
        items.contains { $0.id == id }
    }

    func toggle(detail: AnimeVideoDetail) {
        if let index = items.firstIndex(where: { $0.id == detail.id }) {
            items.remove(at: index)
        } else {
            let newItem = AnimeWatchItem(
                id: detail.id,
                name: detail.name,
                pic: nil,
                lastContinu: detail.continu,
                savedDate: Date(),
                hasUpdate: false
            )
            items.insert(newItem, at: 0)
        }
        save()
    }

    func toggle(item: AnimeVideoItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
        } else {
            let newItem = AnimeWatchItem(
                id: item.id,
                name: item.name,
                pic: item.pic,
                lastContinu: item.continu,
                savedDate: Date(),
                hasUpdate: false
            )
            items.insert(newItem, at: 0)
        }
        save()
    }

    func markUpdateChecked(id: Int) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].hasUpdate = false
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AnimeWatchItem].self, from: data) else {
            return
        }
        items = decoded
    }
}
