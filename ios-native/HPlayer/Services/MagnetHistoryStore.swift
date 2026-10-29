import Foundation

/// 一条磁力播放记录：再次打开时引擎能直接读到本机保存的种子信息，不用重新解析。
struct MagnetHistoryItem: Codable, Identifiable, Equatable {
    var infoHash: String
    /// 整理后的磁力链接（不含补充的公共 Tracker）
    var magnet: String
    var name: String
    var totalSize: UInt64
    var videoCount: Int
    var lastFileIndex: UInt32?
    var lastFileTitle: String?
    /// 每个文件上次看到的位置（秒），键是文件序号
    var positions: [String: Double]
    var updatedAt: Date

    var id: String { infoHash }
}

/// 最近播放的磁力资源和每一集的观看进度，保存在本机。
@MainActor
final class MagnetHistoryStore: ObservableObject {
    static let shared = MagnetHistoryStore()

    @Published private(set) var items: [MagnetHistoryItem] = []

    private let storageKey = "hplayer.magnet.history"
    private let limit = 30

    init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MagnetHistoryItem].self, from: data) else { return }
        items = decoded
    }

    func item(for infoHash: String) -> MagnetHistoryItem? {
        items.first { $0.infoHash == infoHash }
    }

    /// 解析成功：新建或刷新记录，并移到最前面
    func recordResolved(link: MagnetLink, catalog: MagnetCatalog) {
        var entry = self.item(for: link.infoHash) ?? MagnetHistoryItem(
            infoHash: link.infoHash,
            magnet: link.uri,
            name: catalog.name,
            totalSize: catalog.totalSize,
            videoCount: catalog.allVideos.count,
            lastFileIndex: nil,
            lastFileTitle: nil,
            positions: [:],
            updatedAt: Date()
        )
        entry.magnet = link.uri
        entry.name = catalog.name
        entry.totalSize = catalog.totalSize
        entry.videoCount = catalog.allVideos.count
        entry.updatedAt = Date()
        upsert(entry)
    }

    func recordPlayed(infoHash: String, file: MagnetFile) {
        guard var entry = self.item(for: infoHash) else { return }
        entry.lastFileIndex = file.index
        entry.lastFileTitle = file.title
        entry.updatedAt = Date()
        upsert(entry)
    }

    func position(infoHash: String, fileIndex: UInt32) -> Double? {
        item(for: infoHash)?.positions[String(fileIndex)]
    }

    /// 刚开头或快看完时不记位置，下次从头播放
    func savePosition(infoHash: String, fileIndex: UInt32, seconds: Double, duration: Double) {
        guard var entry = self.item(for: infoHash), seconds.isFinite, duration.isFinite, duration > 0 else { return }
        let key = String(fileIndex)
        if seconds < 10 || seconds > duration - 30 || seconds / duration > 0.95 {
            guard entry.positions[key] != nil else { return }
            entry.positions[key] = nil
        } else {
            entry.positions[key] = seconds
        }
        if let index = items.firstIndex(where: { $0.infoHash == infoHash }) {
            items[index] = entry
            persist()
        }
    }

    func clearPosition(infoHash: String, fileIndex: UInt32) {
        guard let index = items.firstIndex(where: { $0.infoHash == infoHash }) else { return }
        items[index].positions[String(fileIndex)] = nil
        persist()
    }

    func remove(_ infoHash: String) {
        items.removeAll { $0.infoHash == infoHash }
        persist()
    }

    func removeAll() {
        items = []
        persist()
    }

    private func upsert(_ item: MagnetHistoryItem) {
        items.removeAll { $0.infoHash == item.infoHash }
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
