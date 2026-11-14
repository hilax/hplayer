import Foundation

/// 记住每条观看记录当时的播放列表（同一部剧 / 同一个文件夹 / 同一部番的所有集），
/// 从首页「继续观看」打开时把整份列表还原给播放器，选集里就能看到上一集、下一集。
///
/// 以前只记了正在看的那一集：片库里认得出来的剧还能按剧集重新拼，网盘文件夹里没入库的视频、
/// 在线动漫、短剧打开后选集里都只有一集。
///
/// 列表存在 Application Support 下的一个 JSON 文件里（不放 UserDefaults，免得撑大）；
/// 同一份列表的各集共用一份，只留还在观看记录里的那些。
@MainActor
final class RecentPlaylistStore {
    static let shared = RecentPlaylistStore()

    /// 能存下来的播放源。`.online` 带请求头和清晰度列表、地址会过期，不存；列表里有它就整份不记。
    enum StoredSource: Codable, Equatable {
        case direct(title: String, url: URL)
        case p115(title: String, pickCode: String)
        case anime(AnimeEpisodeRef)
        case drama(videoId: Int, seriesName: String, episode: Int)

        init?(_ source: PlaybackSource) {
            switch source {
            case .direct(let title, let url): self = .direct(title: title, url: url)
            case .p115(let title, let pickCode): self = .p115(title: title, pickCode: pickCode)
            case .anime(let ref): self = .anime(ref)
            case .drama(let ref): self = .drama(videoId: ref.videoId, seriesName: ref.seriesName, episode: ref.episode)
            case .online: return nil
            }
        }

        var source: PlaybackSource {
            switch self {
            case .direct(let title, let url): return .direct(title: title, url: url)
            case .p115(let title, let pickCode): return .p115(title: title, pickCode: pickCode)
            case .anime(let ref): return .anime(ref)
            case .drama(let videoId, let seriesName, let episode):
                return .drama(DramaEpisodeRef(videoId: videoId, seriesName: seriesName, episode: episode))
            }
        }
    }

    private struct Snapshot: Codable {
        /// 列表编号 → 整份列表
        var groups: [String: [StoredSource]] = [:]
        /// 观看记录的 key（RecentStore.key）→ 列表编号
        var byKey: [String: String] = [:]
    }

    /// 一份列表最多存这么多集，太长的（整个片库）不记
    private let maxItems = 600
    private var snapshot = Snapshot()
    private let fileURL: URL?
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = RecentPlaylistStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        }
    }

    private static var defaultFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("HPlayer", isDirectory: true).appendingPathComponent("recent-playlists.json")
    }

    /// 播放器开始播一集时调用：记下这一集属于哪份列表
    func remember(_ playlist: [PlaybackSource], current: PlaybackSource, keep liveKeys: Set<String>) {
        guard playlist.count > 1, playlist.count <= maxItems, playlist.contains(current) else { return }
        let stored = playlist.compactMap(StoredSource.init)
        guard stored.count == playlist.count, let first = playlist.first, let last = playlist.last else { return }
        let group = "\(playlist.count)|\(first.id)|\(last.id)"
        snapshot.groups[group] = stored
        snapshot.byKey[RecentStore.key(for: current)] = group
        prune(keeping: liveKeys.union([RecentStore.key(for: current)]))
        scheduleSave()
    }

    /// 继续观看打开时：这条记录当时的整份列表，以及列表里对应「正在看的这一集」的那一项
    /// 本机文件的绝对路径在 App 更新后会变（沙盒目录换了），按文件名重新指到 `localDirectory` 下。
    func queue(for item: RecentItem, localDirectory: URL? = nil) -> PlaybackQueue? {
        let key = RecentStore.key(of: item)
        guard let group = snapshot.byKey[key], let stored = snapshot.groups[group] else { return nil }
        let sources = stored.map { entry -> PlaybackSource in
            if case .direct(let title, let url) = entry, url.isFileURL, let localDirectory {
                return .direct(title: title, url: localDirectory.appendingPathComponent(url.lastPathComponent))
            }
            return entry.source
        }
        guard let current = sources.first(where: { RecentStore.key(for: $0) == key }) else { return nil }
        return PlaybackQueue(source: current, items: sources)
    }

    /// 只留还在观看记录里的条目，以及它们还在用的列表
    private func prune(keeping liveKeys: Set<String>) {
        snapshot.byKey = snapshot.byKey.filter { liveKeys.contains($0.key) }
        let used = Set(snapshot.byKey.values)
        snapshot.groups = snapshot.groups.filter { used.contains($0.key) }
    }

    /// 切集很频繁：合并成一次，在后台写文件
    private func scheduleSave() {
        guard let fileURL else { return }
        saveTask?.cancel()
        let snapshot = self.snapshot
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
