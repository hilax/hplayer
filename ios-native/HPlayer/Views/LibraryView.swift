import SwiftUI

struct Crumb: Hashable {
    let cid: String
    let name: String
}

struct DirectoryView: View {
    let cid: String
    let onOpenDir: (Crumb) -> Void
    let onPlay: (P115File, [P115File]) -> Void
    var onImported: (() -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @State private var files: [P115File] = []
    @State private var loading = true
    @State private var error = ""
    @State private var addedToHome = false

    var body: some View {
        Group {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !error.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "目录加载失败",
                    message: error,
                    actionTitle: "重试",
                    action: { Task { await load() } }
                )
            } else if files.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "这个文件夹是空的",
                    message: "这里没有视频或子文件夹。"
                )
            } else {
                List(files) { file in
                    Button {
                        if file.isDir {
                            onOpenDir(Crumb(cid: file.id, name: file.name))
                        } else {
                            onPlay(file, files.filter { !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty })
                        }
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
        .task(id: cid) {
            await load()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    mediaLibrary.add(files, for: appState)
                    if let onImported { onImported() } else { addedToHome = true }
                } label: {
                    Label("加入首页", systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(loading || !files.contains { $0.isVideo && !$0.pickCode.isEmpty })
            }
        }
        .alert("已加入首页媒体库", isPresented: $addedToHome) {
            Button("好", role: .cancel) { }
        } message: {
            Text("首页会自动匹配这些视频的海报，点击海报即可在线播放。")
        }
    }

    private func load() async {
        guard appState.isAuthenticated else {
            loading = false
            error = appState.isDirect ? "请先登录 115" : "请先在设置中连接服务器并登录"
            return
        }
        loading = true
        error = ""
        do {
            let listed: [P115File]
            if let direct = appState.directClient() {
                listed = try await direct.files(cid: cid)
            } else if let client = appState.client() {
                let response: FileListResponse = try await client.get("/api/files?cid=\(cid)")
                listed = response.files
            } else { throw APIError.server("未连接 115") }
            files = listed
                .filter { $0.isDir || $0.isVideo }
                .sorted { a, b in
                    if a.isDir != b.isDir { return a.isDir }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
        } catch let err {
            error = err.localizedDescription
        }
        loading = false
    }
}

/// 115 文件行：文件夹显示图标，视频优先显示网盘缩略图。
struct FileRow: View {
    let file: P115File
    var showsChevron = true

    var body: some View {
        HStack(spacing: 13) {
            thumbnail
                .frame(width: file.isDir ? 42 : 64, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if !file.isDir, !formatSize(file.size).isEmpty {
                    Text(formatSize(file.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            if showsChevron {
                Image(systemName: file.isDir ? "chevron.right" : "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(file.isDir ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(Theme.accent))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if file.isDir {
            Image(systemName: "folder.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.tileTint)
        } else if let url = URL(string: file.thumbUrl), !file.thumbUrl.isEmpty {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    videoPlaceholder
                }
            }
        } else {
            videoPlaceholder
        }
    }

    private var videoPlaceholder: some View {
        Image(systemName: "film")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [Theme.brandBlue.opacity(0.85), Theme.brandViolet.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}
