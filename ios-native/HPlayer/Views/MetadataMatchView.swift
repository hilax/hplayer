import SwiftUI

/// 匹配封面：按片名在番组计划、IMDb（和填了 Key 的 TMDB）里搜，选一个作为这部影片的封面和资料。
struct MetadataMatchView: View {
    let file: LibraryMedia
    let current: MediaMetadata?
    let onMatch: (MediaMetadata) async -> Void
    var onClear: (() async -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MediaMetadata] = []
    @State private var searching = false
    @State private var searched = false
    @State private var applying = false
    @State private var showTMDB = false
    @State private var tmdbEnabled = !TMDBClient.storedKey.isEmpty
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false

    init(file: LibraryMedia, current: MediaMetadata?, onMatch: @escaping (MediaMetadata) async -> Void,
         onClear: (() async -> Void)? = nil, initialQuery: String = "", initialResults: [MediaMetadata]? = nil) {
        self.file = file; self.current = current; self.onMatch = onMatch; self.onClear = onClear
        _query = State(initialValue: initialQuery); _results = State(initialValue: initialResults ?? [])
        _searched = State(initialValue: initialResults != nil)
    }

    private var parsed: MediaNameParser.ParsedName { MediaNameParser.parse(file.name) }

    var body: some View {
        NavigationStack {
            DesignPage(eyebrow: "Find the right story", title: "匹配封面", subtitle: "为这份文件，找到正确的影片资料。") {
                HStack(spacing: 12) {
                    Image(systemName: "film").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("源文件").font(.caption).foregroundStyle(.secondary)
                        Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2).textSelection(.enabled)
                    }
                }.padding(16).surfaceCard()
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("输入片名或番号", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).onSubmit { startSearch() }
                        .accessibilityIdentifier("metadata.query")
                    if searching { ProgressView() }
                    else if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空")
                    }
                }.padding(15).surfaceCard()
                if !parsed.searchTitles.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(parsed.searchTitles, id: \.self) { title in
                                SelectionPill(title: title, selected: query == title) { query = title; startSearch() }
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                if let current {
                    GroupLabel(title: "当前资料")
                    MetadataRow(metadata: current, selected: true).padding(14).surfaceCard()
                    if let onClear {
                        Button("取消当前匹配", role: .destructive) {
                            applying = true; Task { await onClear(); dismiss() }
                        }.font(.subheadline).disabled(applying)
                    }
                }
                HStack {
                    Text("搜索结果").font(.headline)
                    Spacer()
                    Text(searching ? "搜索中" : "\(results.count) 项").font(.caption).foregroundStyle(.secondary)
                }
                if searched && results.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "暂时没有找到", message: "可以换个片名或检查番号后再试。", actionTitle: "重新搜索", action: startSearch)
                }
                ForEach(results) { metadata in
                    Button {
                        applying = true; Task { await onMatch(metadata); dismiss() }
                    } label: {
                        MetadataRow(metadata: metadata, selected: metadata.imdbID == current?.imdbID)
                            .padding(14).surfaceCard()
                    }.buttonStyle(.plain).disabled(applying)
                    .accessibilityIdentifier("metadata.result.\(metadata.imdbID)")
                }
                DesignNotice(symbol: "lock.shield", text: "搜索仅向资料来源发送片名或已识别的番号，不发送网盘 Cookie、文件路径或视频内容。")
            }
            .designScreen("match")
            .navigationTitle("匹配封面")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTMDB = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("资料来源")
                }
            }
            .task {
                guard query.isEmpty, !InterfacePreview.active else { return }
                query = (adultMatching ? parsed.catalogCode : nil) ?? parsed.chineseTitle ?? parsed.title
                startSearch()
            }
            .onChange(of: adultMatching) { enabled in
                if enabled {
                    if let code = parsed.catalogCode { query = code }
                    startSearch()
                } else {
                    cancelSearch()
                    results = []
                    searched = false
                }
            }
            .onDisappear { searchTask?.cancel() }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showTMDB, onDismiss: {
                let enabled = !TMDBClient.storedKey.isEmpty
                if enabled != tmdbEnabled {
                    tmdbEnabled = enabled
                    startSearch()
                }
            }) {
                NavigationStack { MetadataSourcesView(showsCloseButton: true) }
            }
        }
    }

    private func startSearch() {
        cancelSearch()
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; searched = false; return }
        searching = true
        searched = false
        results = []
        let hint = parsed
        searchTask = Task { await search(text, hint: hint, generation: generation) }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        searching = false
    }

    private func search(_ text: String, hint: MediaNameParser.ParsedName, generation: Int) async {
        // 几个来源同时搜，哪个先回来先显示，TMDB 连接慢也不会拖住番组计划和 IMDb 的结果
        await withTaskGroup(of: [MediaMetadata].self) { group in
            for source in MetadataSource.allCases {
                group.addTask { await MetadataSearch.shared.candidates(from: source, query: text) }
            }
            for await items in group {
                guard !Task.isCancelled, generation == searchGeneration else { group.cancelAll(); break }
                if !items.isEmpty { results = MetadataSearch.rank(results + items, query: text, hint: hint) }
            }
        }
        guard !Task.isCancelled, generation == searchGeneration else { return }
        searched = true
        searching = false
    }
}

/// 搜索结果的一行：海报、中文名、原名、年份类型和来源
struct MetadataRow: View {
    let metadata: MediaMetadata
    var selected = false

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: metadata.posterURL)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.gray.opacity(0.18)
                        Image(systemName: metadata.isSeries ? "tv" : "film").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 63, height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let original = metadata.originalTitle, !original.isEmpty {
                    Text(original).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if !metadata.overview.isEmpty {
                    Text(metadata.overview).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detail: String {
        [metadata.year, metadata.isSeries ? "剧集" : "电影", metadata.sourceKind.label, metadata.ratingLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 填写 TMDB API Key：v3 的 API Key 或 v4 的「API 读访问令牌」都可以，存在钥匙串里
struct TMDBKeyView: View {
    var body: some View { NavigationStack { MetadataCredentialsView() } }
}

struct HomeCloudBrowser: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Crumb] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if appState.isAuthenticated {
                    directory("0").navigationTitle("选择 115 文件夹")
                        .navigationDestination(for: Crumb.self) { crumb in
                            directory(crumb.cid).navigationTitle(crumb.name)
                        }
                } else {
                    CookieWebLoginView(onConnected: { })
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func directory(_ cid: String) -> some View {
        DirectoryView(cid: cid, onOpenDir: { path.append($0) }, onPlay: { _, files in
            mediaLibrary.add(files, for: appState)
            dismiss()
        }, onImported: { dismiss() })
    }
}
