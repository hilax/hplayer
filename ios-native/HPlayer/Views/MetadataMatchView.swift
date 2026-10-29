import SwiftUI

struct MetadataMatchView: View {
    let file: LibraryMedia
    let current: MediaMetadata?
    let onMatch: (MediaMetadata) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MediaMetadata] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                if let current {
                    Section("当前识别") {
                        Text(current.title).font(.headline)
                        Text([current.year, current.country, current.rating.isEmpty ? "" : "IMDb \(current.rating)"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !current.overview.isEmpty { Text(current.overview).font(.subheadline) }
                    }
                }
                Section {
                    TextField("输入电影或剧集名称", text: $query)
                        .submitLabel(.search).onSubmit { Task { await search() } }
                    Button("搜索封面") { Task { await search() } }
                        .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("搜索仅发送片名，不发送 115 Cookie 或视频内容。确认后会保存名称和 SHA-1 对应关系；相同文件改名后仍可识别。")
                }
                if searching { ProgressView() }
                ForEach(results) { metadata in
                    Button {
                        searching = true
                        Task { await onMatch(metadata); dismiss() }
                    } label: {
                        HStack(spacing: 14) {
                            AsyncImage(url: URL(string: metadata.posterURL)) { image in image.resizable().scaledToFill() }
                                placeholder: { Color.gray.opacity(0.2) }
                                .frame(width: 50, height: 75).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metadata.title).font(.headline).foregroundStyle(.primary)
                                Text("\(metadata.year) · \(metadata.isSeries ? "剧集" : "电影")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(searching)
                    .accessibilityIdentifier("metadata.result.\(metadata.imdbID)")
                }
                if searched && !searching && results.isEmpty { Text("没有找到结果，请尝试其他片名或英文名。") }
                Section("源文件") { Text(file.name).font(.caption).foregroundStyle(.secondary) }
            }
            .listRowSeparator(.hidden)
            .navigationTitle("匹配封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .task { query = MediaNameParser.parse(file.name).title; await search() }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func search() async {
        guard !searching else { return }
        searching = true
        results = await CinemetaClient.shared.candidates(query: query)
        searched = true
        searching = false
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
