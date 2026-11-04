import Foundation

/// 用户标记过「不在精选中显示」的影片。
///
/// 按资料编号（imdbID）记：同一部片换了文件、重新扫描、剧集的不同集，都认同一条；
/// 只影响首页顶部的精选大图，影片本身仍在首页货架和片库里。
@MainActor
final class FeaturedStore: ObservableObject {
    static let shared = FeaturedStore()
    static let storageKey = "hplayer.featured.hidden"

    @Published private(set) var hidden: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func hide(_ id: String) {
        guard !id.isEmpty, hidden.insert(id).inserted else { return }
        save()
    }

    func restoreAll() {
        guard !hidden.isEmpty else { return }
        hidden = []
        save()
    }

    private func save() {
        defaults.set(hidden.sorted(), forKey: Self.storageKey)
    }
}
