import SwiftUI

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
    @StateObject private var recents = RecentStore.shared
    @StateObject private var mediaLibrary = MediaLibraryStore()
    @StateObject private var localStore = LocalMediaStore()
    @StateObject private var metadataStore = MediaMetadataStore(concurrency: 3, performerLookup: { code, contentID in
        await MetadataSearch.shared.performers(for: code, contentID: contentID)
    })
    @StateObject private var scanner = CloudLibraryScanner()
    @State private var selection: HomeSection = .home
    @State private var restored = false
    private let appState: AppState

    /// init 会在上层页面每次刷新时被重新调用，这里不做任何读盘或联网，
    /// 恢复工作放到 restoreOnce，只执行一次。
    private var sourceStatus: P115Status?
    private var sourceQuota: QuotaResponse?
    private var initialSearch = ""
    private var searchFiles: [P115File] = []

    init(appState: AppState, initialSection: HomeSection = .home,
         library: MediaLibraryStore? = nil, local: LocalMediaStore? = nil,
         metadata: MediaMetadataStore? = nil, recents: RecentStore? = nil,
         sourceStatus: P115Status? = nil, sourceQuota: QuotaResponse? = nil,
         initialSearch: String = "", searchFiles: [P115File] = []) {
        self.appState = appState
        _selection = State(initialValue: initialSection)
        if let library { _mediaLibrary = StateObject(wrappedValue: library) }
        if let local { _localStore = StateObject(wrappedValue: local) }
        if let metadata { _metadataStore = StateObject(wrappedValue: metadata) }
        if let recents { _recents = StateObject(wrappedValue: recents) }
        self.sourceStatus = sourceStatus; self.sourceQuota = sourceQuota
        self.initialSearch = initialSearch; self.searchFiles = searchFiles
    }

    private func restoreOnce() {
        guard !restored, !InterfacePreview.active else { return }
        restored = true
        scanner.selectAccount(appState.libraryAccountID)
        // 扫描检查点先于首页恢复，避免上次退出时的最后一批文件遗漏。
        mediaLibrary.add(scanner.discoveredFiles, for: appState)
        metadataStore.hydrate(files: HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState))
    }

    var body: some View {
        tabs
            .onAppear(perform: restoreOnce)
            .task(id: syncInput) {
                guard !InterfacePreview.active else { return }
                if scanner.accountID != appState.libraryAccountID {
                    metadataStore.pause()
                    scanner.selectAccount(appState.libraryAccountID)
                    mediaLibrary.add(scanner.discoveredFiles, for: appState)
                }
                metadataStore.hydrate(files: libraryFiles)
                if scenePhase == .background {
                    scanner.pause()
                    metadataStore.pause()
                    mediaLibrary.flush()
                } else {
                    metadataStore.sync(files: libraryFiles)
                }
            }
            .onChange(of: adultMatching) { enabled in
                metadataStore.pause()
                guard scenePhase != .background else { return }
                if enabled { metadataStore.retryFailed(files: libraryFiles) }
                else { metadataStore.sync(files: libraryFiles) }
            }
            .environmentObject(recents)
            .environmentObject(mediaLibrary)
            .environmentObject(localStore)
            .environmentObject(metadataStore)
            .environmentObject(scanner)
            .tint(Theme.accent)
    }

    private var libraryFiles: [LibraryMedia] {
        HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState)
    }

    /// Keep scanning/matching alive when moving between tabs; coalesce scan batches.
    private var syncInput: LibrarySyncInput {
        let count = localStore.files.count + mediaLibrary.files(for: appState).count
        return LibrarySyncInput(count: scanner.phase == .running ? count / 300 : count,
                                accountID: appState.libraryAccountID,
                                background: scenePhase == .background, scanning: scanner.phase == .running)
    }

    /// iOS 18 起用新的 Tab 写法，搜索标签带上 search 角色：iOS 26 上它会变成标签栏右侧单独的玻璃圆钮。
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selection) {
                Tab("首页", systemImage: "play.rectangle.on.rectangle.fill", value: HomeSection.home) {
                    HomeTab(onBrowseLibrary: { selection = .library })
                }
                Tab("资源库", systemImage: "square.stack.3d.up.fill", value: HomeSection.library) {
                    LibraryTab(initialStatus: sourceStatus, initialQuota: sourceQuota)
                }
                Tab("设置", systemImage: "gearshape.fill", value: HomeSection.settings) {
                    SettingsTab()
                }
                Tab("搜索", systemImage: "magnifyingglass", value: HomeSection.search, role: .search) {
                    SearchTab(initialQuery: initialSearch, initialResults: searchFiles)
                }
            }
        } else {
            TabView(selection: $selection) {
                HomeTab(onBrowseLibrary: { selection = .library })
                    .tag(HomeSection.home)
                    .tabItem {
                        Label("首页", systemImage: "play.rectangle.on.rectangle.fill")
                    }

                LibraryTab(initialStatus: sourceStatus, initialQuota: sourceQuota)
                    .tag(HomeSection.library)
                    .tabItem {
                        Label("资源库", systemImage: "square.stack.3d.up.fill")
                    }

                SettingsTab()
                    .tag(HomeSection.settings)
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }

                SearchTab(initialQuery: initialSearch, initialResults: searchFiles)
                    .tag(HomeSection.search)
                    .tabItem {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
            }
        }
    }
}

/// 底部标签
enum HomeSection: Hashable {
    case home, library, settings, search
}

private struct LibrarySyncInput: Equatable {
    let count: Int
    let accountID: String?
    let background: Bool
    let scanning: Bool
}
