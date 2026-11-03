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
    /// 首页和片库共用的分组结果，在这里算一次，两个页面直接读。
    @StateObject private var librarySnapshots = LibrarySnapshotStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 当前标签（系统原生 TabView 的选中项）。
    @State private var selection: HomeSection = .home
    /// 搜索是盖在标签页上面的全屏页，不占标签位；打开过以后保持存活（搜索词还在）。
    @State private var searchOpen = false
    @State private var searchCreated = false
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
        _selection = State(initialValue: initialSection == .search ? .home : initialSection)
        _searchOpen = State(initialValue: initialSection == .search)
        _searchCreated = State(initialValue: initialSection == .search)
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
            .task(id: snapshotKey) {
                // 先等封面缓存恢复完，第一屏直接带封面，不会先出现一屏没封面的画面。
                await metadataStore.waitUntilRestored()
                guard !Task.isCancelled else { return }
                await librarySnapshots.rebuild(files: libraryFiles, matches: metadataStore.metadataByMediaID)
            }
            .task(id: CatalogEntriesKey(revision: librarySnapshots.revision, recents: recents.items.count)) {
                await librarySnapshots.rebuildEntries(recents: recents.items)
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
            .environmentObject(librarySnapshots)
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

    private var snapshotKey: LibrarySnapshotKey {
        LibrarySnapshotKey(local: localStore.files.count, cloudRevision: mediaLibrary.revision,
                           metadataRevision: metadataStore.revision, account: appState.libraryAccountID)
    }

    /// Keep scanning/matching alive when moving between tabs; coalesce scan batches.
    private var syncInput: LibrarySyncInput {
        let count = localStore.files.count + mediaLibrary.files(for: appState).count
        return LibrarySyncInput(count: scanner.phase == .running ? count / 300 : count,
                                accountID: appState.libraryAccountID,
                                background: scenePhase == .background, scanning: scanner.phase == .running)
    }

    /// 系统原生 TabView：iOS 26 上标签栏是悬浮的 Liquid Glass 胶囊，可以左右拖动切换；
    /// 选中色用应用的琥珀色，图标用统一图标表。去过的页面系统会保留（滚动位置不丢）。
    /// 搜索不在标签栏上，是盖在整个 TabView（含标签栏）上面的全屏页。
    private var tabs: some View {
        ZStack {
            TabView(selection: $selection) {
                ForEach(HomeSection.tabs, id: \.self) { section in
                    page(for: section)
                        .tabItem {
                            // 系统 TabView 会把标签栏里所有符号自动换成实心款（四个图标都是实心的）。
                            // 关掉它，由图标表决定：没选中是线框，选中才是实心，和应用其余图标一致。
                            Label(section.title,
                                  systemImage: selection == section ? section.icon.activeName : section.icon.name)
                                .environment(\.symbolVariants, .none)
                        }
                        .tag(section)
                }
            }
            .tint(Theme.accent)
            .accessibilityHidden(searchOpen)

            if searchCreated {
                SearchTab(initialQuery: initialSearch, initialResults: searchFiles, isActive: searchOpen,
                          onClose: { closeSearch() })
                    .background(Theme.pageBackground.ignoresSafeArea())
                    .opacity(searchOpen ? 1 : 0)
                    .allowsHitTesting(searchOpen)
                    .accessibilityHidden(!searchOpen)
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : Motion.fade, value: searchOpen)
        .background(Theme.pageBackground.ignoresSafeArea())
    }

    private func openSearch() {
        searchCreated = true
        searchOpen = true
    }

    private func closeSearch() { searchOpen = false }

    @ViewBuilder
    private func page(for section: HomeSection) -> some View {
        switch section {
        case .home:
            HomeTab(onBrowseLibrary: { selection = .cloud },
                    onSearch: { openSearch() },
                    onOpenCatalog: { kind, sort in
                        catalogPreset = CatalogPreset(kind: kind, sort: sort)
                        selection = .library
                    })
        case .library:
            CatalogTab(onSearch: { openSearch() }, preset: $catalogPreset)
        case .cloud:
            CloudTab(onSearch: { openSearch() })
        case .mine:
            SettingsView()
        case .search:
            EmptyView()
        }
    }
}

private struct LibrarySyncInput: Equatable {
    let count: Int
    let accountID: String?
    let background: Bool
    let scanning: Bool
}

private struct LibrarySnapshotKey: Equatable {
    let local: Int
    let cloudRevision: Int
    let metadataRevision: Int
    let account: String?
}

private struct CatalogEntriesKey: Equatable {
    let revision: Int
    let recents: Int
}
