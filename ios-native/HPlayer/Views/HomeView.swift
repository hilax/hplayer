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
    @StateObject private var navigation = HomeNavigation()
    /// 首页和片库共用的分组结果，在这里算一次，两个页面直接读。
    @StateObject private var librarySnapshots = LibrarySnapshotStore()
    /// 标记过「不在精选中显示」的影片，变化时精选要重新挑。
    @ObservedObject private var featuredStore = FeaturedStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// 当前标签（系统原生 TabView 的选中项）。
    @State private var selection: HomeSection = .home
    /// 搜索是盖在标签页上面的全屏页，不占标签位；打开过以后保持存活（搜索词还在）。
    @State private var searchOpen = false
    @State private var searchCreated = false
    /// 首页分类入口带过来的筛选；片库读取后会清空。
    @State private var catalogPreset: CatalogPreset?
    /// 首页当前频道：推荐 / 片库 / 动漫（2.0：原「片库」Tab 并入首页）。
    @State private var channel: HomeChannel = .recommend
    @State private var restored = false
    @ObservedObject private var appState: AppState

    /// init 会在上层页面每次刷新时被重新调用，这里不做任何读盘或联网，
    /// 恢复工作放到 restoreOnce，只执行一次。
    private var sourceStatus: P115Status?
    private var sourceQuota: QuotaResponse?
    private var initialSearch = ""
    private var searchFiles: [P115File] = []

    init(appState: AppState, initialSection: HomeSection = .home, initialChannel: HomeChannel = .recommend,
         library: MediaLibraryStore? = nil, local: LocalMediaStore? = nil,
         metadata: MediaMetadataStore? = nil, recents: RecentStore? = nil,
         accountInfo: P115AccountInfoStore? = nil,
         sourceStatus: P115Status? = nil, sourceQuota: QuotaResponse? = nil,
         initialSearch: String = "", searchFiles: [P115File] = []) {
        _appState = ObservedObject(wrappedValue: appState)
        _selection = State(initialValue: initialSection == .search ? .home : initialSection)
        _searchOpen = State(initialValue: initialSection == .search)
        _searchCreated = State(initialValue: initialSection == .search)
        _channel = State(initialValue: initialChannel)
        if let library { _mediaLibrary = StateObject(wrappedValue: library) }
        if let local { _localStore = StateObject(wrappedValue: local) }
        if let metadata { _metadataStore = StateObject(wrappedValue: metadata) }
        if let recents { _recents = StateObject(wrappedValue: recents) }
        if let accountInfo { _accountInfo = StateObject(wrappedValue: accountInfo) }
        self.sourceStatus = sourceStatus; self.sourceQuota = sourceQuota
        self.initialSearch = initialSearch; self.searchFiles = searchFiles
    }

    /// 「下载到手机」：下载好的视频放进本地视频库；每次开始或续传时现取 115 的下载地址。
    private func configureDownloads() {
        guard !InterfacePreview.active else { return }
        let manager = DownloadManager.shared
        manager.media = localStore
        let state = appState
        manager.requestProvider = { [weak state] item in
            guard let state, let client = state.directClient() else {
                throw APIError.server("请先登录 115")
            }
            let address = try await client.originalURL(pickCode: item.pickCode)
            return client.downloadRequest(for: address)
        }
    }

    /// 下载只在 App 打开时进行：切到后台时向系统多要一小段时间，之后自动暂停；回来后继续。
    private func updateDownloads(for phase: ScenePhase) {
        guard !InterfacePreview.active else { return }
        switch phase {
        case .background:
            DownloadManager.shared.sceneDidEnterBackground()
        case .active:
            DownloadManager.shared.sceneDidBecomeActive()
        default:
            break
        }
    }

    private func restoreOnce() {
        configureDownloads()
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
                navigation.setCloudRoutes([])
                if section == .cloud || section == .mine { Task { await refreshAccountInfo() } }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await refreshAccountInfo() } }
                updateDownloads(for: phase)
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
                await librarySnapshots.rebuild(files: libraryFiles, matches: metadataStore.metadataByMediaID,
                                               hiddenFeatured: featuredStore.hidden)
            }
            // 按记录的先后排序：重看旧片、记录满 30 条后再看新片时条数不变，所以要比较整串 id，不能只看条数
            .task(id: CatalogEntriesKey(revision: librarySnapshots.revision, recents: recents.items.map(\.id))) {
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
            .environmentObject(navigation)
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
                           metadataRevision: metadataStore.revision, account: appState.libraryAccountID,
                           hiddenFeatured: featuredStore.hidden)
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
            NavigationStack(path: $navigation.path) {
                tabPages
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: PerformerListRoute.self) { _ in
                        PerformerGridView(groups: librarySnapshots.home.performers)
                    }
                    .navigationDestination(for: PerformerRoute.self) { route in
                        if let group = librarySnapshots.home.performers.first(where: { $0.id == route.id }) {
                            PerformerCollectionView(group: group).id(route.id)
                        } else {
                            EmptyStateView(icon: AppIcon.people.name, title: "演员合集已更新", message: "返回后重新进入演员合集。")
                        }
                    }
                    .navigationDestination(for: AnimeDetailRoute.self) { route in
                        AnimeDetailView(animeId: route.animeId).id(route.animeId)
                    }
                    .navigationDestination(for: AnimeBrowseRoute.self) { route in
                        AnimeBrowseView(route: route)
                    }
                    .navigationDestination(for: DramaRoute.self) { route in
                        DramaDetailView(route: route).environmentObject(appState)
                    }
                    // 程序化路径的目标注册在整个 TabView 的外层，网盘根页退场后仍可解析。
                    .navigationDestination(for: CloudRoute.self) { route in
                        CloudTab(route: route)
                    }
                    .navigationDestination(for: MineRoute.self) { route in
                        switch route {
                        case .watchlist:
                            AnimeWatchlistView()
                        case .page(.offline):
                            OfflineTasksView()
                        case .page(.downloads):
                            DownloadsView()
                        case .page(.recycleBin):
                            RecycleBinView()
                        case .page(.localVideos):
                            LocalVideosView()
                        }
                    }
            }
            .tint(Theme.textPrimary)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .accessibilityHidden(searchOpen)

            if searchCreated {
                searchPage
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
    }

    /// 整个原生标签容器属于同一个根页面。二级页盖住整个容器，返回时连同胶囊栏一起回来。
    private var tabPages: some View {
        TabView(selection: $selection) {
            ForEach(HomeSection.tabs, id: \.self) { section in
                page(for: section)
                    // 搜索页打开时键盘弹出，底下的页面不该跟着键盘改变尺寸：
                    // 不然从搜索页返回、键盘收起时，片库、网盘会跟着弹回去。
                    // 「我的」里有带输入框的二级页，需要保留键盘避让，所以不包括它。
                    .ignoresSafeArea(keyboardRegions(for: section), edges: .bottom)
                    .tabItem {
                        // 系统 TabView 会把标签栏里所有符号自动换成实心款（四个图标都是实心的）。
                        // 关掉它，由图标表决定：没选中是线框，选中才是实心，和应用其余图标一致。
                        // 选中的图标由系统染成主题琥珀色；没选中的图标 iOS 26 不允许改颜色，
                        // 所以用预先染成主题次要灰（和原来自绘标签栏一样）的图片。
                        Label {
                            Text(section.title)
                        } icon: {
                            if selection == section {
                                Image(systemName: section.icon.activeName)
                            } else {
                                Image(uiImage: Self.restingTabIcon(section.icon, scheme: colorScheme))
                            }
                        }
                        .environment(\.symbolVariants, .none)
                    }
                    .tag(section)
            }
        }
        // Prism Noir：选中的标签用主文字色（深色模式为白），不用强调色。
        .tint(Theme.textPrimary)
        // 键盘只该让上面的搜索页避让：TabView 自己（连同悬浮的标签栏）整体不跟着键盘缩小，
        // 否则搜索页弹出、收起键盘时，底下的页面和标签栏会被顶起来再落下去。
        // 各页里带输入框的二级页（「我的」里的设置）由它们自己的页面处理键盘避让。
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var searchPage: some View {
        SearchTab(initialQuery: initialSearch, initialResults: searchFiles, isActive: searchOpen,
                  library: librarySnapshots.ready ? librarySnapshots.home : nil,
                  onClose: { closeSearch() })
            .background(Theme.pageBackground.ignoresSafeArea())
            // 淡入淡出只作用在透明度上：搜索页内部的布局（键盘收起时它跟着变高）
            // 不能被这个淡出动画接管，否则它和键盘自己的动画叠在一起，页面会先被带下去再弹回来。
            .transaction { $0.animation = nil }
            .opacity(searchOpen ? 1 : 0)
            // 打开时柔和淡入；返回时快一点淡出，淡完之后搜索页才收键盘（见 SearchView）
            .animation(reduceMotion ? nil : (searchOpen ? Motion.fade : .easeOut(duration: SearchView.closeFadeDuration)),
                       value: searchOpen)
            .allowsHitTesting(searchOpen)
            .accessibilityHidden(!searchOpen)
            // 搜索页也不跟系统的键盘避让：它的大小、位置在键盘弹出收起时一点都不变，
            // 列表底部为键盘留的空白由搜索页自己量（见 SearchView.keyboardHeight）。
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .zIndex(1)
    }

    /// 没选中标签的图标：线框款，预先染成主题的次要文字灰（浅色 / 深色各一套）。
    private static func restingTabIcon(_ icon: AppIcon, scheme: ColorScheme) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let color = Theme.textSecondaryUIColor.resolvedColor(with: traits)
        guard let image = UIImage(systemName: icon.name) else { return UIImage() }
        return image.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private func keyboardRegions(for section: HomeSection) -> SafeAreaRegions {
        section == .mine ? [] : .keyboard
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
            // 推荐 / 动漫 / 片库 / 短剧：左右滑动切换，频道条和搜索框是固定头部（见 HomeChannelsView）
            HomeChannelsView(channel: $channel, catalogPreset: $catalogPreset,
                             onSearch: { openSearch() }, onBrowseLibrary: { selection = .cloud })
        case .magnet:
            MagnetTab()
        case .cloud:
            CloudTab(onSearch: { openSearch() }, onOpenAccount: { selection = .mine })
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
    let hiddenFeatured: Set<String>
}

private struct CatalogEntriesKey: Equatable {
    let revision: Int
    let recents: [String]
}
