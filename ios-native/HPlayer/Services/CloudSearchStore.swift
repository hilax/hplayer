import Foundation

/// 远程搜索结果状态的通用基类：确保较慢或已取消的旧请求不能覆盖最新查询。
@MainActor
class SearchQueryStore<Item>: ObservableObject {
    @Published private(set) var results: [Item]
    @Published private(set) var searchedKeyword: String
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    private var request = UUID()

    init(initialQuery: String = "", initialResults: [Item] = []) {
        results = initialResults
        searchedKeyword = initialQuery
    }

    func invalidate(clearResults: Bool = false) {
        request = UUID()
        loading = false
        error = ""
        if clearResults {
            results = []
            searchedKeyword = ""
        }
    }

    func runSearch(_ query: String, lookup: (String) async throws -> [Item]) async {
        guard !Task.isCancelled else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            invalidate(clearResults: true)
            return
        }
        let current = UUID()
        request = current
        loading = true
        error = ""
        defer { if request == current { loading = false } }
        do {
            let items = try await lookup(text)
            guard request == current, !Task.isCancelled else { return }
            results = items
            searchedKeyword = text
        } catch {
            guard request == current, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

/// Owns a search response so a slower, older request cannot replace the latest query.
@MainActor
final class CloudSearchStore: SearchQueryStore<P115File> {
    func search(_ query: String, lookup: (String) async throws -> [P115File]) async {
        await runSearch(query) { text in
            try await lookup(text).filter { !$0.isDir && $0.isVideo }
        }
    }
}

/// 在线动漫搜索结果存储，与 `CloudSearchStore` 共用防乱序与取消保护逻辑。
@MainActor
final class AnimeSearchStore: SearchQueryStore<AnimeVideoItem> {
    func search(_ query: String, lookup: (String) async throws -> [AnimeVideoItem]) async {
        await runSearch(query, lookup: lookup)
    }
}

/// 本地持久化最近搜索关键词：不区分大小写去重、置顶、最多保留 12 条。
@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()
    static let maxItems = 12
    private static let storageKey = "hplayer.search_history"

    @Published private(set) var items: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    func record(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = items.filter { $0.localizedCaseInsensitiveCompare(text) != .orderedSame }
        updated.insert(text, at: 0)
        if updated.count > Self.maxItems {
            updated = Array(updated.prefix(Self.maxItems))
        }
        guard updated != items else { return }
        items = updated
        defaults.set(updated, forKey: Self.storageKey)
    }

    func remove(_ keyword: String) {
        let updated = items.filter { $0 != keyword }
        guard updated != items else { return }
        items = updated
        defaults.set(updated, forKey: Self.storageKey)
    }

    func clear() {
        guard !items.isEmpty else { return }
        items = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
