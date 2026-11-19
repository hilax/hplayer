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
    /// 每个文件的总时长（秒），和 positions 一起用来画进度条；旧记录没有这一项
    var durations: [String: Double]? = nil
    /// 最近一次是通过 115 播放的（115 播放记录由 RecentStore 承载，首页「继续观看」不再重复显示磁力卡片）
    var playedViaCloud: Bool? = nil
    /// 115 离线目录里对应的视频提取码列表（用于和 RecentStore 中的 115 记录关联去重）
    var cloudPickCodes: [String]? = nil
    /// 最近一次通过 115 播放的视频提取码
    var lastCloudPickCode: String? = nil

    var id: String { infoHash }

    /// 上次播放那一集看到的位置和比例，首页「继续观看」用
    var lastProgress: (seconds: Double, fraction: Double?)? {
        guard let index = lastFileIndex, let seconds = positions[String(index)] else { return nil }
        guard let duration = durations?[String(index)], duration > 0 else { return (seconds, nil) }
        return (seconds, min(max(seconds / duration, 0), 1))
    }
}

/// 最近播放的磁力资源和每一集的观看进度，保存在本机。
@MainActor
final class MagnetHistoryStore: ObservableObject {
    static let shared = MagnetHistoryStore()

    @Published private(set) var items: [MagnetHistoryItem] = []

    private let defaults: UserDefaults
    private let storageKey = "hplayer.magnet.history"
    private let limit = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MagnetHistoryItem].self, from: data) else { return }
        items = decoded
    }

    func item(for infoHash: String) -> MagnetHistoryItem? {
        items.first { $0.infoHash == infoHash }
    }

    /// 解析成功：新建或刷新记录，并移到最前面
    func recordResolved(link: MagnetLink, catalog: MagnetCatalog) {
        let viaCloud = catalog.source == .cloud
        let pickCodes = catalog.allVideos.compactMap(\.pickCode).filter { !$0.isEmpty }
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
        entry.playedViaCloud = viaCloud
        if !pickCodes.isEmpty {
            entry.cloudPickCodes = pickCodes
        }
        upsert(entry)
    }

    func recordPlayed(infoHash: String, file: MagnetFile) {
        guard var entry = self.item(for: infoHash) else { return }
        entry.lastFileIndex = file.historyIndex
        entry.lastFileTitle = file.title
        entry.updatedAt = Date()
        if let pickCode = file.pickCode, !pickCode.isEmpty {
            entry.playedViaCloud = true
            entry.lastCloudPickCode = pickCode
            var codes = entry.cloudPickCodes ?? []
            if !codes.contains(pickCode) { codes.append(pickCode) }
            entry.cloudPickCodes = codes
        } else {
            entry.playedViaCloud = false
        }
        upsert(entry)
    }

    /// 从首页「继续观看」移除一条 115 播放记录时，同步标记旧版尚未写入 `playedViaCloud` 的对应磁力条目，
    /// 避免删掉 115 卡片后原本被去重隐藏的旧磁力卡片重新冒出来。
    func markSupersededByCloud(pickCode: String, cachedInfoHashes: Set<String> = [], title: String = "") {
        guard !pickCode.isEmpty else { return }
        var changed = false
        let normalizedTitle = Self.normalizedTitle(title)
        for index in items.indices {
            let item = items[index]
            guard item.playedViaCloud == nil, item.lastProgress == nil else { continue }
            let matchesPickCode = item.lastCloudPickCode == pickCode || (item.cloudPickCodes?.contains(pickCode) == true)
            let matchesHash = cachedInfoHashes.contains(item.infoHash.lowercased())
            let matchesTitle = !normalizedTitle.isEmpty && Self.matchesCloudTitle(item, normalizedCloudTitle: normalizedTitle)
            if matchesPickCode || matchesHash || matchesTitle {
                items[index].playedViaCloud = true
                if items[index].lastCloudPickCode == nil {
                    items[index].lastCloudPickCode = pickCode
                }
                changed = true
            }
        }
        if changed { persist() }
    }

    /// 判断一条磁力历史记录在首页「继续观看」里是否已经由对应的 115 播放记录承载（避免同一视频出现两条记录）。
    static func isSupersededByCloud(
        _ item: MagnetHistoryItem,
        recentCloudPickCodes: Set<String>,
        recentCloudTitles: [String],
        cachedPickCodesForHash: (String) -> Set<String>,
        isDownloadedToCloud: (String) -> Bool
    ) -> Bool {
        if let playedViaCloud = item.playedViaCloud {
            return playedViaCloud
        }
        // 兼容旧版本已经写盘的历史记录：没有 BT 播放进度，且对应提取码或已离线资源已在 115 最近播放里出现
        guard item.lastProgress == nil else { return false }
        var codes = Set(item.cloudPickCodes ?? [])
        if let last = item.lastCloudPickCode, !last.isEmpty { codes.insert(last) }
        codes.formUnion(cachedPickCodesForHash(item.infoHash))
        if !codes.isEmpty && !codes.isDisjoint(with: recentCloudPickCodes) {
            return true
        }
        guard isDownloadedToCloud(item.infoHash), !recentCloudTitles.isEmpty else { return false }
        for cloudTitle in recentCloudTitles {
            let normalized = normalizedTitle(cloudTitle)
            if !normalized.isEmpty, matchesCloudTitle(item, normalizedCloudTitle: normalized) {
                return true
            }
        }
        return false
    }

    private static func normalizedTitle(_ raw: String) -> String {
        let parsed = MediaNameParser.parse(raw).title
        let candidate = parsed.isEmpty ? raw : parsed
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matchesCloudTitle(_ item: MagnetHistoryItem, normalizedCloudTitle: String) -> Bool {
        if let fileTitle = item.lastFileTitle {
            let normalizedFile = normalizedTitle(fileTitle)
            if normalizedFile.count >= 4,
               normalizedFile == normalizedCloudTitle || normalizedCloudTitle.contains(normalizedFile) || normalizedFile.contains(normalizedCloudTitle) {
                return true
            }
        }
        let normalizedName = normalizedTitle(item.name)
        if normalizedName.count >= 4,
           normalizedName == normalizedCloudTitle || normalizedCloudTitle.contains(normalizedName) || normalizedName.contains(normalizedCloudTitle) {
            return true
        }
        return false
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
            entry.durations?[key] = nil
        } else {
            entry.positions[key] = seconds
            var durations = entry.durations ?? [:]
            durations[key] = duration
            entry.durations = durations
        }
        if let index = items.firstIndex(where: { $0.infoHash == infoHash }) {
            items[index] = entry
            persist()
        }
    }

    func clearPosition(infoHash: String, fileIndex: UInt32) {
        guard let index = items.firstIndex(where: { $0.infoHash == infoHash }) else { return }
        items[index].positions[String(fileIndex)] = nil
        items[index].durations?[String(fileIndex)] = nil
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
        defaults.set(data, forKey: storageKey)
    }
}
