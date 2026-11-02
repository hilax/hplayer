import SwiftUI

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
    @AppStorage(CoverMatchingSettings.automaticKey) private var automaticMatching = false
    @StateObject private var recents = RecentStore.shared
    @StateObject private var mediaLibrary = MediaLibraryStore()
    @StateObject private var localStore = LocalMediaStore()
    @StateObject private var metadataStore = MediaMetadataStore(concurrency: 3, restoring: true, performerLookup: { code, contentID in
        await MetadataSearch.shared.performers(for: code, contentID: contentID)
    })
    @StateObject private var scanner = CloudLibraryScanner()
    @StateObject private var accountInfo = P115AccountInfoStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: HomeSection = .home
    /// 去过的页面保持存活（滚动位置、搜索词都在），没去过的不提前创建。
    @State private var visited: Set<HomeSection> = [.home]
    /// 从搜索返回时回到进入搜索前所在的标签。
    @State private var lastTab: HomeSection = .home
    @StateObject private var tabBarVisibility = TabBarVisibility()
    /// 首页分类入口带过来的筛选；片库读取后会清空。
    @State private var catalogPreset: CatalogPreset?
    @State private var restored = false
    @ObservedObject private var appState: AppState

    /// init 会在上层页面每次刷新时被重新调用，这里不做任何读盘或联网，
    /// 恢复工作放到 restoreOnce，只执行一次。
    private var sourceStatus: P115Status?
    private var sourceQuota: QuotaResponse?
    private var initialSearch = ""
    private var searchFiles: [P115File] = []

    init(appState: AppState, initialSection: HomeSection = .home,
         library: MediaLibraryStore? = nil, local: LocalMediaStore? = nil,
         metadata: MediaMetadataStore? = nil, recents: RecentStore? = nil,
         accountInfo: P115AccountInfoStore? = nil,
         sourceStatus: P115Status? = nil, sourceQuota: QuotaResponse? = nil,
         initialSearch: String = "", searchFiles: [P115File] = []) {
        _appState = ObservedObject(wrappedValue: appState)
        _selection = State(initialValue: initialSection)
        _visited = State(initialValue: [initialSection])
        _lastTab = State(initialValue: initialSection == .search ? .home : initialSection)
        if let library { _mediaLibrary = StateObject(wrappedValue: library) }
        if let local { _localStore = StateObject(wrappedValue: local) }
        if let metadata { _metadataStore = StateObject(wrappedValue: metadata) }
        if let recents { _recents = StateObject(wrappedValue: recents) }
        if let accountInfo { _accountInfo = StateObject(wrappedValue: accountInfo) }
        self.sourceStatus = sourceStatus; self.sourceQuota = sourceQuota
        self.initialSearch = initialSearch; self.searchFiles = searchFiles
    }

    private func restoreOnce() {
        guard !restored else { return }
        if InterfacePreview.active {
            metadataStore.finishRestoring()
            return
        }
        restored = true
        scanner.selectAccount(appState.libraryAccountID)
        // 扫描检查点先于首页恢复，避免上次退出时的最后一批文件遗漏。
        mediaLibrary.add(scanner.discoveredFiles, for: appState)
        // 片名解析在后台线程做完再回来恢复封面，主线程不被整个片库的解析拖住。
        let files = HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState)
        Task { await metadataStore.restore(files: files) }
    }

    var body: some View {
        tabs
            .onAppear(perform: restoreOnce)
            .task(id: appState.sessionID) { await refreshAccountInfo() }
            .onChange(of: selection) { section in
                visited.insert(section)
                if section != .search { lastTab = section }
                if section == .cloud || section == .mine { Task { await refreshAccountInfo() } }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await refreshAccountInfo() } }
            }
            .task(id: syncInput) {
                guard !InterfacePreview.active else { return }
                await metadataStore.waitUntilRestored()
                guard !Task.isCancelled else { return }
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
                } else if automaticMatching || isHomeTest {
                    metadataStore.sync(files: libraryFiles)
                }
            }
            .onChange(of: automaticMatching) { enabled in
                if enabled && scenePhase != .background {
                    metadataStore.resumeAutomatic()
                    metadataStore.sync(files: libraryFiles)
                } else if !enabled {
                    metadataStore.stopByUser()
                }
            }
            .onChange(of: adultMatching) { enabled in
                metadataStore.pause()
                guard scenePhase != .background, automaticMatching || isHomeTest else {
                    metadataStore.hydrate(files: libraryFiles)
                    return
                }
                if enabled { metadataStore.retryFailed(files: libraryFiles) }
                else { metadataStore.sync(files: libraryFiles) }
            }
            .environmentObject(recents)
            .environmentObject(mediaLibrary)
            .environmentObject(localStore)
            .environmentObject(metadataStore)
            .environmentObject(scanner)
            .environmentObject(accountInfo)
            .tint(Theme.accent)
    }

    private var isHomeTest: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1"
        #else
        return false
        #endif
    }

    private func refreshAccountInfo() async {
        if InterfacePreview.active {
            accountInfo.seed(session: appState.sessionID, status: sourceStatus, quota: sourceQuota)
            return
        }
        await accountInfo.refreshIfNeeded(session: appState.sessionID, client: appState.directClient())
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

    /// 自绘的标签页容器：去过的页面都留在内存里，只有当前页可见、可点、可被读屏读到；
    /// 切换时新页面淡入并从 0.985 放大到 1。标签栏作为底部安全区的一部分，页面内容自动让开。
    private var tabs: some View {
        ZStack {
            ForEach(HomeSection.allCases, id: \.self) { section in
                if visited.contains(section) || selection == section {
                    page(for: section)
                        .opacity(selection == section ? 1 : 0)
                        .allowsHitTesting(selection == section)
                        .accessibilityHidden(selection != section)
                        .zIndex(selection == section ? 1 : 0)
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.fade, value: selection)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBarHost(selection: $selection, visibility: tabBarVisibility)
        }
        .environment(\.tabBarVisibility, tabBarVisibility)
        .background(Theme.pageBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private func page(for section: HomeSection) -> some View {
        switch section {
        case .home:
            HomeTab(onBrowseLibrary: { selection = .cloud },
                    onSearch: { selection = .search },
                    onOpenCatalog: { kind, sort in
                        catalogPreset = CatalogPreset(kind: kind, sort: sort)
                        selection = .library
                    })
        case .library:
            CatalogTab(onSearch: { selection = .search }, preset: $catalogPreset)
        case .cloud:
            CloudTab(onSearch: { selection = .search })
        case .mine:
            SettingsView()
        case .search:
            SearchTab(initialQuery: initialSearch, initialResults: searchFiles, isActive: selection == .search,
                      onClose: { selection = lastTab })
        }
    }
}

private struct LibrarySyncInput: Equatable {
    let count: Int
    let accountID: String?
    let background: Bool
    let scanning: Bool
}
