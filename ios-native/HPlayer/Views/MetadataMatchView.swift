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

    private var parsed: MediaNameParser.ParsedName { MediaNameParser.parse(file.name) }

    var body: some View {
        NavigationStack {
            List {
                if let current {
                    Section("当前封面") {
                        MetadataRow(metadata: current)
                        if let onClear {
                            Button("取消匹配", role: .destructive) {
                                applying = true
                                Task { await onClear(); dismiss() }
                            }
                            .disabled(applying)
                        }
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("输入片名或番号", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { startSearch() }
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("清空")
                        }
                    }
                    if parsed.searchTitles.count > 1 {
                        // 文件名里同时有中文名和英文名时，一键换着搜
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(parsed.searchTitles, id: \.self) { title in
                                    Button(title) {
                                        query = title
                                        startSearch()
                                    }
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(query == title ? 0.22 : 0.1), in: Capsule())
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                } footer: {
                    Text("搜索向资料来源发送片名；启用番号匹配后，识别到番号时只向 R18.dev 发送番号。不发送 115 Cookie、路径或视频内容。")
                }

                Section {
                    if searching && results.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在搜索资料来源…")
                                .foregroundStyle(.secondary)
                        }
                    } else if searched && results.isEmpty {
                        Text("没有找到。可以换个片名或检查番号后再试。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { metadata in
                        Button {
                            applying = true
                            Task { await onMatch(metadata); dismiss() }
                        } label: {
                            MetadataRow(metadata: metadata, selected: metadata.imdbID == current?.imdbID)
                        }
                        .buttonStyle(.plain)
                        .disabled(applying)
                        .accessibilityIdentifier("metadata.result.\(metadata.imdbID)")
                    }
                } header: {
                    if !results.isEmpty { Text("搜索结果") }
                }

                Section {
                    Toggle("按番号匹配成人影片", isOn: $adultMatching)
                        .accessibilityIdentifier("metadata.adultMatching")
                    Button {
                        showTMDB = true
                    } label: {
                        HStack {
                            Label("TMDB", systemImage: "key")
                            Spacer()
                            Text(tmdbEnabled ? "已开启" : "未开启（可选）").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("资料来源")
                } footer: {
                    Text("番组计划、IMDb 和可选的 TMDB 用于影视资料。开启番号匹配后使用 R18.dev；封面由第三方图片服务提供。关闭后已匹配的封面仍会保留。")
                }

                Section("源文件") {
                    Text(file.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .navigationTitle("匹配封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .task {
                guard query.isEmpty else { return }
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
                TMDBKeyView()
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
private struct MetadataRow: View {
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
            .frame(width: 54, height: 80)
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
private struct TMDBKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = TMDBClient.storedKey

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API Key 或 API 读访问令牌", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("在 themoviedb.org 注册账号后，到「设置 → API」免费申请。Key 只保存在这台手机的钥匙串里，只用来搜索影片资料。部分网络下 TMDB 连接不稳定，连不上时会自动改用番组计划和 IMDb。")
                }
                if !TMDBClient.storedKey.isEmpty {
                    Section {
                        Button("删除 Key", role: .destructive) {
                            TMDBClient.saveKey("")
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("TMDB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        TMDBClient.saveKey(key)
                        dismiss()
                    }
                }
            }
        }
    }
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
