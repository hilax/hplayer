import SwiftUI

@main
struct HPlayerApp: App {
    @UIApplicationDelegateAdaptor(HPlayerAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let mode = ProcessInfo.processInfo.environment["HPLAYER_PERFORMER_TEST"] {
                    PerformerNavigationUITestHost(mode: mode)
                } else if let style = ProcessInfo.processInfo.environment["HPLAYER_SCAN_TEST_STYLE"] {
                    ScanUITestHost()
                        .preferredColorScheme(style == "dark" ? .dark : .light)
                } else if ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1" {
                    HomeUITestHost()
                } else if let value = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"], let url = URL(string: value) {
                    let first = PlaybackSource.direct(title: "测试影片", url: url)
                    let second = PlaybackSource.direct(title: "测试下一集", url: url)
                    PlayerUITestHost(first: first, second: second)
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environmentObject(appState)
            .onAppear { AppearanceController.apply(appearance) }
            .onChange(of: appearance) { mode in AppearanceController.apply(mode) }
        }
    }
}

#if DEBUG
/// mode：
/// - 其他值（"1"）：文字卡片，只测导航本身。
/// - "wide"：和首页「演员合集」一样的横版封面卡片（真实的 PosterArtwork 和 PosterButtonStyle）。
/// - "legacy"：封面点击区域修复之前的卡片写法，只用来确认问题能复现。
private struct PerformerNavigationUITestHost: View {
    enum Style { case plain, wide, legacy }

    private let style: Style
    private let groups: [PerformerGroup]

    init(mode: String) {
        let style: Style = mode == "wide" ? .wide : (mode == "legacy" ? .legacy : .plain)
        self.style = style
        if style != .plain { WideJacketFixture.seed() }
        groups = Self.makeGroups(wide: style != .plain)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: style == .plain ? 20 : 14) {
                    ForEach(groups) { group in
                        card(group)
                    }
                }
                .padding(.horizontal, style == .plain ? 20 : 18)
                .padding(.vertical, style == .plain ? 20 : 4)
            }
            .navigationTitle("演员合集")
            .navigationDestination(for: PerformerRoute.self) { route in
                if let group = groups.first(where: { $0.id == route.id }) {
                    PerformerCollectionView(group: group)
                        .id(route.id)
                }
            }
        }
    }

    @ViewBuilder private func card(_ group: PerformerGroup) -> some View {
        switch style {
        case .plain:
            PerformerNavigationLink(group: group) {
                Text(group.name)
                    .font(.title2)
                    .frame(width: 160, height: 220)
                    .background(Theme.surface)
            }
            .accessibilityIdentifier("performerTest.\(group.id)")
        case .wide:
            PerformerNavigationLink(group: group) {
                VStack(alignment: .leading, spacing: 9) {
                    PosterArtwork(urlString: group.posterURL, title: group.name, width: 118, alignment: .trailing)
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(width: 118, alignment: .leading)
                }
            }
            .accessibilityIdentifier("performerTest.\(group.id)")
            .buttonStyle(PosterButtonStyle())
        case .legacy:
            PerformerNavigationLink(group: group) {
                VStack(alignment: .leading, spacing: 9) {
                    LegacyPosterArtwork(urlString: group.posterURL, title: group.name)
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(width: 118, alignment: .leading)
                }
            }
            .accessibilityIdentifier("performerTest.\(group.id)")
            .buttonStyle(LegacyPosterButtonStyle())
        }
    }

    private static func makeGroups(wide: Bool) -> [PerformerGroup] {
        let actorA = PerformerName.key("演员甲")
        let actorB = PerformerName.key("演员乙")
        let a1 = item("作品甲1", slug: "a1", wide: wide, performers: ["演员甲"])
        let a2 = item("作品甲2", slug: "a2", wide: wide, performers: ["演员甲"])
        let b1 = item("作品乙1", slug: "b1", wide: wide, performers: ["演员乙"])
        let b2 = item("作品乙2", slug: "b2", wide: wide, performers: ["演员乙"])
        return [
            PerformerGroup(id: actorA, name: "演员甲", items: [a1, a2, b1]),
            PerformerGroup(id: actorB, name: "演员乙", items: [b1, b2]),
        ]
    }

    private static func item(_ title: String, slug: String, wide: Bool, performers: [String]) -> HomeMediaItem {
        var metadata = MediaMetadata(
            imdbID: "fixture:\(title)", type: "movie", title: title, year: "2026",
            posterURL: wide ? WideJacketFixture.url(slug) : "https://images.example.org/\(title).jpg",
            backgroundURL: "", logoURL: "",
            overview: "", rating: "", genres: [], country: "Japan", season: nil, episode: nil
        )
        metadata.performers = performers
        if wide { metadata.source = MetadataSource.r18dev.rawValue }
        let media = LibraryMedia(local: LocalMedia(
            url: URL(fileURLWithPath: "/tmp/\(title).mp4"), size: 100, modified: .distantPast
        ))
        return HomeMediaItem(media: media, metadata: metadata)
    }
}

/// 横版封面（和 R18.dev 的封面一样是 800×538）。写进图片的磁盘缓存，界面按真实流程加载，不访问网络。
private enum WideJacketFixture {
    static func url(_ slug: String) -> String { "https://images.example.org/wide-\(slug).jpg" }

    static func seed() {
        let store = ImageDiskStore(directory: ImageDiskStore.defaultDirectory)
        let colors: [(String, UIColor)] = [("a1", .systemRed), ("a2", .systemBlue), ("b1", .systemGreen), ("b2", .systemOrange)]
        for (slug, color) in colors {
            guard let url = URL(string: url(slug)) else { continue }
            store.write(jpeg(color), for: url)
        }
    }

    private static func jpeg(_ color: UIColor) -> Data {
        let size = CGSize(width: 800, height: 538)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.7) { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// 修复之前的封面卡片：clipped 之后伸出去的那一截仍然接住点击。
private struct LegacyPosterArtwork: View {
    let urlString: String
    let title: String
    var width: CGFloat = 118

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(urlString: urlString, title: title)
                .scaledToFill()
                .frame(width: width, height: width * 1.5, alignment: .trailing)
                .clipped()
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct LegacyPosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// A real, idle scanner and empty stores let UI tests exercise the scan page
/// without a 115 session or any network requests.
private struct ScanUITestHost: View {
    @StateObject private var scanner = CloudLibraryScanner()
    @StateObject private var metadata = MediaMetadataStore()
    @StateObject private var library = MediaLibraryStore()
    @StateObject private var local = LocalMediaStore()

    var body: some View {
        HomeLibraryScanView(onStart: { _ in }, onStartFolder: { _, _ in }, onRetryMatching: {})
            .environmentObject(scanner)
            .environmentObject(metadata)
            .environmentObject(library)
            .environmentObject(local)
    }
}

private struct HomeUITestHost: View {
    @EnvironmentObject private var appState: AppState
    @State private var ready = false

    var body: some View {
        Group {
            if ready { HomeView(appState: appState) }
            else { ProgressView() }
        }.task {
            let store = LocalMediaStore()
            for name in ["The.Demon.Hunter.S01E71.2026.mkv", "Arrival.2016.mp4", "Dune.2021.mp4",
                         "仙逆.Renegade.Immortal.S01E05.2023.1080p.WEB-DL.mp4"] {
                let url = store.mediaDirectory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) { try? Data(name.utf8).write(to: url) }
            }
            ready = true
        }
    }
}

private struct PlayerUITestHost: View {
    let first: PlaybackSource
    let second: PlaybackSource
    @State private var presentingPlayer = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Text("播放器已关闭")
                .accessibilityIdentifier("playbackTest.previousPage")
            Button("重新播放测试视频") { presentingPlayer = true }
                .accessibilityIdentifier("playbackTest.reopen")
        }
            .task {
                await Task.yield()
                presentingPlayer = true
            }
            .fullScreenCover(isPresented: $presentingPlayer) {
                PlayerView(source: first, playlist: [first, second])
            }
    }
}
#endif
