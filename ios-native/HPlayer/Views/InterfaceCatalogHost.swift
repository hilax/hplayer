#if DEBUG
import SwiftUI

/// Launches production views with isolated stores for the 41-screen simulator audit.
/// No prototype screenshot is used as an application screen.
struct InterfaceCatalogHost: View {
    let screen: String
    @StateObject private var fixture = InterfaceCatalogData()
    @State private var ready = false
    @State private var selectedFiles: Set<Int> = [0, 1, 2, 3]
    @State private var savePath = "云下载 / 剧集"
    @State private var folderID = "20415876"

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
        .tint(Theme.accent)
        .preferredColorScheme(ProcessInfo.processInfo.environment["HPLAYER_DESIGN_STYLE"] == "light" ? .light : .dark)
        .task {
            await fixture.prepare(empty: screen == "home-empty")
            ready = true
        }
    }

    @ViewBuilder private var destination: some View {
        switch screen {
        case "home", "home-more", "home-empty", "add", "film-menu": tabs(.home)
        case "library", "library-empty": tabs(.library)
        case "settings": tabs(.settings)
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
        case "continue": NavigationStack { ContinueHistoryView(entries: fixture.history, onOpen: { _ in }, onRemove: { _ in }) }
        case "files", "files-select":
            NavigationStack {
                DirectoryView(cid: "100", trail: [Crumb(cid: "0", name: "根目录"), Crumb(cid: "100", name: "影视收藏")],
                              onOpenDir: { _ in }, onPlay: { _, _ in }, initialFiles: fixture.directory,
                              initialSelection: screen == "files-select" ? ["movie-0", "movie-1"] : nil)
                    .navigationTitle("115 网盘")
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
        case "official": NavigationStack {
            Official115SettingsView(onSourceChanged: {}, initialStatus: Open115Status(configured: true, authorized: false, message: nil, userName: nil),
                                    initialAuthorization: Open115Start(verificationUri: "https://115.com/?interface-preview=1", userCode: "H7KP 2N", expiresIn: 300))
        }
        case "licenses": NavigationStack { LicensesView() }
        case "magnet": NavigationStack { MagnetPlayerView(initialMagnet: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789") }
        case "resolving": NavigationStack { MagnetPlayerView(controller: .interfaceFixture()) }
        case "magnet-files": NavigationStack { MagnetPlayerView(controller: .interfaceFixture(catalog: fixture.magnetCatalog)) }
        case "torrent": NavigationStack { TorrentView(initialTasks: fixture.torrentTasks) }
        case "torrent-files": NavigationStack {
            TorrentSelectionView(info: fixture.torrent, selected: $selectedFiles, savePath: $savePath, folderId: $folderID, busy: false, error: "", onSubmit: {})
        }
        case "portrait", "landscape", "playback", "tracks", "episodes", "aspect":
            InterfacePlayerHost()
        default: Text("未知原型页面：\(screen)")
        }
    }

    private func tabs(_ section: HomeSection) -> some View {
        HomeView(appState: fixture.account, initialSection: section, library: fixture.library, local: fixture.local,
                 metadata: fixture.metadata, recents: fixture.recents,
                 sourceStatus: screen == "library-empty" ? nil : P115Status(configured: true, userId: 999, userName: "Hilax 的私人片库", vip: 1, error: nil, message: nil),
                 sourceQuota: screen == "library-empty" ? nil : QuotaResponse(usedText: "2.4 TB", totalText: "5 TB", usedBytes: 2_640_000_000_000, totalBytes: 5_500_000_000_000),
                 initialSearch: screen == "search-results" ? "沙丘" : screen == "search-empty" ? "未找到的影片" : "",
                 searchFiles: screen == "search-results" ? Array(fixture.directory.filter { !$0.isDir }.prefix(2)) : [])
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
    private(set) var snapshot = HomeSnapshot(items: [])
    private(set) var history: [ContinueEntry] = []
    private let defaults: UserDefaults
    private let base = "http://127.0.0.1:8765/design-art/"

    init() {
        let suite = "hplayer.interface-catalog"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
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
    var torrent: TorrentInfo {
        let files = (0..<5).map { TorrentEntry(index: $0, path: "Severance.S01E\(String(format: "%02d", $0 + 1)).mkv", size: 1_420_000_000, wanted: true) }
            + [TorrentEntry(index: 5, path: "readme.txt", size: 2048, wanted: false)]
        return TorrentInfo(name: "Severance.S01.1080p", infoHash: "fixture", sha1: "fixture", pickCode: "fixture", size: 7_100_002_048, files: files)
    }
    var torrentTasks: TorrentTasks {
        TorrentTasks(page: 1, pageCount: 1, count: 2, tasks: [
            TorrentTask(id: "1", name: "Dune.Part.Two.2024.2160p", progress: 68, size: 26_800_000_000, status: 1),
            TorrentTask(id: "2", name: "Severance.S01.1080p", progress: 100, size: 12_800_000_000, status: 2)])
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
            .fullScreenCover(isPresented: $presenting) {
                PlayerView(source: .direct(title: "人生切割术 · 第 3 集", url: url), playlist: (1...9).map { .direct(title: "人生切割术 · 第 \($0) 集", url: url) })
            }
    }
}
#endif
