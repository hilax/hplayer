import SwiftUI

struct SearchTab: View {
    var body: some View {
        NavigationStack {
            SearchView()
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState

    @State private var keyword = ""
    @State private var results: [P115File] = []
    @State private var loading = false
    @State private var error = ""
    @State private var playing: PlaybackQueue?

    var body: some View {
        Group {
            if !appState.isAuthenticated {
                EmptyStateView(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "登录 115 后才能搜索",
                    message: appState.isDirect ? "到「资源库」登录 115 账号。" : "到「设置」里连接服务器并登录 115 账号。"
                )
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "搜索失败",
                    message: error,
                    actionTitle: "重试",
                    action: { Task { await search() } }
                )
            } else if results.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: keyword.isEmpty ? "搜索 115 网盘" : "没有找到相关视频",
                    message: keyword.isEmpty ? "输入片名、演员或文件名里的关键词。" : "换个关键词，或者试试英文片名。"
                )
            } else {
                List(results) { file in
                    Button {
                        let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
                        let items = results.filter { !$0.isDir && !$0.pickCode.isEmpty }.map { PlaybackSource.p115(title: $0.name, pickCode: $0.pickCode) }
                        playing = PlaybackQueue(source: source, items: items)
                    } label: {
                        FileRow(file: file)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.hairline)
                    .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("搜索")
        .searchable(text: $keyword, prompt: "搜索 115 文件")
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
    }

    private func search() async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        loading = true
        error = ""
        do {
            let files: [P115File]
            if let direct = appState.directClient() {
                files = try await direct.search(query)
            } else if let client = appState.client() {
                let response: SearchResponse = try await client.get("/api/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
                files = response.files
            } else { throw APIError.server("请先登录 115") }
            results = files.filter { !$0.isDir && $0.isVideo }
        } catch let err {
            error = err.localizedDescription
        }
        loading = false
    }
}
