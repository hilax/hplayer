import SwiftUI
import UniformTypeIdentifiers

private struct TorrentSeed: Decodable, Identifiable {
    let id: String
    let name: String
    let isDir: Bool
    let sha1: String
    let pickCode: String
    let size: Int
}

private struct TorrentDirectoryPage: Decodable {
    let files: [TorrentSeed]
    let nextOffset: Int
    let hasMore: Bool
}

private struct TorrentUpload: Decodable {
    let sha1: String
    let pickCode: String
}

struct TorrentEntry: Decodable, Identifiable {
    let index: Int
    let path: String
    let size: Int
    let wanted: Bool
    var id: Int { index }
}

struct TorrentInfo: Decodable {
    let name: String
    let infoHash: String
    let sha1: String
    let pickCode: String
    let size: Int
    let files: [TorrentEntry]
}

struct TorrentTask: Decodable, Identifiable {
    let id: String
    let name: String
    let progress: Double
    let size: Int
    let status: Int
    var statusText: String {
        switch status {
        case -1: return "下载失败"
        case 0: return "分配中"
        case 1: return "下载中"
        case 2: return "已完成"
        default: return "状态 \(status)"
        }
    }
}

struct TorrentTasks: Decodable {
    let page: Int
    let pageCount: Int
    let count: Int
    let tasks: [TorrentTask]
}

private struct TorrentOK: Decodable { let ok: Bool }

struct TorrentView: View {
    private enum Field: Hashable { case savePath, folderId }
    @FocusState private var focusedField: Field?
    @EnvironmentObject private var appState: AppState
    @State private var importing = false
    @State private var browsing = false
    @State private var busy = false
    @State private var busyText = ""
    @State private var showingFiles = false
    @State private var info: TorrentInfo?
    @State private var selected: Set<Int> = []
    @State private var savePath = "HPlayer"
    @State private var folderId = "0"
    @State private var tasks: TorrentTasks?
    @State private var error = ""
    @State private var message = ""

    init(initialTasks: TorrentTasks? = nil) { _tasks = State(initialValue: initialTasks) }

    var body: some View {
        DesignPage(eyebrow: "Cloud download", title: "BT 云下载", subtitle: "解析种子，交给 115 保存。") {
            NavigationLink {
                Official115SettingsView(onSourceChanged: { Task { await loadTasks(page: 1) } })
            } label: {
                LibraryActionRow(symbol: "key.horizontal", title: "115 云下载授权", subtitle: "配置开放平台与云下载权限").surfaceCard()
            }.buttonStyle(.plain)
            VStack(spacing: 14) {
                Image(systemName: "doc.badge.arrow.up").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
                    .padding(.top, 12)
                Text("添加一个种子").font(.title3.bold())
                Text("选择 .torrent 文件，查看内容后再创建下载任务。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { importing = true } label: { Label("从手机导入 .torrent", systemImage: "plus") }
                    .buttonStyle(PrimaryActionStyle()).disabled(busy || !appState.isAuthenticated)
                Button { browsing = true } label: { Label("选择网盘中的种子", systemImage: "folder") }
                    .buttonStyle(SecondaryActionStyle()).disabled(busy || !appState.isAuthenticated)
            }.padding(22).surfaceCard()
            if busy { HStack(spacing: 12) { ProgressView(); Text(busyText).font(.subheadline).foregroundStyle(.secondary) } }
            if let info {
                Button { showingFiles = true } label: {
                    LibraryActionRow(symbol: "checklist", title: info.name, subtitle: "\(info.files.count) 个文件 · \(formatSize(info.size))", value: "选文件").surfaceCard()
                }.buttonStyle(.plain)
            }
            if !message.isEmpty { DesignNotice(symbol: "checkmark.circle", text: message) }
            if !error.isEmpty { DesignNotice(symbol: "exclamationmark.circle", text: error, warning: true) }
            HStack {
                Text("云下载任务").font(.headline)
                Spacer()
                Button("刷新") { Task { await loadTasks(page: tasks?.page ?? 1) } }
                    .font(.subheadline).disabled(!appState.isAuthenticated)
            }
            if let tasks, !tasks.tasks.isEmpty {
                ForEach(tasks.tasks) { task in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: task.status == 2 ? "checkmark.circle" : "arrow.down.circle")
                                .font(.title2).foregroundStyle(task.status == -1 ? Theme.warning : Theme.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.name).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text("\(task.statusText) · \(formatSize(task.size))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text("\(Int(max(0, min(100, task.progress))))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: max(0, min(100, task.progress)), total: 100).tint(Theme.accent)
                    }.padding(18).surfaceCard()
                }
                if tasks.pageCount > 1 {
                    HStack {
                        Button("上一页") { Task { await loadTasks(page: tasks.page - 1) } }.disabled(tasks.page <= 1)
                        Spacer(); Text("\(tasks.page) / \(tasks.pageCount)").font(.caption); Spacer()
                        Button("下一页") { Task { await loadTasks(page: tasks.page + 1) } }.disabled(tasks.page >= tasks.pageCount)
                    }
                }
            } else {
                Text("暂无可显示的任务").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24).surfaceCard()
            }
            DesignNotice(text: "需要先完成 115 官方授权。手机导入的种子会上传到网盘根目录；创建任务可能使用云下载配额。")
        }
        .navigationTitle("BT 云下载")
        .designScreen("torrent")
        .navigationDestination(isPresented: $showingFiles) {
            if let info {
                TorrentSelectionView(info: info, selected: $selected, savePath: $savePath, folderId: $folderId, busy: busy, error: error) {
                    Task { await submit(info) }
                }
            }
        }
        .task { if !InterfacePreview.active { await loadTasks(page: 1) } }
        .sheet(isPresented: $browsing) {
            TorrentBrowser { seed in
                browsing = false
                Task { await parse(sha1: seed.sha1, pickCode: seed.pickCode) }
            }.environmentObject(appState)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            switch result {
            case .success(let url): Task { await importTorrent(url) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
    }

    private func importTorrent(_ url: URL) async {
        guard let client = appState.client(), appState.isAuthenticated else { error = "请先登录 115"; return }
        busy = true; busyText = "正在上传种子…"; error = ""; message = ""; info = nil
        defer { busy = false }
        do {
            let bytes = try await Task.detached(priority: .userInitiated) {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                guard url.pathExtension.lowercased() == "torrent" else { throw APIError.server("请选择 .torrent 文件") }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 && size <= 4 * 1024 * 1024 else { throw APIError.server("种子文件必须小于 4 MB") }
                return try Data(contentsOf: url)
            }.value
            let uploaded: TorrentUpload = try await client.post("/api/115/torrent/upload", body: ["name": url.lastPathComponent, "data": bytes.base64EncodedString()])
            busyText = "正在解析种子…"
            try await parseWithClient(client, sha1: uploaded.sha1, pickCode: uploaded.pickCode)
        } catch { self.error = error.localizedDescription }
    }

    private func parse(sha1: String, pickCode: String) async {
        guard let client = appState.client(), appState.isAuthenticated else { error = "请先登录 115"; return }
        busy = true; busyText = "正在解析种子…"; error = ""; message = ""; info = nil
        defer { busy = false }
        do { try await parseWithClient(client, sha1: sha1, pickCode: pickCode) }
        catch { self.error = error.localizedDescription }
    }

    private func parseWithClient(_ client: APIClient, sha1: String, pickCode: String) async throws {
        let parsed: TorrentInfo = try await client.post("/api/115/torrent/parse", body: ["sha1": sha1, "pickCode": pickCode])
        info = parsed
        let defaults = parsed.files.filter(\.wanted).map(\.index)
        selected = Set(defaults.isEmpty ? parsed.files.map(\.index) : defaults)
        if parsed.files.isEmpty { error = "115 没有返回可下载的文件。" }
        else { showingFiles = true }
    }

    private func submit(_ info: TorrentInfo) async {
        guard let client = appState.client(), !selected.isEmpty else { return }
        busy = true; busyText = "正在创建任务…"; error = ""; message = ""
        defer { busy = false }
        do {
            let _: TorrentOK = try await client.post("/api/115/torrent/tasks", body: [
                "sha1": info.sha1, "pickCode": info.pickCode, "infoHash": info.infoHash,
                "wanted": selected.sorted().map(String.init).joined(separator: ","),
                "savePath": savePath.trimmingCharacters(in: .whitespacesAndNewlines), "folderId": folderId
            ])
            message = "已提交云下载任务，可在下方查看进度。"
            showingFiles = false
            self.info = nil; selected.removeAll()
            await loadTasks(page: 1)
        } catch { self.error = error.localizedDescription }
    }

    private func loadTasks(page: Int) async {
        guard let client = appState.client(), appState.isAuthenticated else { return }
        do { tasks = try await client.get("/api/115/torrent/tasks?page=\(page)") }
        catch { self.error = error.localizedDescription }
    }
}

private struct TorrentBrowser: View {
    let select: (TorrentSeed) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TorrentFolder(cid: "0", title: "115 网盘") { seed in select(seed); dismiss() }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

private struct TorrentFolder: View {
    let cid: String
    let title: String
    let select: (TorrentSeed) -> Void
    @EnvironmentObject private var appState: AppState
    @State private var files: [TorrentSeed] = []
    @State private var offset = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        List {
            ForEach(files) { file in
                if file.isDir {
                    NavigationLink { TorrentFolder(cid: file.id, title: file.name, select: select) } label: {
                        Label(file.name, systemImage: "folder.fill")
                    }
                } else {
                    Button { select(file) } label: {
                        HStack {
                            Label(file.name, systemImage: "doc.fill")
                            Spacer()
                            Text(formatSize(file.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if hasMore { Button("加载更多") { Task { await load() } }.disabled(loading) }
            if !loading && files.isEmpty && error.isEmpty && !hasMore { Text("此目录没有种子或文件夹").foregroundStyle(.secondary) }
        }
        .listRowSeparator(.hidden)
        .libraryFormStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !loading, let client = appState.client() else { error = "请先登录 115"; return }
        loading = true; error = ""
        defer { loading = false }
        do {
            let page: TorrentDirectoryPage = try await client.get("/api/115/torrent/files?cid=\(cid)&offset=\(offset)")
            files.append(contentsOf: page.files)
            offset = page.nextOffset; hasMore = page.hasMore
        } catch { self.error = error.localizedDescription }
    }
}
