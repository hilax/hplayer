import SwiftUI
import UIKit

struct SearchTab: View {
    var initialQuery = ""
    var initialResults: [P115File] = []
    /// 搜索页当前是否在前台；回到前台时自动弹出键盘，离开时收起。
    var isActive = true
    /// HomeView 在后台算好的片库分组。搜索页留在后台时每次刷新都要用到片库，
    /// 直接读这份现成的，不要在主线程把整个片库重新分组一遍。
    var library: HomeSnapshot?
    var keyboard: SearchKeyboardCoordinator? = nil
    var onClose: () -> Void = {}
    var body: some View {
        NavigationStack {
            SearchView(initialQuery: initialQuery, initialResults: initialResults, isActive: isActive,
                       library: library, externalKeyboard: keyboard, onClose: onClose)
        }
        .navigationButtonTint()
    }
}

/// 搜索：「片库」在首页媒体库里按片名即时筛选，「115 网盘」按搜索键后请求网盘。
struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all, library, anime, cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .library: return "片库"
            case .anime: return "在线动漫"
            case .cloud: return "115 网盘"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isActive = true
    /// 现成的片库分组；没有（还没算好）时才自己算一遍。
    var sharedLibrary: HomeSnapshot?
    var externalKeyboard: SearchKeyboardCoordinator? = nil
    var onClose: () -> Void = {}
    @Namespace private var scopeNamespace
    @StateObject private var ownedKeyboard = SearchKeyboardCoordinator()
    private var keyboard: SearchKeyboardCoordinator { externalKeyboard ?? ownedKeyboard }
    @State private var keyword = ""
    @State private var scope: Scope = .all
    @StateObject private var cloudSearch = CloudSearchStore()
    @State private var searchTask: Task<Void, Never>?
    private var results: [P115File] { cloudSearch.results }
    private var searchedKeyword: String { cloudSearch.searchedKeyword }
    private var loading: Bool { cloudSearch.loading }
    private var error: String { cloudSearch.error }
    @State private var playing: PlaybackQueue?
    @State private var openSeriesID: String?
    @State private var animeResults: [AnimeVideoItem] = []
    @State private var isAnimeLoading = false

    init(initialQuery: String = "", initialResults: [P115File] = [], isActive: Bool = true,
         library: HomeSnapshot? = nil, externalKeyboard: SearchKeyboardCoordinator? = nil,
         onClose: @escaping () -> Void = {}) {
        self.isActive = isActive
        self.sharedLibrary = library
        self.externalKeyboard = externalKeyboard
        self.onClose = onClose
        _keyword = State(initialValue: initialQuery)
        _cloudSearch = StateObject(wrappedValue: CloudSearchStore(initialQuery: initialQuery, initialResults: initialResults))
    }

    private var query: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let library = sharedLibrary ?? HomeLibrary.snapshot(local: localStore, cloud: mediaLibrary, metadata: metadataStore, appState: appState)
        let hits = libraryMatches(library)

        VStack(spacing: 0) {
        searchBar
        scopePills
        List {
            if query.isEmpty {
                EmptyStateView(
                    icon: AppIcon.search.name,
                    title: "找到你想看的",
                    message: "输入片名、演员或文件名里的关键词。片库里的影片会边输入边显示，按搜索键再查 115 网盘。"
                )
                .frame(minHeight: 380)
                .searchRow()
            } else if (scope == .cloud || hits.count == 0) && (scope == .library || results.isEmpty) && (scope == .library || animeResults.isEmpty) && !loading && !isAnimeLoading && error.isEmpty && (scope == .library || searchedKeyword == query) {
                EmptyStateView(icon: AppIcon.search.name, title: "暂时没有找到", message: "试试更短的片名，或检查文件名。也可以切换搜索范围后再试。", actionTitle: "重新搜索", action: { keyboard.focusField() })
                    .frame(minHeight: 380).searchRow()
            } else {
                if scope != .cloud && scope != .anime {
                    librarySection(hits, library: library)
                }
                if scope == .all || scope == .anime {
                    animeSection
                }
                if scope != .library && scope != .anime {
                    cloudSection
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SearchKeyboardInset(coordinator: keyboard)
        }
        }
        // 在导航容器里面再声明一次不跟键盘避让：外面的声明管不到导航容器自己的键盘处理，
        // 只在外面写的话列表底部会被系统和上面的 keyboardHeight 各让一次。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Theme.pageBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if externalKeyboard == nil {
                keyboard.handleStandaloneInitialAppearance(isActive: isActive, autoFocus: query.isEmpty && !InterfacePreview.active, reduceMotion: reduceMotion)
            }
        }
        .onChange(of: isActive) { active in
            if externalKeyboard == nil {
                if active { keyboard.open(autoFocus: !InterfacePreview.active, reduceMotion: reduceMotion) }
                else { keyboard.close(reduceMotion: reduceMotion) }
            }
        }
        .designScreen(query.isEmpty ? "search" : hits.count == 0 && results.isEmpty && !loading && error.isEmpty ? "search-empty" : "search-results")
        .navigationDestination(for: PerformerRoute.self) { route in
            if let group = library.performers.first(where: { $0.id == route.id }) {
                PerformerCollectionView(group: group)
                    .id(route.id)
            } else {
                VStack(spacing: 10) {
                    Image(appIconNamed: AppIcon.people.name)
                    Text("演员合集已更新").font(.headline)
                    Text("返回搜索页后重新进入演员合集。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationDestination(for: AnimeDetailRoute.self) { route in
            AnimeDetailView(animeId: route.animeId)
                .id(route.animeId)
        }
        .onChange(of: keyword) { _ in
            searchTask?.cancel()
            cloudSearch.invalidate(clearResults: query.isEmpty)
            if query.isEmpty { animeResults = [] }
        }
        .onChange(of: scope) { value in
            searchTask?.cancel()
            cloudSearch.invalidate()
            if value != .library, !query.isEmpty { startSearch() }
        }
        .onChange(of: appState.sessionID) { _ in
            searchTask?.cancel()
            cloudSearch.invalidate(clearResults: true)
        }
        .onDisappear { searchTask?.cancel(); cloudSearch.invalidate() }
        .navigationDestination(isPresented: Binding(
            get: { openSeriesID != nil },
            set: { if !$0 { openSeriesID = nil } }
        )) {
            if let openSeriesID {
                SeriesDetailView(seriesID: openSeriesID)
            }
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
    }

    // MARK: 顶部搜索栏

    private var searchBar: some View {
        HStack(spacing: 2) {
            BarIconButton(icon: .back, label: "返回", identifier: "search.back") {
                keyboard.close(reduceMotion: reduceMotion)
                onClose()
            }
            HStack(spacing: 8) {
                Image(appIconNamed: AppIcon.search.name)
                    .font(.scaled(15, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textTertiary)
                SearchTextField(
                    text: $keyword,
                    placeholder: "片名、文件名或演员",
                    coordinator: keyboard,
                    onSubmit: { startSearch() }
                )
                .frame(height: 28)
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(appIconNamed: AppIcon.clear.name)
                            .font(.scaled(15))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable(scale: 0.85))
                    .accessibilityLabel("清空搜索")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.surface, in: Capsule())
            .animation(Motion.snappy, value: keyword.isEmpty)

            Button { startSearch(); keyboard.resignField() } label: {
                Text("搜索")
                    .font(.scaled(15, weight: .semibold))
                    .foregroundStyle(query.isEmpty ? Theme.textTertiary : Theme.accent)
                    .frame(minWidth: 48, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.92))
            .disabled(query.isEmpty)
            .accessibilityIdentifier("search.submit")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.top, 2)
    }

    private var scopePills: some View {
        HStack(spacing: 6) {
            ForEach(Scope.allCases) { item in
                SelectionPill(title: item.title, selected: scope == item, namespace: scopeNamespace) {
                    withAnimation(Motion.snappy) { scope = item }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: 片库

    private struct LibraryHits {
        let movies: [HomeMediaItem]
        let series: [SeriesGroup]
        /// 名字匹配的演员合集（至少两部影片的演员）
        let performers: [PerformerGroup]
        var count: Int { movies.count + series.count + performers.count }
    }

    private func libraryMatches(_ library: HomeSnapshot) -> LibraryHits {
        let text = query
        guard !text.isEmpty else { return LibraryHits(movies: [], series: [], performers: []) }
        func hit(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(text) }
        let series = library.series.filter { group in
            hit(group.title) || group.episodes.contains { hit($0.media.name) }
        }
        // 演员名也能搜到影片：只有一部影片的演员不会有合集，但仍然能从这里找到她的片子。
        let movies = library.items.filter { item in
            !item.isSeries && (hit(item.title) || hit(item.media.name) || (item.metadata?.performers ?? []).contains(where: hit))
        }
        let performers = library.performers.filter { hit($0.name) }
        return LibraryHits(movies: movies, series: series, performers: performers)
    }

    @ViewBuilder
    private func librarySection(_ hits: LibraryHits, library: HomeSnapshot) -> some View {
        sectionTitle(hits.count > 0 ? "片库 · \(hits.count)" : "片库")

        if hits.count == 0 {
            Text("片库里没有找到「\(query)」")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .searchRow(top: 2, bottom: 12)
        } else {
            ForEach(hits.performers) { group in
                PerformerNavigationLink(group: group) {
                    HStack(spacing: 14) {
                        IconTile(icon: .people, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(.scaled(15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("演员合集 · \(group.collectionItems.count) 部").font(.scaled(12)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(appIconNamed: AppIcon.forward.name).font(.scaled(12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(12)
                    .surfaceCard()
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("search.performer.\(group.id)")
                .buttonStyle(.pressable(scale: 0.98))
                .searchRow()
                .reveal(0, id: group.id)
            }

            ForEach(Array(hits.series.enumerated()), id: \.element.id) { index, group in
                Button {
                    openSeriesID = group.id
                } label: {
                    LibraryResultRow(
                        posterURL: group.posterURL,
                        title: group.title,
                        meta: metaLine(year: group.year, country: group.episodes.first?.countryLabel ?? "", rating: group.rating),
                        detail: "剧集 · \(group.countLabel) · \(group.sourceLabel)",
                        showsPlay: false
                    )
                }
                .buttonStyle(.pressable(scale: 0.98))
                .searchRow()
                .reveal(index, id: group.id)
            }

            ForEach(Array(hits.movies.enumerated()), id: \.element.id) { index, item in
                Button {
                    playing = HomeLibrary.queue(for: item, in: library.items)
                } label: {
                    LibraryResultRow(
                        posterURL: item.posterURL,
                        title: item.title,
                        meta: metaLine(year: item.year, country: item.countryLabel, rating: item.rating),
                        detail: [item.metadata == nil ? "视频" : "电影", item.sourceLabel, formatSize(item.media.size),
                                 (item.metadata?.performers ?? []).prefix(3).joined(separator: "、")]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        showsPlay: true
                    )
                }
                .buttonStyle(.pressable(scale: 0.98))
                .searchRow()
                .reveal(index, id: item.id)
            }
        }
    }

    private func metaLine(year: String, country: String, rating: String) -> String {
        var parts: [String] = []
        if !year.isEmpty { parts.append(year) }
        if !country.isEmpty { parts.append(country) }
        if !rating.isEmpty { parts.append("★ \(rating)") }
        return parts.joined(separator: " · ")
    }

    // MARK: 115 网盘

    @ViewBuilder
    private var cloudSection: some View {
        sectionTitle(searchedKeyword == query && !results.isEmpty ? "115 网盘 · \(results.count) 个视频" : "115 网盘")

        if !appState.isAuthenticated {
            hintRow(
                icon: AppIcon.personUnknown.name,
                text: "登录 115 后才能搜索网盘，到「网盘」页登录。"
            )
        } else if loading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 24)
            .searchRow()
        } else if !error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, image: AppIcon.alert.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                Button("重试") { startSearch() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            .searchRow(top: 4, bottom: 12)
        } else if searchedKeyword != query {
            hintRow(icon: AppIcon.returnKey.name, text: "按键盘上的搜索键，在 115 网盘里搜索「\(query)」。")
        } else if results.isEmpty {
            hintRow(icon: AppIcon.search.name, text: "115 网盘里没有找到相关视频，换个关键词或者试试英文片名。")
        } else {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, file in
                Button {
                    let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
                    let items = results.filter { !$0.isDir && !$0.pickCode.isEmpty }.map { PlaybackSource.p115(title: $0.name, pickCode: $0.pickCode) }
                    playing = PlaybackQueue(source: source, items: items)
                } label: {
                    FileRow(file: file)
                }
                .buttonStyle(.pressable(scale: 0.98))
                .searchRow(top: 7, bottom: 7)
                .reveal(index, id: file.id)
            }
        }
    }

    // MARK: 在线动漫

    @ViewBuilder
    private var animeSection: some View {
        if !animeResults.isEmpty {
            sectionTitle("在线动漫 · \(animeResults.count) 部")

            ForEach(Array(animeResults.enumerated()), id: \.element.id) { index, item in
                NavigationLink(value: AnimeDetailRoute(animeId: item.id)) {
                    LibraryResultRow(
                        posterURL: item.safePicURLString,
                        title: item.name,
                        meta: [item.year, item.area, item.continu].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                        detail: ["在线动漫", item.tags.prefix(2).joined(separator: " / ")].filter { !$0.isEmpty }.joined(separator: " · "),
                        showsPlay: false
                    )
                }
                .buttonStyle(.pressable(scale: 0.98))
                .searchRow()
            }
        } else if isAnimeLoading {
            HStack {
                Spacer()
                ProgressView()
                    .tint(Theme.accent)
                Spacer()
            }
            .padding(.vertical, 24)
            .searchRow()
        }
    }

    // MARK: 行

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.scaled(13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .searchRow(top: 14, bottom: 4)
    }

    private func hintRow(icon: String, text: String) -> some View {
        Label(text, image: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .searchRow(top: 4, bottom: 12)
    }

    // MARK: 请求

    private func startSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.isEmpty else { return }

        searchTask = Task {
            if scope != .library && scope != .anime && appState.isAuthenticated,
               let direct = appState.directClient() {
                await cloudSearch.search(text) { try await direct.search($0) }
            }

            if scope == .all || scope == .anime {
                isAnimeLoading = true
                do {
                    let res = try await AnimeClient.shared.search(keyword: text, limit: 20)
                    self.animeResults = res.items
                } catch {
                    self.animeResults = []
                }
                isAnimeLoading = false
            }
        }
    }

}

/// 片库搜索结果：小海报、片名和资料
private struct LibraryResultRow: View {
    let posterURL: String
    let title: String
    let meta: String
    let detail: String
    let showsPlay: Bool

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(urlString: posterURL, title: title, letterSize: 24)
                .scaledToFill()
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                // 横版封面铺满后会伸出框外，clipShape 只裁画面不裁点击区域；整行的点击区域由最外层的 contentShape 决定
                .allowsHitTesting(false)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.scaled(15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.scaled(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.scaled(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsPlay {
                Image(appIconNamed: AppIcon.play.name)
                    .font(.scaled(13, weight: .bold))
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 36, height: 36)
                    .background(Theme.gold, in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .surfaceCard()
        .contentShape(Rectangle())
    }
}

private extension View {
    /// 搜索列表里的行：透明背景、无分隔线
    func searchRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
    }
}

private struct SearchKeyboardInset: View {
    @ObservedObject var coordinator: SearchKeyboardCoordinator

    var body: some View {
        Color.clear.frame(height: coordinator.keyboardHeight)
    }
}

/// 承载全屏搜索页的 UIKit 容器：
/// 直接驱动 `view.alpha` 与系统 `keyboardWillShow` / `keyboardWillHide` 在同一个 `CATransaction` 里同步淡入淡出，
/// 并用 `safeAreaRegions = .container` 隔绝系统键盘安全区，保证搜索页与系统键盘零时间差且无跳动。
struct SearchOverlayHost<Content: View>: UIViewControllerRepresentable {
    let isOpen: Bool
    let initiallyVisible: Bool
    @ObservedObject var coordinator: SearchKeyboardCoordinator
    let content: () -> Content

    func makeCoordinator() -> HostState {
        HostState(lastOpen: initiallyVisible)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = .clear
        container.view.alpha = initiallyVisible ? 1 : 0
        container.view.isUserInteractionEnabled = isOpen
        container.view.accessibilityElementsHidden = !isOpen

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = .container
        }
        host.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        host.view.isUserInteractionEnabled = isOpen
        host.view.accessibilityElementsHidden = !isOpen

        container.addChild(host)
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        host.didMove(toParent: container)

        context.coordinator.host = host
        coordinator.overlayView = container.view
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        coordinator.overlayView = uiViewController.view
        if let host = context.coordinator.host {
            host.rootView = content()
            host.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
            host.view.isUserInteractionEnabled = isOpen
            host.view.accessibilityElementsHidden = !isOpen
        }
        uiViewController.view.isUserInteractionEnabled = isOpen
        uiViewController.view.accessibilityElementsHidden = !isOpen

        if context.coordinator.lastOpen != isOpen {
            context.coordinator.lastOpen = isOpen
            let reduceMotion = context.environment.accessibilityReduceMotion
            if isOpen {
                coordinator.open(autoFocus: !InterfacePreview.active, reduceMotion: reduceMotion)
            } else {
                coordinator.close(reduceMotion: reduceMotion)
            }
        }
    }

    final class HostState {
        var host: UIHostingController<Content>?
        var lastOpen: Bool

        init(lastOpen: Bool) {
            self.lastOpen = lastOpen
        }
    }
}

/// 同步管理搜索页的输入框焦点、列表底部键盘留白，以及遮罩容器与系统键盘的同事务动画。
@MainActor
final class SearchKeyboardCoordinator: ObservableObject {
    @Published private(set) var keyboardHeight: CGFloat = 0
    private(set) var isKeyboardVisible = false

    weak var overlayView: UIView?
    private(set) weak var textField: UITextField?

    private var isOpen = false
    private var isClosing = false
    private var isFrozen = false
    private var wantFocus = false
    private var didAnimateReveal = false
    private var activeReduceMotion = false
    private var didHandleStandaloneInitial = false
    private var isObserving = false
    private var openGeneration = 0
    private var fallbackTask: Task<Void, Never>?

    deinit {
        if isObserving {
            NotificationCenter.default.removeObserver(self)
        }
    }

    private func ensureObserving() {
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(handleWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(handleWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    func attach(textField: UITextField) {
        ensureObserving()
        self.textField = textField
        if isOpen && wantFocus && textField.window != nil && !textField.isFirstResponder {
            textField.becomeFirstResponder()
        }
    }

    func handleStandaloneInitialAppearance(isActive: Bool, autoFocus: Bool, reduceMotion: Bool) {
        ensureObserving()
        guard !didHandleStandaloneInitial else { return }
        didHandleStandaloneInitial = true
        if isActive {
            open(autoFocus: autoFocus, reduceMotion: reduceMotion)
        }
    }

    func open(autoFocus: Bool, reduceMotion: Bool) {
        ensureObserving()
        isOpen = true
        isClosing = false
        isFrozen = false
        didAnimateReveal = false
        activeReduceMotion = reduceMotion
        openGeneration += 1
        let generation = openGeneration
        fallbackTask?.cancel()
        fallbackTask = nil

        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { keyboardHeight = 0 }

        guard autoFocus else {
            wantFocus = false
            didAnimateReveal = true
            animateOverlay(visible: true, motion: .default, reduceMotion: reduceMotion)
            return
        }

        wantFocus = true
        if let field = textField, field.window != nil {
            if field.isFirstResponder {
                didAnimateReveal = true
                animateOverlay(visible: true, motion: .default, reduceMotion: reduceMotion)
                return
            }
            field.becomeFirstResponder()
        }

        // 外接硬键盘等场景下可能不会触发软键盘 willShow，兜底显出搜索页。
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, self.isOpen, self.openGeneration == generation, !self.didAnimateReveal else { return }
            self.didAnimateReveal = true
            self.animateOverlay(visible: true, motion: .default, reduceMotion: self.activeReduceMotion)
        }
    }

    func close(reduceMotion: Bool) {
        guard isOpen || wantFocus || !isFrozen else { return }
        isOpen = false
        isClosing = true
        isFrozen = true
        wantFocus = false
        activeReduceMotion = reduceMotion
        openGeneration += 1
        fallbackTask?.cancel()
        fallbackTask = nil

        resignField()
        if isClosing {
            // 键盘本来就处于收起状态（如拖拽收起或点过搜索键）：立即开始淡出
            isClosing = false
            animateOverlay(visible: false, motion: .default, reduceMotion: reduceMotion)
        }
    }

    func focusField() {
        wantFocus = true
        if let field = textField, field.window != nil, !field.isFirstResponder {
            field.becomeFirstResponder()
        }
    }

    func resignField() {
        wantFocus = false
        if let field = textField, field.isFirstResponder {
            field.resignFirstResponder()
        } else {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private func animateOverlay(visible: Bool, motion: KeyboardMotion, reduceMotion: Bool) {
        guard let view = overlayView else { return }
        let targetAlpha: CGFloat = visible ? 1 : 0
        if reduceMotion || motion.duration <= 0 {
            view.layer.removeAllAnimations()
            view.alpha = targetAlpha
            return
        }
        let curveRaw = UInt(motion.curve ?? 7) << 16
        let options: UIView.AnimationOptions = [
            .beginFromCurrentState,
            .allowUserInteraction,
            UIView.AnimationOptions(rawValue: curveRaw)
        ]
        UIView.animate(withDuration: motion.duration, delay: 0, options: options) {
            view.alpha = targetAlpha
        }
    }

    @objc private func handleWillShow(_ note: Notification) {
        let info = SocialComposerKeyboardTracker.geometry(from: note)
        isKeyboardVisible = true
        guard isOpen, !didAnimateReveal else { return }
        didAnimateReveal = true
        fallbackTask?.cancel()
        fallbackTask = nil
        animateOverlay(visible: true, motion: info.motion, reduceMotion: activeReduceMotion)
    }

    @objc private func handleWillChangeFrame(_ note: Notification) {
        guard isOpen, !isFrozen else { return }
        let info = SocialComposerKeyboardTracker.geometry(from: note)
        guard let frame = info.frame else { return }
        let covered = max(0, UIScreen.main.bounds.height - frame.minY - Self.windowBottomInset)
        if let animation = info.motion.animation {
            withAnimation(animation) { keyboardHeight = covered }
        } else {
            keyboardHeight = covered
        }
    }

    @objc private func handleWillHide(_ note: Notification) {
        let info = SocialComposerKeyboardTracker.geometry(from: note)
        isKeyboardVisible = false
        if isClosing {
            isClosing = false
            animateOverlay(visible: false, motion: info.motion, reduceMotion: activeReduceMotion)
        }
        guard isOpen, !isFrozen else { return }
        if let animation = info.motion.animation {
            withAnimation(animation) { keyboardHeight = 0 }
        } else {
            keyboardHeight = 0
        }
    }

    /// 屏幕底部的安全区（Home 条）：键盘高度里已经包含它，列表底部本来就留着这一段。
    private static var windowBottomInset: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window?.safeAreaInsets.bottom ?? 0
    }
}

private struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @ObservedObject var coordinator: SearchKeyboardCoordinator
    let onSubmit: () -> Void

    func makeCoordinator() -> Delegate {
        Delegate(parent: self)
    }

    func makeUIView(context: Context) -> ResponderTextField {
        let field = ResponderTextField()
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.textColor = Theme.textPrimaryUIColor
        field.tintColor = Theme.accentUIColor
        field.font = Self.scaledFont()
        field.accessibilityIdentifier = "search.query"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.addTarget(context.coordinator, action: #selector(Delegate.editingChanged(_:)), for: .editingChanged)
        field.onMovedToWindow = { [weak coordinator] textField in
            coordinator?.attach(textField: textField)
        }
        return field
    }

    func updateUIView(_ uiView: ResponderTextField, context: Context) {
        context.coordinator.parent = self
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
        let targetFont = Self.scaledFont()
        if uiView.font?.pointSize != targetFont.pointSize {
            uiView.font = targetFont
        }
        if coordinator.textField !== uiView {
            coordinator.attach(textField: uiView)
        }
    }

    private static func scaledFont() -> UIFont {
        let size = min(UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 15), 15 * 1.4)
        return .systemFont(ofSize: size)
    }

    final class ResponderTextField: UITextField {
        var onMovedToWindow: ((UITextField) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onMovedToWindow?(self)
            }
        }
    }

    final class Delegate: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(parent: SearchTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            let next = textField.text ?? ""
            if parent.text != next {
                parent.text = next
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            textField.resignFirstResponder()
            return true
        }
    }
}
