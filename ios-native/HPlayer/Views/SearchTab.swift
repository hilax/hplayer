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
    @State private var playing: PlaybackSource?

    var body: some View {
        Group {
            if !appState.isAuthenticated {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "登录后才能搜索",
                    message: "到「设置」里连接服务器并登录 115 账号"
                )
            } else if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.red)
                    Button("重试") { Task { await search() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: keyword.isEmpty ? "搜索 115 网盘" : "没有找到结果",
                    message: keyword.isEmpty ? "输入片名试试" : "换个关键词再试"
                )
            } else {
                List(results) { file in
                    Button {
                        if file.isDir {
                            // 目录暂不展开，先只处理文件
                        } else {
                            playing = .p115(title: file.name, pickCode: file.pickCode)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: file.isDir ? "folder.fill" : "play.rectangle.fill")
                                .foregroundStyle(file.isDir ? Color.blue : Theme.accent)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                if !file.isDir {
                                    Text(formatSize(file.size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $keyword, prompt: "搜索 115 文件")
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .fullScreenCover(item: $playing) { source in
            PlayerView(source: source)
                .environmentObject(appState)
        }
    }

    private func search() async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let client = appState.client() else { return }

        loading = true
        error = ""
        do {
            let response: SearchResponse = try await client.get(
                "/api/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            )
            results = response.files.filter { !$0.isDir }
        } catch let err {
            error = err.localizedDescription
        }
        loading = false
    }
}
