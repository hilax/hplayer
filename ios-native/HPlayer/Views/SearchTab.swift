import SwiftUI

struct SearchTab: View {
    var initialQuery = ""
    var initialResults: [P115File] = []
    var body: some View {
        NavigationStack {
            SearchView(initialQuery: initialQuery, initialResults: initialResults)
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

    @FocusState private var searchFocused: Bool
    @State private var keyword = ""
    @State private var scope: Scope = .all
    @State private var results: [P115File] = []
    @State private var searchedKeyword = ""
    @State private var loading = false
    @State private var error = ""
    @State private var playing: PlaybackQueue?
    @State private var openSeriesID: String?

    init(initialQuery: String = "", initialResults: [P115File] = []) {
        _keyword = State(initialValue: initialQuery)
        _results = State(initialValue: initialResults)
        _searchedKeyword = State(initialValue: initialQuery)
    }

    private var query: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let library = HomeLibrary.snapshot(local: localStore, cloud: mediaLibrary, metadata: metadataStore, appState: appState)
        let hits = libraryMatches(library)

        List {
            PageIntroduction(eyebrow: "Find your next watch", title: "搜索")
                .padding(.top, 12)
                .searchRow(top: 0, bottom: 16)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("片名、文件名或演员", text: $keyword)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { Task { await search() } }
                    .focused($searchFocused)
                    .accessibilityIdentifier("search.query")
                if !keyword.isEmpty {
                    Button { keyword = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("清空搜索")
                }
            }.padding(15).surfaceCard().searchRow(top: 0, bottom: 12)
            Picker("搜索范围", selection: $scope) {
                ForEach(Scope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .searchRow(top: 4, bottom: 10)

            if query.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "找到你想看的",
                    message: "输入片名、演员或文件名里的关键词。片库里的影片会边输入边显示，按搜索键再查 115 网盘。"
                )
                .frame(minHeight: 380)
                .searchRow()
            } else if hits.count == 0 && results.isEmpty && !loading && error.isEmpty && (scope == .library || searchedKeyword == query) {
                EmptyStateView(icon: "magnifyingglass", title: "暂时没有找到", message: "试试更短的片名，或检查文件名。也可以切换搜索范围后再试。", actionTitle: "重新搜索", action: { searchFocused = true })
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
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .designScreen(query.isEmpty ? "search" : hits.count == 0 && results.isEmpty && !loading && error.isEmpty ? "search-empty" : "search-results")
        .navigationDestination(for: PerformerRoute.self) { route in
            if let group = library.performers.first(where: { $0.id == route.id }) {
                PerformerCollectionView(group: group)
                    .id(route.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.2")
                    Text("演员合集已更新").font(.headline)
                    Text("返回搜索页后重新进入演员合集。").foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: keyword) { _ in
            if query.isEmpty {
                results = []
                error = ""
                searchedKeyword = ""
            }
        }
        .onChange(of: scope) { value in
            if value != .library, !query.isEmpty, searchedKeyword != query, !loading {
                Task { await search() }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { openSeriesID != nil },
            set: { if !$0 { openSeriesID = nil } }
        )) {
            if let openSeriesID {
                SeriesDetailView(seriesID: openSeriesID)
            }
        }
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
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
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                            Text("演员合集 · \(group.collectionItems.count) 部").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .surfaceCard(cornerRadius: 20)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("search.performer.\(group.id)")
                .buttonStyle(.plain)
                .searchRow()
            }

            ForEach(hits.series) { group in
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
                .buttonStyle(.plain)
                .searchRow()
            }

            ForEach(hits.movies) { item in
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
                .buttonStyle(.plain)
                .searchRow()
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
                icon: "person.crop.circle.badge.questionmark",
                text: "登录 115 后才能搜索网盘，到「资源库」登录。"
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
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                Button("重试") { Task { await search() } }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            .searchRow(top: 4, bottom: 12)
        } else if searchedKeyword != query {
            hintRow(icon: "return", text: "按键盘上的搜索键，在 115 网盘里搜索「\(query)」。")
        } else if results.isEmpty {
            hintRow(icon: "magnifyingglass", text: "115 网盘里没有找到相关视频，换个关键词或者试试英文片名。")
        } else {
            ForEach(results) { file in
                Button {
                    let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
                    let items = results.filter { !$0.isDir && !$0.pickCode.isEmpty }.map { PlaybackSource.p115(title: $0.name, pickCode: $0.pickCode) }
                    playing = PlaybackQueue(source: source, items: items)
                } label: {
                    FileRow(file: file)
                }
                .buttonStyle(.plain)
                .searchRow(top: 7, bottom: 7)
            }
        }
    }

    // MARK: 行

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .searchRow(top: 14, bottom: 4)
    }

    private func hintRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .searchRow(top: 4, bottom: 12)
    }

    // MARK: 请求

    private func search() async {
        let text = query
        guard !text.isEmpty, scope != .library, appState.isAuthenticated else { return }

        loading = true
        error = ""
        do {
            let files: [P115File]
            guard let direct = appState.directClient() else { throw APIError.server("请先登录 115") }
            files = try await direct.search(text)
            results = files.filter { !$0.isDir && $0.isVideo }
            searchedKeyword = text
        } catch let err {
            error = err.localizedDescription
        }
        loading = false
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
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsPlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .glassProminentCircle()
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .surfaceCard(cornerRadius: 20)
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
