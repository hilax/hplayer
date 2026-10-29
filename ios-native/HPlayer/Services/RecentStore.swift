import Foundation

/// 最近播放记录和续播位置。直接地址（本地视频、网络地址）和 115 文件都会记下来；
/// 磁力资源的记录在 MagnetHistoryStore 里。
final class RecentStore: ObservableObject {
    static let shared = RecentStore()

    @Published private(set) var items: [RecentItem] = []

    private let storageKey = "hplayer.recent"
    private let limit = 30

    init() {
        load()
    }

    /// 开始播放时调用：新建或刷新记录并移到最前面，保留已有的观看位置
    func record(_ source: PlaybackSource) {
        let key = Self.key(for: source)
        var entry = items.first { Self.key(of: $0) == key } ?? RecentItem(
            id: UUID().uuidString,
            title: source.title,
            url: "",
            playedAt: Date()
        )
        entry.title = source.title
        entry.playedAt = Date()
        switch source {
        case .direct(_, let url):
            entry.url = url.absoluteString
            entry.pickCode = nil
        case .p115(_, let pickCode):
            entry.url = ""
            entry.pickCode = pickCode
        }
        items.removeAll { Self.key(of: $0) == key }
        items.insert(entry, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save()
    }

    /// 兼容旧接口
    func add(title: String, url: URL) {
        record(.direct(title: title, url: url))
    }

    func position(for source: PlaybackSource) -> Double? {
        let key = Self.key(for: source)
        return items.first { Self.key(of: $0) == key }?.position
    }

    /// 刚开头或快看完时不记位置，下次从头播放
    func savePosition(for source: PlaybackSource, seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        let key = Self.key(for: source)
        guard let index = items.firstIndex(where: { Self.key(of: $0) == key }) else { return }
        var entry = items[index]
        if seconds < 10 || seconds > duration - 30 || seconds / duration > 0.95 {
            guard entry.position != nil else { return }
            entry.position = nil
            entry.duration = nil
        } else {
            if let old = entry.position, abs(old - seconds) < 1, entry.duration == duration { return }
            entry.position = seconds
            entry.duration = duration
        }
        items[index] = entry
        save()
    }

    /// 把记录还原成播放源。本地文件在重装后路径会变，按文件名到媒体目录里再找一次。
    func source(for item: RecentItem, localDirectory: URL? = nil) -> PlaybackSource? {
        if let pickCode = item.pickCode, !pickCode.isEmpty {
            return .p115(title: item.title, pickCode: pickCode)
        }
        guard let url = URL(string: item.url) else { return nil }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path), let localDirectory {
            let moved = localDirectory.appendingPathComponent(url.lastPathComponent)
            guard FileManager.default.fileExists(atPath: moved.path) else { return nil }
            return .direct(title: item.title, url: moved)
        }
        return .direct(title: item.title, url: url)
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

    /// 同一个视频只留一条：115 按 pickCode，本地文件按文件名，网络地址按完整地址
    static func key(for source: PlaybackSource) -> String {
        switch source {
        case .p115(_, let pickCode):
            return "p115|\(pickCode)"
        case .direct(_, let url):
            return url.isFileURL ? "file|\(url.lastPathComponent)" : "url|\(url.absoluteString)"
        }
    }

    private static func key(of item: RecentItem) -> String {
        if let pickCode = item.pickCode, !pickCode.isEmpty { return "p115|\(pickCode)" }
        guard let url = URL(string: item.url) else { return "url|\(item.url)" }
        return url.isFileURL ? "file|\(url.lastPathComponent)" : "url|\(url.absoluteString)"
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
