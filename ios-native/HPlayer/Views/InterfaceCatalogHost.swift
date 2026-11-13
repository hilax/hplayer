#if DEBUG
import SwiftUI

/// Launches production views with isolated stores for the 47-screen simulator audit.
/// No prototype screenshot is used as an application screen.
struct InterfaceCatalogHost: View {
    let screen: String
    @StateObject private var fixture = InterfaceCatalogData()
    /// 剧集详情从这里读分组；正式应用里由 HomeView 提供，单独打开的检查页要自己备一份。
    @StateObject private var snapshots = LibrarySnapshotStore()
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                destination
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("catalog.\(screen)")
            } else { ProgressView("准备界面数据") }
        }
        .environmentObject(fixture.account)
        .environmentObject(fixture.library)
        .environmentObject(fixture.local)
        .environmentObject(fixture.metadata)
        .environmentObject(fixture.recents)
        .environmentObject(fixture.scanner)
        .environmentObject(snapshots)
        .tint(Theme.accent)
        .preferredColorScheme(ProcessInfo.processInfo.environment["HPLAYER_DESIGN_STYLE"] == "light" ? .light : .dark)
        .task {
            await fixture.prepare(empty: screen == "home-empty")
            snapshots.seed(fixture.snapshot)
            ready = true
        }
    }

    @ViewBuilder private var destination: some View {
        switch screen {
        case "home", "home-more", "home-empty", "add", "film-menu": tabs(.home)
        case "library", "library-empty": tabs(.cloud)
        case "catalog": tabs(.home, channel: .library)
        case "magnet-tab": tabs(.magnet)
        case "settings": tabs(.mine)
        case "search", "search-results", "search-empty": tabs(.search)
        case "movies":
            NavigationStack {
                PosterGridScreen(title: "电影", items: fixture.snapshot.movies) { item, width in
                    PosterCard(item: item, width: width, onPlay: {}, onDelete: {}, onMatch: {})
                }
            }
        case "series":
            NavigationStack {
                PosterGridScreen(title: "剧集", items: fixture.snapshot.series) { group, width in
                    NavigationLink { SeriesDetailView(seriesID: group.id) } label: { SeriesPosterCard(group: group, width: width) }.buttonStyle(.plain)
                }
            }
        case "people":
            NavigationStack {
                PerformerGridView(groups: fixture.snapshot.performers)
                    .navigationDestination(for: PerformerRoute.self) { route in
                        if let group = fixture.snapshot.performers.first(where: { $0.id == route.id }) { PerformerCollectionView(group: group) }
                    }
            }
        case "person": NavigationStack { PerformerCollectionView(group: fixture.snapshot.performers[0]) }
        case "detail": NavigationStack { SeriesDetailView(seriesID: "tt11280740") }
        case "continue": NavigationStack { ContinueHistoryFixture(entries: fixture.history) }
        case "files", "files-select", "files-menu", "files-delete", "files-move", "file-info":
            NavigationStack {
                DirectoryView(cid: "100", trail: fixture.trail, onOpenDir: { _ in }, onPlay: { _, _ in },
                              management: true, onOpenPage: { _ in }, initialFiles: fixture.directory,
                              initialSelection: managementSelection, initialSheet: managementSheet,
                              initialInfo: screen == "file-info" ? fixture.fileInfo : nil)
                    .navigationTitle("115 网盘")
            }
        case "files-import":
            // 导入流程里的目录选择（只能选视频），不属于原型截图，供批量选择的交互测试使用
            NavigationStack {
                DirectoryView(cid: "100", trail: fixture.trail, onOpenDir: { _ in }, onPlay: { _, _ in },
                              initialFiles: fixture.directory, initialSelection: ["movie-0", "movie-1"])
                    .navigationTitle("115 网盘")
            }
        case "recycle":
            NavigationStack {
                RecycleBinView(initialItems: fixture.recycleItems, initialSelection: ["9003", "9004"])
            }
        case "offline":
            NavigationStack {
                OfflineTasksView(initialTasks: fixture.offlineTasks, initialFilter: .running,
                                 initialFolderLabels: fixture.offlineFolders)
            }
        case "watchlist": NavigationStack { AnimeWatchlistView() }
        case "magnet-history": NavigationStack { MagnetHistoryView() }
        case "offline-add":
            OfflineAddPreviewHost(tasks: fixture.offlineTasks, folders: fixture.offlineFolders)
        case "downloads":
            NavigationStack {
                DownloadsView(manager: fixture.downloads, initialTab: "active", fixedStorage: fixture.downloadStorage)
            }
        case "local": NavigationStack { LocalVideosView() }
        case "manage": HomeLibraryScanView(onStart: { _ in }, onStartFolder: { _, _ in }, onRetryMatching: {})
        case "folder-picker": ScanFolderPicker(onSelect: { _, _ in }, initialFolders: fixture.directory.filter(\.isDir))
        case "unmatched": NavigationStack { HomeUnmatchedMediaView() }
        case "match": MetadataMatchView(file: fixture.unmatched, current: nil, onMatch: { _ in }, initialQuery: "Arrival", initialResults: [fixture.movies[3], fixture.movies[0]])
        case "metadata": NavigationStack { MetadataSourcesView() }
        case "credentials": NavigationStack { MetadataCredentialsView() }
        case "appearance": NavigationStack { AppearanceSettingsView() }
        case "connect115": NavigationStack { CookieWebLoginView(onConnected: {}) }
        case "licenses": NavigationStack { LicensesView() }
        case "magnet": NavigationStack { MagnetPlayerView(initialMagnet: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789") }
        case "resolving": NavigationStack { MagnetPlayerView(controller: .interfaceFixture()) }
        case "magnet-files": NavigationStack { MagnetPlayerView(controller: .interfaceFixture(catalog: fixture.magnetCatalog)) }
        case "portrait", "landscape", "playback", "tracks", "episodes", "aspect", "sleep":
            InterfacePlayerHost()
        default: Text("未知原型页面：\(screen)")
        }
    }

    /// 多选、删除确认、移动面板这几页都停在「已选 3 项：1 个文件夹 + 2 个视频」的状态
    private static let selectedFixtureIDs: Set<String> = ["dir-3", "movie-0", "movie-1"]

    private var managementSelection: Set<String>? {
        ["files-select", "files-delete", "files-move"].contains(screen) ? Self.selectedFixtureIDs : nil
    }

    private var managementSheet: DirectorySheet? {
        let chosen = fixture.directory.filter { Self.selectedFixtureIDs.contains($0.id) }
        switch screen {
        case "files-delete": return .delete(chosen)
        case "files-move": return .destination(chosen, .move)
        case "file-info":
            guard let file = fixture.directory.first(where: { $0.id == "movie-0" }) else { return nil }
            return .info(file)
        default: return nil
        }
    }

    private func tabs(_ section: HomeSection, channel: HomeChannel = .recommend) -> some View {
        HomeView(appState: fixture.account, initialSection: section, initialChannel: channel, library: fixture.library, local: fixture.local,
                 metadata: fixture.metadata, recents: fixture.recents,
                 sourceStatus: screen == "library-empty" ? nil : P115Status(configured: true, userId: 999, userName: "Hilax 的私人片库", vip: 1, error: nil, message: nil),
                 sourceQuota: screen == "library-empty" ? nil : QuotaResponse(usedText: "2.4 TB", totalText: "5 TB", usedBytes: 2_640_000_000_000, totalBytes: 5_500_000_000_000),
                 initialSearch: screen == "search-results" ? "沙丘" : screen == "search-empty" ? "未找到的影片" : "",
                 searchFiles: screen == "search-results" ? Array(fixture.directory.filter { !$0.isDir }.prefix(2)) : [])
    }
}

/// 离线下载页上叠着「添加离线任务」面板，链接已经填好，用来检查识别结果和保存设置。
private struct OfflineAddPreviewHost: View {
    let tasks: [Direct115OfflineTask]
    let folders: [String: String]
    @State private var presenting = true

    private static let links = "magnet:?xt=urn:btih:8E3F1C7A92B04D5E6F8091A2B3C4D5E6F7081920&dn=sample\nhttps://example.com/files/sample-movie.mp4"

    var body: some View {
        NavigationStack {
            OfflineTasksView(initialTasks: tasks, initialFilter: .running, initialFolderLabels: folders)
        }
        .sheet(isPresented: $presenting) {
            OfflineAddSheet(client: nil, initialText: Self.links) { _ in }
        }
    }
}

/// Mutable fixture for exercising list updates without touching real history.
private struct ContinueHistoryFixture: View {
    @State private var entries: [ContinueEntry]
    private let motionTest = ProcessInfo.processInfo.environment["HPLAYER_HISTORY_MOTION_TEST"] == "1"
    private let reduced = ProcessInfo.processInfo.environment["HPLAYER_REDUCE_MOTION_TEST"] == "1"

    init(entries: [ContinueEntry]) { _entries = State(initialValue: entries) }

    var body: some View {
        Group {
            if reduced { history.environment(\.testReducedMotion, true) }
            else { history }
        }
    }

    private var history: some View {
        ContinueHistoryView(entries: entries, onOpen: { _ in }, onRemove: { entry in
            entries.removeAll { $0.id == entry.id }
        })
        .toolbar {
            if motionTest {
                ToolbarItem(placement: .topBarLeading) {
                    Button("更新进度") { updateProgress() }.accessibilityIdentifier("history.testProgress")
                }
            }
        }
    }

    private func updateProgress() {
        guard let first = entries.first else { return }
        entries[0] = ContinueEntry(id: first.id, target: first.target, title: first.title,
                                   subtitle: first.subtitle, tag: first.tag, artworkURL: first.artworkURL,
                                   progress: 0.8, date: first.date, libraryItem: first.libraryItem)
    }
}

@MainActor
private final class InterfaceCatalogData: ObservableObject {
    let account: AppState
    let library: MediaLibraryStore
    let local: LocalMediaStore
    let metadata: MediaMetadataStore
    let recents: RecentStore
    let scanner = CloudLibraryScanner()
    /// 下载管理页用的下载记录，放在临时目录里，不碰真实的下载列表
    let downloads: DownloadManager
    private(set) var snapshot = HomeSnapshot(items: [])
    private(set) var history: [ContinueEntry] = []
    private let defaults: UserDefaults
    private let base = "http://127.0.0.1:8765/design-art/"

    init() {
        let suite = "hplayer.interface-catalog"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let downloadsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("InterfaceCatalogDownloads", isDirectory: true)
        try? FileManager.default.removeItem(at: downloadsRoot)
        downloads = DownloadManager(storeURL: downloadsRoot.appendingPathComponent("downloads.json"),
                                    partsDirectory: downloadsRoot.appendingPathComponent("parts", isDirectory: true),
                                    looseDirectory: downloadsRoot.appendingPathComponent("loose", isDirectory: true))
        account = AppState(cookieLoader: { InterfacePreview.screen == "library-empty" ? nil : "UID=999_fixture; CID=fixture; SEID=fixture; KID=fixture" })
        library = MediaLibraryStore(defaults: defaults)
        metadata = MediaMetadataStore(defaults: defaults, lookup: { _ in nil })
        recents = RecentStore(defaults: defaults)
        local = LocalMediaStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("InterfaceCatalog", isDirectory: true))
    }

    var movies: [MediaMetadata] {
        [makeMetadata("dune", "tt15239678", "沙丘 2", "2024", "8.5"),
         makeMetadata("interstellar", "tt0816692", "星际穿越", "2014", "8.7"),
         makeMetadata("blade", "tt1856101", "银翼杀手 2049", "2017", "8.0"),
         makeMetadata("arrival", "tt2543164", "降临", "2016", "7.9")]
    }
    private func makeMetadata(_ art: String, _ id: String, _ title: String, _ year: String, _ rating: String, series: Bool = false) -> MediaMetadata {
        var value = MediaMetadata(imdbID: id, type: series ? "series" : "movie", title: title, year: year,
                                 posterURL: base + art + "-poster.jpg", backgroundURL: base + art + "-background.jpg", logoURL: "",
                                 overview: series ? "当工作与生活的记忆被完全分开，一段看似平静的日常，开始浮现出意想不到的秘密。" : "命运的沙海，再次掀起波澜。保罗与弗雷曼人一同踏上新的征程。",
                                 rating: rating, genres: series ? ["科幻", "悬疑"] : ["科幻", "冒险"], country: "United States", season: nil, episode: nil)
        if art == "dune" || art == "interstellar" { value.performers = ["提莫西·查拉梅"] }
        return value
    }
    private func file(_ id: String, _ name: String, directory: Bool = false, size: Int = 2_640_000_000) -> P115File {
        P115File(id: id, parentId: "100", name: name, isDir: directory, kind: directory ? "folder" : "video", size: directory ? 0 : size,
                 pickCode: directory ? "" : "preview-" + id, sha1: "", updatedAt: "2026-10-31 12:00", thumbUrl: "")
    }
    var directory: [P115File] {
        [file("dir-1", "电影", directory: true), file("dir-2", "剧集", directory: true), file("dir-3", "纪录片", directory: true)] +
        [file("movie-0", "Dune.Part.Two.2024.2160p.mkv", size: 26_400_000_000), file("movie-1", "Interstellar.2014.2160p.mkv", size: 32_800_000_000),
         file("movie-2", "Blade.Runner.2049.2160p.mkv", size: 28_100_000_000), file("movie-3", "Arrival.2016.1080p.mkv", size: 8_200_000_000)]
    }
    var unmatched: LibraryMedia { LibraryMedia(cloud: file("unmatched", "Arrival.2016.1080p.WEB-DL.mkv", size: 8_200_000_000)) }
    var trail: [Crumb] { [Crumb(cid: "0", name: "根目录"), Crumb(cid: "100", name: "影视收藏")] }

    /// 「文件信息」页的详细信息（正式使用时从 115 读取）
    var fileInfo: Direct115FileInfo {
        Direct115FileInfo(name: "Dune.Part.Two.2024.2160p.mkv", isDirectory: false, pickCode: "preview-movie-0",
                          sha1: "3F2A91C07B5E4D18A6C0E52F9B7D134A8E60C2D5", location: ["网盘", "影视收藏"],
                          fileCount: 0, folderCount: 0, sizeText: "24.59GB",
                          createdAt: Date(timeIntervalSince1970: 1_793_191_860), modifiedAt: Date(timeIntervalSince1970: 1_793_193_240))
    }

    /// 回收站：一个文件夹、三个视频、一个旧文件夹
    var recycleItems: [Direct115RecycleItem] {
        let now = Date()
        return [
            Direct115RecycleItem(id: "9001", name: "待整理", size: 0, parentName: "影视收藏",
                                 deletedAt: now.addingTimeInterval(-3_600), isDirectory: true),
            Direct115RecycleItem(id: "9002", name: "Dune.Part.Two.2024.2160p.mkv", size: 4_692_251_770, parentName: "电影",
                                 deletedAt: now.addingTimeInterval(-3_600), isDirectory: false),
            Direct115RecycleItem(id: "9003", name: "Interstellar.2014.1080p.mp4", size: 1_954_210_119, parentName: "电影",
                                 deletedAt: now.addingTimeInterval(-26 * 3_600), isDirectory: false),
            Direct115RecycleItem(id: "9004", name: "Arrival.2016.1080p.mkv", size: 7_569_879_859, parentName: "电影",
                                 deletedAt: now.addingTimeInterval(-5 * 86_400), isDirectory: false),
            Direct115RecycleItem(id: "9005", name: "旧备份", size: 0, parentName: "",
                                 deletedAt: now.addingTimeInterval(-9 * 86_400), isDirectory: true),
        ]
    }

    /// 离线下载：三个进行中（一个在等资源）、两个已完成、一个失败
    var offlineTasks: [Direct115OfflineTask] {
        let now = Date()
        return [
            Direct115OfflineTask(infoHash: "8e3f1c7a92b04d5e6f8091a2b3c4d5e6f7081920", name: "Dune.Part.Two.2024.2160p.WEB-DL.mkv",
                                 size: 9_921_374_453, status: .downloading, percent: 63, fileID: "", folderID: "20415876",
                                 remoteHash: "8e3f1c7a92b04d5e6f8091a2b3c4d5e6f7081920",
                                 sourceURL: "magnet:?xt=urn:btih:8e3f1c7a92b04d5e6f8091a2b3c4d5e6f7081920",
                                 addedAt: now.addingTimeInterval(-1_800), speed: 3_565_158, remainingSeconds: 1_020),
            Direct115OfflineTask(infoHash: "5b8d2a41c7e9f03b6a1d4c8e2f7a9b3c5d6e7f80", name: "Severance.S02.Complete.1080p",
                                 size: 16_965_120_819, status: .downloading, percent: 12, fileID: "", folderID: "20415877",
                                 remoteHash: "5b8d2a41c7e9f03b6a1d4c8e2f7a9b3c5d6e7f80",
                                 sourceURL: "https://example.com/files/severance-s02.zip",
                                 addedAt: now.addingTimeInterval(-3_600), speed: 1_153_433, remainingSeconds: 10_800),
            Direct115OfflineTask(infoHash: "c4a7e1b9d2f60385a1c7e9b3d5f70246a8c0e1f3", name: "Arrival.2016.1080p.mp4",
                                 size: 0, status: .waiting, percent: 0, fileID: "", folderID: "20415876",
                                 remoteHash: "c4a7e1b9d2f60385a1c7e9b3d5f70246a8c0e1f3",
                                 sourceURL: "magnet:?xt=urn:btih:c4a7e1b9d2f60385a1c7e9b3d5f70246a8c0e1f3",
                                 addedAt: now.addingTimeInterval(-300)),
            Direct115OfflineTask(infoHash: "1f2e3d4c5b6a79880918273645546372819a0b1c", name: "Interstellar.2014.2160p.mkv",
                                 size: 32_800_000_000, status: .done, percent: 100, fileID: "3300001", folderID: "20415876",
                                 remoteHash: "1f2e3d4c5b6a79880918273645546372819a0b1c",
                                 sourceURL: "magnet:?xt=urn:btih:1f2e3d4c5b6a79880918273645546372819a0b1c",
                                 addedAt: now.addingTimeInterval(-86_400)),
            Direct115OfflineTask(infoHash: "9a8b7c6d5e4f30211203948576a6b7c8d9e0f1a2", name: "Planet.Earth.II.2016.1080p",
                                 size: 12_800_000_000, status: .done, percent: 100, fileID: "3300002", folderID: "20415877",
                                 remoteHash: "9a8b7c6d5e4f30211203948576a6b7c8d9e0f1a2",
                                 sourceURL: "magnet:?xt=urn:btih:9a8b7c6d5e4f30211203948576a6b7c8d9e0f1a2",
                                 addedAt: now.addingTimeInterval(-2 * 86_400)),
            Direct115OfflineTask(infoHash: "0d1c2b3a49586776655443322110ffeeddccbbaa", name: "Blade.Runner.2049.2160p.mkv",
                                 size: 28_100_000_000, status: .failed, percent: 0, fileID: "", folderID: "20415876",
                                 remoteHash: "0d1c2b3a49586776655443322110ffeeddccbbaa",
                                 sourceURL: "magnet:?xt=urn:btih:0d1c2b3a49586776655443322110ffeeddccbbaa",
                                 addedAt: now.addingTimeInterval(-3 * 86_400)),
        ]
    }

    var offlineFolders: [String: String] { ["20415876": "网盘 / 电影", "20415877": "网盘 / 电视剧"] }

    var downloadStorage: DownloadStorageSummary {
        DownloadStorageSummary(libraryBytes: 8_400_000_000, freeBytes: 46_200_000_000, totalBytes: 256_000_000_000)
    }

    /// 下载管理：一个正在下载、一个已暂停，三个已完成（最近一个刚刚完成）。
    /// 已完成的文件名要和本地视频库里写入的占位文件对上，页面才会显示「播放」。
    private func configureDownloads() {
        downloads.media = local
        let now = Date()
        func item(_ name: String, total: Int64, received: Int64, state: DownloadItem.State,
                  finished: Date? = nil, saved: String? = nil) -> DownloadItem {
            DownloadItem(id: UUID(), fileID: "dl-" + name, pickCode: "dl-" + name, name: name, isVideo: true,
                         totalBytes: total, folderLabel: "网盘 / 电影", state: state, receivedBytes: received, message: "",
                         addedAt: now.addingTimeInterval(-7_200), finishedAt: finished, savedName: saved, savedInLibrary: saved != nil)
        }
        let running = item("Dune.Part.Two.2024.2160p.mkv", total: 4_692_251_770, received: 1_923_823_225, state: .downloading)
        let paused = item("Interstellar.2014.1080p.mp4", total: 1_954_210_119, received: 1_426_573_386, state: .paused)
        let justNow = item("Arrival.2016.1080p.mkv", total: 7_569_879_859, received: 7_569_879_859, state: .completed,
                           finished: now.addingTimeInterval(-120), saved: "Arrival.2016.mkv")
        let yesterday = item("Interstellar.2014.2160p.mkv", total: 32_800_000_000, received: 32_800_000_000, state: .completed,
                             finished: now.addingTimeInterval(-86_400), saved: "Interstellar.2014.mp4")
        let older = item("Planet.Earth.II.E01.mp4", total: 2_100_000_000, received: 2_100_000_000, state: .completed,
                         finished: now.addingTimeInterval(-3 * 86_400), saved: "Planet.Earth.II.E01.mp4")
        downloads.setItemsForPreview([running, paused, justNow, yesterday, older], speeds: [running.id: 8_598_323])
    }
    var magnetCatalog: MagnetCatalog {
        MagnetCatalog(cloudVideos: (1...9).map { Direct115CloudVideo(file: file("episode-\($0)", "Severance.S01E\(String(format: "%02d", $0)).mkv", size: 1_420_000_000), folder: "") }, name: "人生切割术 · 第 1 季", totalSize: 12_800_000_000)
    }

    func prepare(empty: Bool) async {
        UserDefaults.standard.set("system", forKey: AppearanceMode.storageKey)
        UserDefaults.standard.set(InterfacePreview.screen == "manage" || InterfacePreview.screen == "metadata", forKey: AdultMetadataSettings.enabledKey)
        for file in local.files { local.delete(file) }
        guard !empty else { return }
        let cloud = Array(directory.filter { !$0.isDir })
        library.add(cloud + [file("unmatched", unmatched.name), file("unmatched-2", "Documentary.2160p.mkv")], for: account)
        for (index, file) in cloud.enumerated() { await metadata.match(movies[index], to: LibraryMedia(cloud: file)) }
        let severance = makeMetadata("severance", "tt11280740", "人生切割术", "2022", "8.7", series: true)
        let silo = makeMetadata("silo", "tt14688458", "末日地堡", "2023", "8.1", series: true)
        for season in 1...2 {
            let episodes = (1...5).map { file("s\(season)-\($0)", "Severance.S0\(season)E\(String(format: "%02d", $0)).mkv") }
            library.add(episodes, for: account)
            for file in episodes { await metadata.match(severance, to: LibraryMedia(cloud: file)) }
        }
        let second = file("silo", "Silo.S01E01.mkv")
        library.add([second], for: account)
        await metadata.match(silo, to: LibraryMedia(cloud: second))
        let localNames = ["Interstellar.2014.mp4", "Arrival.2016.mkv", "Planet.Earth.II.E01.mp4"]
        for name in localNames { try? Data(repeating: 0, count: 1024).write(to: local.mediaDirectory.appendingPathComponent(name)) }
        local.refresh()
        configureDownloads()
        if InterfacePreview.screen == "offline-add" {
            // 添加面板的「保存位置」一栏显示上次选过的文件夹
            UserDefaults.standard.set("20415876", forKey: "hplayer.offline.saveFolderID")
            UserDefaults.standard.set("网盘 / 电影", forKey: "hplayer.offline.saveFolderPath")
        }
        for file in local.files {
            let item = file.name.hasPrefix("Arrival") ? movies[3] : file.name.hasPrefix("Interstellar") ? movies[1] : makeMetadata("planet", "tt5491994", "地球脉动 II", "2016", "9.5", series: true)
            await metadata.match(item, to: LibraryMedia(local: file))
        }
        snapshot = HomeLibrary.snapshot(local: local, cloud: library, metadata: metadata, appState: account)
        // Cloud first makes the featured shot mirror the reviewed prototype.
        snapshot = HomeSnapshot(items: snapshot.items.sorted { $0.isCloud && !$1.isCloud })
        for (offset, item) in snapshot.movies.prefix(3).enumerated() {
            recents.record(item.media.source)
            recents.savePosition(for: item.media.source, seconds: Double(4360 - offset * 900), duration: 9960)
        }
        history = snapshot.movies.prefix(3).enumerated().map { offset, item in
            let recent = recents.items.first { $0.title == item.media.name }!
            return ContinueEntry(id: recent.id, target: .recent(recent), title: item.title, subtitle: "已看 \(playbackTimeText(Double(4360 - offset * 900))) · \(item.sourceLabel)", tag: "115", artworkURL: item.backgroundURL, progress: Double(44 - offset * 10) / 100, date: Date(), libraryItem: item)
        }
        ImagePipeline.shared.prefetch(HomeArtwork.prefetchRequests(snapshot, selection: 0))
    }
}

private struct InterfacePlayerHost: View {
    @State private var presenting = false
    private let url = URL(string: "http://127.0.0.1:8765/hls-fixture/index.m3u8")!
    var body: some View {
        Color.black.ignoresSafeArea()
            .task { presenting = true }
            .playerWindow(isPresented: $presenting) {
                PlayerView(source: .direct(title: "人生切割术 · 第 3 集", url: url), playlist: (1...9).map { .direct(title: "人生切割术 · 第 \($0) 集", url: url) })
            }
    }
}
#endif
