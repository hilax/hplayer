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

private struct TorrentEntry: Decodable, Identifiable {
    let index: Int
    let path: String
    let size: Int
    let wanted: Bool
    var id: Int { index }
}

private struct TorrentInfo: Decodable {
    let name: String
    let infoHash: String
    let sha1: String
    let pickCode: String
    let size: Int
    let files: [TorrentEntry]
}

private struct TorrentTask: Decodable, Identifiable {
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

private struct TorrentTasks: Decodable {
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
    @State private var info: TorrentInfo?
    @State private var selected: Set<Int> = []
    @State private var savePath = "HPlayer"
    @State private var folderId = "0"
    @State private var tasks: TorrentTasks?
    @State private var error = ""
    @State private var message = ""

    var body: some View {
        List {
            if appState.isDirect {
                Section {
                    NavigationLink {
                        Official115SettingsView(onSourceChanged: { Task { await loadTasks(page: 1) } })
                    } label: {
                        Label("115 云下载授权", systemImage: "key.horizontal")
                    }
                } footer: {
                    Text("BT 云下载可在手机直接使用，但需在 115 开放平台申请 AppID 和上传、云下载权限。")
                }
            }
            Section {
                Button { importing = true } label: {
                    Label("从手机导入 .torrent", systemImage: "doc.badge.plus")
                }.disabled(busy || !appState.isAuthenticated)
                Button { browsing = true } label: {
                    Label("选择网盘中的种子", systemImage: "folder")
                }.disabled(busy || !appState.isAuthenticated)
                if busy { HStack { ProgressView(); Text(busyText).foregroundStyle(.secondary) } }
            } header: { Text("添加种子") }
            footer: { Text(appState.isDirect ? "需要先完成上方 115 官方授权。手机导入的种子会上传到你的 115 网盘根目录。" : "需要先连接服务器并使用 115 官方授权。手机导入的种子会上传到你的 115 网盘根目录。") }

            if let info {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(info.name.isEmpty ? "BT 种子" : info.name).font(.headline)
                        Text("\(info.files.count) 个文件 · \(formatSize(info.size))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("全选") { selected = Set(info.files.map(\.index)) }
                        Spacer()
                        Text("已选 \(selected.count) 项").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("清空") { selected.removeAll() }
                    }
                    ForEach(info.files) { file in
                        Button { toggle(file.index) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selected.contains(file.index) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(file.index) ? Theme.accent : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.path).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text(formatSize(file.size)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }.buttonStyle(.plain)
                    }
                } header: { Text("选择要下载的文件") }

                Section {
                    TextField("保存路径", text: $savePath)
                        .focused($focusedField, equals: .savePath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done).onSubmit { focusedField = nil }
                    TextField("目标文件夹 ID，根目录为 0", text: $folderId)
                        .focused($focusedField, equals: .folderId)
                        .keyboardType(.numberPad)
                    Button { Task { await submit(info) } } label: {
                        Label("创建云下载任务", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(busy || selected.isEmpty || savePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("保存位置") }
                footer: { Text("路径相对于目标文件夹。创建任务可能使用 115 云下载配额。") }
            }

            if !message.isEmpty { Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if !error.isEmpty { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }

            Section {
                if let tasks, !tasks.tasks.isEmpty {
                    ForEach(tasks.tasks) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.name).font(.subheadline.weight(.medium))
                            HStack {
                                Text(task.statusText)
                                Spacer()
                                Text("\(Int(max(0, min(100, task.progress))))% · \(formatSize(task.size))")
                            }.font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: max(0, min(100, task.progress)), total: 100)
                        }.padding(.vertical, 3)
                    }
                    if tasks.pageCount > 1 {
                        HStack {
                            Button("上一页") { Task { await loadTasks(page: tasks.page - 1) } }.disabled(tasks.page <= 1)
                            Spacer()
                            Text("\(tasks.page) / \(tasks.pageCount)").font(.caption)
                            Spacer()
                            Button("下一页") { Task { await loadTasks(page: tasks.page + 1) } }.disabled(tasks.page >= tasks.pageCount)
                        }
                    }
                } else {
                    Text("暂无可显示的任务").foregroundStyle(.secondary)
                }
                Button("刷新任务") { Task { await loadTasks(page: tasks?.page ?? 1) } }
                    .disabled(!appState.isAuthenticated)
            } header: { Text("115 云下载任务") }
        }
        .listRowSeparator(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .navigationTitle("BT 云下载")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTasks(page: 1) }
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
        guard let client = appState.client(), appState.isAuthenticated else { error = "请先连接服务器并登录"; return }
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
        guard let client = appState.client(), appState.isAuthenticated else { error = "请先连接服务器并登录"; return }
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard !loading, let client = appState.client() else { error = "请先连接服务器"; return }
        loading = true; error = ""
        defer { loading = false }
        do {
            let page: TorrentDirectoryPage = try await client.get("/api/115/torrent/files?cid=\(cid)&offset=\(offset)")
            files.append(contentsOf: page.files)
            offset = page.nextOffset; hasMore = page.hasMore
        } catch { self.error = error.localizedDescription }
    }
}
