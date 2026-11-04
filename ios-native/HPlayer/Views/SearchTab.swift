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
    var onClose: () -> Void = {}
    var body: some View {
        NavigationStack {
            SearchView(initialQuery: initialQuery, initialResults: initialResults, isActive: isActive, library: library, onClose: onClose)
        }
    }
}

/// 搜索：「片库」在首页媒体库里按片名即时筛选，「115 网盘」按搜索键后请求网盘。
struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all, library, cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .library: return "片库"
            case .cloud: return "115 网盘"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore

    var isActive = true
    /// 现成的片库分组；没有（还没算好）时才自己算一遍。
    var sharedLibrary: HomeSnapshot?
    var onClose: () -> Void = {}
    @Namespace private var scopeNamespace
    @FocusState private var searchFocused: Bool
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
    /// 键盘占掉的高度。搜索页整体不跟系统的键盘避让（那样它的布局会随键盘收起被拖着变），
    /// 改成自己量键盘高度、只给列表底部留白；退出时冻结，收起键盘不再引起任何布局变化。
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardFrozen = false
    /// 每次打开 / 关闭加一：关闭后延迟收键盘时，用它判断期间有没有又重新打开
    @State private var focusGeneration = 0

    /// 关闭时搜索页淡出的时长；键盘等搜索页完全看不见之后才收起（见 onChange(of: isActive)）
    static let closeFadeDuration = 0.18

    init(initialQuery: String = "", initialResults: [P115File] = [], isActive: Bool = true,
         library: HomeSnapshot? = nil, onClose: @escaping () -> Void = {}) {
        self.isActive = isActive
        self.sharedLibrary = library
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
            } else if (scope == .cloud || hits.count == 0) && (scope == .library || results.isEmpty) && !loading && error.isEmpty && (scope == .library || searchedKeyword == query) {
                EmptyStateView(icon: AppIcon.search.name, title: "暂时没有找到", message: "试试更短的片名，或检查文件名。也可以切换搜索范围后再试。", actionTitle: "重新搜索", action: { searchFocused = true })
                    .frame(minHeight: 380).searchRow()
            } else {
                if scope != .cloud {
                    librarySection(hits, library: library)
                }
                if scope != .library {
                    cloudSection
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: keyboardHeight)
        }
        }
        // 在导航容器里面再声明一次不跟键盘避让：外面的声明管不到导航容器自己的键盘处理，
        // 只在外面写的话列表底部会被系统和上面的 keyboardHeight 各让一次。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Theme.pageBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard isActive, !keyboardFrozen,
                  let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            let covered = max(0, UIScreen.main.bounds.height - frame.minY - Self.windowBottomInset)
            withAnimation(.easeOut(duration: duration)) { keyboardHeight = covered }
        }
        .task {
            guard isActive, query.isEmpty, !InterfacePreview.active else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            searchFocused = true
        }
        .onChange(of: isActive) { active in
            focusGeneration += 1
            if active {
                keyboardFrozen = false
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { keyboardHeight = 0 }
                if !InterfacePreview.active { searchFocused = true }
            } else {
                keyboardFrozen = true
                // 返回时先让搜索页淡出，键盘留在原处；等搜索页完全看不见了再收键盘。
                // 录屏逐帧看过：键盘开始收起的那一帧，搜索页的内容（搜索框、范围标签、空状态）会被整体
                // 往下推约 56pt，再跟着键盘动画弹回来——这就是返回时看到的「跳一下」。底下的页面不跟键盘变化，
                // 所以先把搜索页淡掉再收键盘，这一下就发生在看不见的时候，用户只看到搜索页淡出、键盘落下。
                let generation = focusGeneration
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64((Self.closeFadeDuration + 0.04) * 1_000_000_000))
                    guard generation == focusGeneration else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { searchFocused = false }
                }
            }
        }
        .designScreen(query.isEmpty ? "search" : hits.count == 0 && results.isEmpty && !loading && error.isEmpty ? "search-empty" : "search-results")
        .navigationDestination(for: PerformerRoute.self) { route in
            if let group = library.performers.first(where: { $0.id == route.id }) {
                PerformerCollectionView(group: group)
                    .id(route.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: AppIcon.people.name)
                    Text("演员合集已更新").font(.headline)
                    Text("返回搜索页后重新进入演员合集。").foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: keyword) { _ in
            searchTask?.cancel()
            cloudSearch.invalidate(clearResults: query.isEmpty)
        }
        .onChange(of: scope) { value in
            searchTask?.cancel()
            cloudSearch.invalidate()
            if value != .library, !query.isEmpty, searchedKeyword != query { startSearch() }
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

    /// 屏幕底部的安全区（Home 条）：键盘高度里已经包含它，列表底部本来就留着这一段。
    private static var windowBottomInset: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window?.safeAreaInsets.bottom ?? 0
    }

    // MARK: 顶部搜索栏

    private var searchBar: some View {
        HStack(spacing: 2) {
            BarIconButton(icon: .back, label: "返回", identifier: "search.back") {
                // 这里不收键盘：等搜索页淡出之后再收（见 onChange(of: isActive)）
                keyboardFrozen = true
                onClose()
            }
            HStack(spacing: 8) {
                Image(systemName: AppIcon.search.name)
                    .font(.system(size: 15, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textTertiary)
                TextField("片名、文件名或演员", text: $keyword)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { startSearch() }
                    .focused($searchFocused)
                    .accessibilityIdentifier("search.query")
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: AppIcon.clear.name)
                            .font(.system(size: 15))
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

            Button { startSearch(); searchFocused = false } label: {
                Text("搜索")
                    .font(.system(size: 15, weight: .semibold))
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
                            Text(group.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("演员合集 · \(group.collectionItems.count) 部").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: AppIcon.forward.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
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
                Label(error, systemImage: AppIcon.alert.name)
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

    // MARK: 行

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .searchRow(top: 14, bottom: 4)
    }

    private func hintRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .searchRow(top: 4, bottom: 12)
    }

    // MARK: 请求

    private func startSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.isEmpty, scope != .library, appState.isAuthenticated,
              let direct = appState.directClient() else { return }
        searchTask = Task { await cloudSearch.search(text) { try await direct.search($0) } }
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
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // 横版封面铺满后会伸出框外，clipShape 只裁画面不裁点击区域；整行的点击区域由最外层的 contentShape 决定
                .allowsHitTesting(false)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsPlay {
                Image(systemName: AppIcon.play.name)
                    .font(.system(size: 13, weight: .bold))
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
