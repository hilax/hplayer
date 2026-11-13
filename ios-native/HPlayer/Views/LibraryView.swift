import SwiftUI

struct Crumb: Hashable {
    let cid: String
    let name: String
}

/// 目录里文件的排序依据
enum FileSortKey: String, CaseIterable, Identifiable {
    case name
    case size
    case date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .date: return "日期"
        }
    }
}

/// 目录页弹出的各种面板
enum DirectorySheet: Identifiable {
    case newFolder
    case rename(P115File)
    case delete([P115File])
    case destination([P115File], FileDestinationMode)
    case info(P115File)

    var id: String {
        switch self {
        case .newFolder:
            return "new-folder"
        case .rename(let file):
            return "rename|" + file.id
        case .delete(let files):
            return "delete|" + files.map { $0.id }.joined(separator: ",")
        case .destination(let files, let mode):
            return "destination|" + mode.rawValue + "|" + files.map { $0.id }.joined(separator: ",")
        case .info(let file):
            return "info|" + file.id
        }
    }
}

/// 目录页「更多」菜单里能打开的二级页面
enum ManagementPage: Hashable {
    /// 传输中心：云端离线、本机下载、边下边播汇总在一页
    case transfers
    case offline
    case recycleBin
    case downloads
}

struct DirectoryView: View {
    let cid: String
    /// 从网盘根目录到当前目录的路径，用来画面包屑；为空时不显示
    var trail: [Crumb] = []
    /// 点面包屑里的上级目录，参数是它在 trail 里的位置
    var onJump: ((Int) -> Void)? = nil
    let onOpenDir: (Crumb) -> Void
    let onPlay: (P115File, [P115File]) -> Void
    var onImported: (() -> Void)? = nil
    /// 网盘页里的目录开启完整的文件管理（新建、重命名、移动、复制、删除、信息、下载）；
    /// 导入流程里的目录选择保持原样，只能选视频。
    var management = false
    /// 菜单里的离线下载、回收站、下载管理由上一层的导航栈打开
    var onOpenPage: ((ManagementPage) -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @AppStorage("hplayer.library.sortKey") private var sortKey: FileSortKey = .name
    @AppStorage("hplayer.library.sortAscending") private var ascending = true
    @AppStorage("hplayer.library.foldersFirst") private var foldersFirst = true
    /// 管理模式下可以显示全部类型的文件，默认只显示文件夹和视频
    @AppStorage("hplayer.library.showAllFiles") private var showAllFiles = false
    /// 删除时是否同时清理资料库，记住用户上次的选择
    @AppStorage("hplayer.files.removeFromLibrary") private var removeFromLibrary = false
    /// 目录里读到的全部内容
    @State private var listed: [P115File] = []
    /// 目录里的内容（默认只保留文件夹和视频）
    @State private var files: [P115File] = []
    /// 按当前排序方式排好的列表，界面显示这个
    @State private var items: [P115File] = []
    @State private var loading = true
    @State private var error = ""
    @State private var addedToHome = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var loadRequestID = UUID()
    @State private var loadedSessionID: UUID?
    @State private var sheet: DirectorySheet?
    /// 正在进行的网盘操作；非空时界面显示进度并挡住重复点击
    @State private var operation: String?
    /// 操作失败的原因
    @State private var problem: String?
    /// 操作完成后的轻提示
    @State private var message: String?
    private let previewInfo: Direct115FileInfo?

    init(cid: String, trail: [Crumb] = [], onJump: ((Int) -> Void)? = nil,
         onOpenDir: @escaping (Crumb) -> Void, onPlay: @escaping (P115File, [P115File]) -> Void,
         onImported: (() -> Void)? = nil, management: Bool = false,
         onOpenPage: ((ManagementPage) -> Void)? = nil,
         initialFiles: [P115File]? = nil, initialSelection: Set<String>? = nil,
         initialSheet: DirectorySheet? = nil, initialInfo: Direct115FileInfo? = nil) {
        self.cid = cid; self.trail = trail; self.onJump = onJump
        self.onOpenDir = onOpenDir; self.onPlay = onPlay; self.onImported = onImported
        self.management = management; self.onOpenPage = onOpenPage
        self.previewInfo = initialInfo
        _listed = State(initialValue: initialFiles ?? [])
        _files = State(initialValue: initialFiles ?? [])
        _items = State(initialValue: initialFiles ?? [])
        _loading = State(initialValue: initialFiles == nil)
        _selecting = State(initialValue: initialSelection != nil)
        _selection = State(initialValue: initialSelection ?? [])
        _sheet = State(initialValue: initialSheet)
    }

    var body: some View {
        content
            .background(Theme.pageBackground.ignoresSafeArea())
            .designScreen(selecting ? "files-select" : "files")
            .toolbar(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(selecting)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 非选择模式下，「加入首页」和「选择」都在右上角的更多菜单里
                bottomBar
            }
            .task(id: "\(cid)|\(appState.sessionID.uuidString)") {
                if !InterfacePreview.active { await load() }
            }
            .toolbar { toolbarItems }
            .onChange(of: sortKey) { _ in applySort() }
            .onChange(of: ascending) { _ in applySort() }
            .onChange(of: foldersFirst) { _ in applySort() }
            .onChange(of: showAllFiles) { _ in applyVisibility() }
            .overlay { operationOverlay }
            .toast($message)
            .sheet(item: $sheet) { current in
                sheetContent(current)
            }
            .alert("已加入首页媒体库", isPresented: $addedToHome) {
                Button("好", role: .cancel) { }
            } message: {
                Text("首页会自动匹配这些视频的海报，点击海报即可在线播放。")
            }
            .alert("操作没有完成", isPresented: problemBinding) {
                Button("好", role: .cancel) { }
            } message: {
                Text(problem ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !error.isEmpty {
            EmptyStateView(
                icon: AppIcon.alert.name,
                title: "目录加载失败",
                message: error,
                actionTitle: "重试",
                action: { Task { await load() } }
            )
        } else if items.isEmpty {
            emptyFolder
        } else {
            fileList
        }
    }

    private var problemBinding: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }

    @ViewBuilder
    private var operationOverlay: some View {
        if let text = operation {
            OperationOverlay(text: text)
        }
    }

    @ViewBuilder
    private var emptyFolder: some View {
        if management {
            EmptyStateView(
                icon: AppIcon.folder.name,
                title: "这个文件夹是空的",
                message: showAllFiles ? "可以从右上角的菜单新建文件夹。" : "这里没有视频或子文件夹。可以从右上角的菜单新建文件夹，或显示全部类型的文件。",
                actionTitle: "新建文件夹",
                action: { sheet = .newFolder }
            )
        } else {
            EmptyStateView(
                icon: AppIcon.folder.name,
                title: "这个文件夹是空的",
                message: "这里没有视频或子文件夹。"
            )
        }
    }

    // MARK: 列表

    /// 当前显示的条目：导入流程的选择模式里只留可以选的视频
    private var visibleItems: [P115File] {
        if selecting && !management { return items.filter { $0.isVideo && !$0.pickCode.isEmpty } }
        return items
    }

    private var fileList: some View {
        let libraryCodes: Set<String> = management ? mediaLibrary.pickCodes(for: appState) : []
        let rows = Array(visibleItems.enumerated())
        return List {
            listHeader
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

            ForEach(rows, id: \.element.id) { index, file in
                fileRow(file, index: index, inLibrary: libraryCodes.contains(file.pickCode))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await load(silent: true) }
    }

    @ViewBuilder
    private func fileRow(_ file: P115File, index: Int, inLibrary: Bool) -> some View {
        let selected = selection.contains(file.id)
        HStack(spacing: 0) {
            Button {
                tap(file)
            } label: {
                FileRow(file: file, selecting: selecting, selected: selected, inLibrary: inLibrary)
            }
            .buttonStyle(.pressable(scale: 0.98))
            .accessibilityIdentifier("library.file.\(file.id)")
            .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
            if management && !selecting && !file.isDir {
                rowMenu(file)
            }
        }
        .reveal(index, id: file.id)
        .contextMenu {
            if management && !selecting { rowActions(file) }
        }
        .listRowBackground(selected ? Theme.tileTint : Color.clear)
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Theme.hairline)
        .listRowInsets(EdgeInsets(top: 8, leading: Theme.contentInset, bottom: 8, trailing: Theme.contentInset))
    }

    private func rowMenu(_ file: P115File) -> some View {
        Menu {
            rowActions(file)
        } label: {
            Image(systemName: AppIcon.more.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("文件菜单")
        .accessibilityIdentifier("library.rowMenu.\(file.id)")
    }

    /// 单个文件或文件夹的操作，行右侧的菜单和长按菜单共用
    @ViewBuilder
    private func rowActions(_ file: P115File) -> some View {
        Button {
            sheet = .rename(file)
        } label: {
            Label("重命名", systemImage: AppIcon.rename.name)
        }
        Button {
            sheet = .destination([file], .move)
        } label: {
            Label("移动到…", systemImage: AppIcon.moveTo.name)
        }
        Button {
            sheet = .destination([file], .copy)
        } label: {
            Label("复制到…", systemImage: AppIcon.copy.name)
        }
        if !file.isDir {
            Button {
                download([file])
            } label: {
                Label("下载到手机", systemImage: AppIcon.download.name)
            }
        }
        if file.isVideo && !file.pickCode.isEmpty {
            Button {
                addToHome([file])
            } label: {
                Label("加入首页", systemImage: AppIcon.addToLibrary.name)
            }
        }
        Button {
            sheet = .info(file)
        } label: {
            Label("信息", systemImage: AppIcon.info.name)
        }
        Button(role: .destructive) {
            sheet = .delete([file])
        } label: {
            Label("删除", systemImage: AppIcon.trash.name)
        }
    }

    // MARK: 面包屑与排序

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trail.count > 1 { breadcrumb }
            summaryLine
        }
    }

    private var summaryText: String {
        let folders = items.filter { $0.isDir }.count
        let videos = items.filter { $0.isVideo }.count
        let others = items.count - folders - videos
        var parts = ["\(folders) 个文件夹", "\(videos) 个视频"]
        if others > 0 { parts.append("\(others) 个其他文件") }
        return "\(items.count) 项 · " + parts.joined(separator: "，")
    }

    /// 「8 项 · 3 个文件夹，5 个视频」和排序方式；点排序方式换一种，再点当前的就反向
    private var summaryLine: some View {
        HStack(spacing: 8) {
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("library.summary")
            Spacer(minLength: 8)
            Menu {
                sortOptions
            } label: {
                HStack(spacing: 4) {
                    Text(sortKey.title)
                    Image(systemName: ascending ? AppIcon.sortAscending.name : AppIcon.sortDescending.name)
                        .font(.caption2.weight(.bold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("排序方式")
            .accessibilityIdentifier("library.sort")
        }
    }

    @ViewBuilder
    private var sortOptions: some View {
        ForEach(FileSortKey.allCases) { key in
            Button {
                chooseSort(key)
            } label: {
                if key == sortKey {
                    Label("\(key.title) \(ascending ? "↑" : "↓")", systemImage: AppIcon.check.name)
                } else {
                    Text(key.title)
                }
            }
        }
        Toggle("文件夹置顶", isOn: $foldersFirst)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(trail.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: AppIcon.forward.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    if index == trail.count - 1 {
                        Text(crumb.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: 180)
                            .frame(height: 28)
                            .background(Theme.tileTint, in: Capsule())
                            .accessibilityIdentifier("library.crumb.\(crumb.cid)")
                    } else {
                        Button {
                            onJump?(index)
                        } label: {
                            Text(crumb.name)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: 160)
                                .frame(height: 28)
                                .background(Theme.surfaceRaised, in: Capsule())
                        }
                        .buttonStyle(.pressable(scale: 0.94))
                        .disabled(onJump == nil)
                        .accessibilityIdentifier("library.crumb.\(crumb.cid)")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("路径")
    }

    private func tap(_ file: P115File) {
        guard currentAccountOwnsFiles else { return }
        if selecting {
            toggleSelection(file)
        } else if file.isDir {
            onOpenDir(Crumb(cid: file.id, name: file.name))
        } else if file.isVideo {
            onPlay(file, items.filter { !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty })
        } else {
            sheet = .info(file)
        }
    }

    // MARK: 顶栏

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .principal) {
                Text(selectionTitle)
                    .font(.headline)
                    .accessibilityIdentifier("library.selectionTitle")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "全不选" : "全选") { toggleSelectAll() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { exitSelection() }
                    .fontWeight(.semibold)
            }
        }
        if !selecting {
            ToolbarItem(placement: .primaryAction) {
                moreMenu
            }
        }
    }

    private var selectionTitle: String {
        if !management { return "选择视频" }
        return selection.isEmpty ? "选择项目" : "已选 \(selection.count) 项"
    }

    private var moreMenu: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: AppIcon.more.name)
        }
        .disabled(loading)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("library.menu")
    }

    @ViewBuilder
    private var menuContent: some View {
        if management {
            Button {
                sheet = .newFolder
            } label: {
                Label("新建文件夹", systemImage: AppIcon.newFolder.name)
            }
        }
        Button {
            startSelecting()
        } label: {
            Label("选择", systemImage: AppIcon.success.name)
        }
        .disabled(items.isEmpty)
        if management {
            Menu {
                sortOptions
            } label: {
                Label("排序方式", systemImage: AppIcon.sort.name)
            }
            Section {
                Button {
                    onOpenPage?(.transfers)
                } label: {
                    Label("传输中心", systemImage: AppIcon.cloudDownload.name)
                }
                Button {
                    onOpenPage?(.recycleBin)
                } label: {
                    Label("回收站", systemImage: AppIcon.recycleBin.name)
                }
            }
            Section {
                Toggle("显示全部文件类型", isOn: $showAllFiles)
            }
        }
        Section {
            Button {
                addAllToHome()
            } label: {
                Label(management ? "把此文件夹加入首页" : "加入首页", systemImage: AppIcon.addToLibrary.name)
            }
            .disabled(!files.contains { $0.isVideo && !$0.pickCode.isEmpty })
            if management {
                Button {
                    Task { await load(silent: true) }
                } label: {
                    Label("刷新", systemImage: AppIcon.refresh.name)
                }
            }
        }
    }

    // MARK: 选择模式

    private var selectedItems: [P115File] {
        items.filter { selection.contains($0.id) }
    }

    private var selectedVideos: [P115File] {
        items.filter { selection.contains($0.id) && !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty }
    }

    private var allSelected: Bool {
        let eligible = visibleItems
        return !eligible.isEmpty && selection.count == eligible.count
    }

    @ViewBuilder
    private var bottomBar: some View {
        if selecting {
            if management { dock } else { selectionBar }
        }
    }

    /// 管理模式的底部操作栏
    private var dock: some View {
        let chosen = selectedItems
        let single = chosen.count == 1
        return FileActionDock(
            summary: FileSelectionSummary(chosen),
            busy: operation != nil,
            canRename: single,
            canInspect: single,
            canDownload: chosen.contains { !$0.isDir && !$0.pickCode.isEmpty },
            canAddToHome: chosen.contains { $0.isVideo && !$0.pickCode.isEmpty },
            onMove: { sheet = .destination(chosen, .move) },
            onCopy: { sheet = .destination(chosen, .copy) },
            onRename: { if let file = chosen.first { sheet = .rename(file) } },
            onInfo: { if let file = chosen.first { sheet = .info(file) } },
            onDownload: { download(chosen) },
            onAddToHome: { addToHome(chosen.filter { $0.isVideo && !$0.pickCode.isEmpty }) },
            onDelete: { sheet = .delete(chosen) }
        )
    }

    /// 导入流程的底部操作栏
    private var selectionBar: some View {
        VStack(spacing: 10) {
            if onImported == nil {
                Button { playSelected() } label: { Label("播放所选 · \(selectedVideos.count) 项", systemImage: AppIcon.play.name) }
                    .buttonStyle(PrimaryActionStyle()).disabled(selectedVideos.isEmpty)
            }
            Button(action: addSelectedToHome) { Label("加入首页", systemImage: AppIcon.add.name) }
                .buttonStyle(SecondaryActionStyle()).disabled(selectedVideos.isEmpty)
            Text("按当前列表顺序连续播放所选视频。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, Theme.contentInset).padding(.vertical, 12)
            .background(Theme.pageBackground)
    }

    private func startSelecting() {
        selection = []
        withAnimation(Motion.snappy) { selecting = true }
    }

    private func exitSelection() {
        withAnimation(Motion.snappy) { selecting = false }
        selection = []
    }

    private func toggleSelection(_ file: P115File) {
        if selection.contains(file.id) {
            selection.remove(file.id)
        } else {
            selection.insert(file.id)
        }
        Haptics.select()
    }

    private func toggleSelectAll() {
        selection = allSelected ? [] : Set(visibleItems.map { $0.id })
    }

    private func playSelected() {
        guard currentAccountOwnsFiles else { return }
        let videos = selectedVideos
        guard let first = videos.first else { return }
        exitSelection()
        onPlay(first, videos)
    }

    private func addSelectedToHome() {
        guard currentAccountOwnsFiles else { return }
        let videos = selectedVideos
        guard !videos.isEmpty else { return }
        mediaLibrary.add(videos, for: appState)
        exitSelection()
        finishImport()
    }

    private func addAllToHome() {
        guard currentAccountOwnsFiles else { return }
        mediaLibrary.add(files, for: appState)
        finishImport()
    }

    private func finishImport() {
        if let onImported { onImported() } else { addedToHome = true }
    }

    // MARK: 弹层

    private var previewFolders: [P115File]? {
        InterfacePreview.active ? listed.filter { $0.isDir } : nil
    }

    @ViewBuilder
    private func sheetContent(_ current: DirectorySheet) -> some View {
        switch current {
        case .newFolder:
            NamePromptSheet(title: "新建文件夹", hint: "会创建在当前文件夹里面。", confirmTitle: "创建",
                            placeholder: "文件夹名称") { name in
                createFolder(name)
            }
        case .rename(let file):
            NamePromptSheet(title: "重命名", confirmTitle: "完成", placeholder: "新名称", initial: file.name) { name in
                rename(file, to: name)
            }
        case .delete(let chosen):
            DeleteConfirmSheet(files: chosen, libraryVideoCount: affectedLibraryCount(chosen),
                               removeFromLibrary: $removeFromLibrary) {
                delete(chosen)
            }
        case .destination(let chosen, let mode):
            FolderPickerSheet(client: appState.directClient(), files: chosen, sourceFolderID: cid, trail: trail,
                              mode: mode, preloadedFolders: previewFolders) { chosenMode, destination in
                transfer(chosen, mode: chosenMode, to: destination)
            }
        case .info(let file):
            NavigationStack {
                FileInfoSheet(file: file, client: appState.directClient(),
                              inLibrary: mediaLibrary.pickCodes(for: appState).contains(file.pickCode),
                              onPlay: infoPlayAction(for: file),
                              onRename: { switchSheet(to: .rename(file)) },
                              onDownload: infoDownloadAction(for: file),
                              preloaded: previewInfo)
            }
        }
    }

    private func infoPlayAction(for file: P115File) -> (() -> Void)? {
        guard file.isVideo, !file.pickCode.isEmpty else { return nil }
        return {
            sheet = nil
            onPlay(file, items.filter { !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty })
        }
    }

    private func infoDownloadAction(for file: P115File) -> (() -> Void)? {
        guard !file.isDir, !file.pickCode.isEmpty else { return nil }
        return {
            sheet = nil
            download([file])
        }
    }

    /// 从一个面板换到另一个面板：先收起，等动画结束再弹出，避免系统吞掉第二次弹出
    private func switchSheet(to next: DirectorySheet) {
        sheet = nil
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            sheet = next
        }
    }

    private func affectedLibraryCount(_ chosen: [P115File]) -> Int {
        LibraryFileSync.affectedVideos(chosen, library: mediaLibrary, appState: appState).count
    }

    // MARK: 文件管理操作

    /// 执行一个网盘操作：显示进度，成功后给出提示，失败时说明原因；最后悄悄刷新目录。
    private func runOperation(_ title: String, _ work: @escaping (Direct115Client) async throws -> String?) {
        guard operation == nil, currentAccountOwnsFiles, let client = appState.directClient() else { return }
        let sessionID = appState.sessionID
        operation = title
        Task {
            var done: String?
            var failure: String?
            do {
                done = try await work(client)
            } catch is CancellationError {
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            operation = nil
            guard sessionID == appState.sessionID else { return }
            if let failure {
                Haptics.warning()
                problem = failure
            } else {
                Haptics.success()
                if selecting { exitSelection() }
                if let done { message = done }
            }
            await load(silent: true)
        }
    }

    private func createFolder(_ name: String) {
        let parent = cid
        runOperation("正在新建文件夹…") { client in
            let folder = try await client.createFolder(named: name, in: parent)
            return "已新建「\(folder.name)」"
        }
    }

    private func rename(_ file: P115File, to name: String) {
        guard name != file.name else { return }
        runOperation("正在重命名…") { client in
            let clean = try Direct115Client.validatedName(name)
            try await client.rename(file.id, to: clean)
            LibraryFileSync.didRename(file.replacing(name: clean), library: mediaLibrary, appState: appState)
            return "已重命名为「\(clean)」"
        }
    }

    private func transfer(_ chosen: [P115File], mode: FileDestinationMode, to destination: Crumb) {
        let ids = chosen.map { $0.id }
        let name = destination.name
        switch mode {
        case .move:
            runOperation("正在移动 \(chosen.count) 项…") { client in
                try await client.move(ids, to: destination.cid)
                LibraryFileSync.didMove(chosen, to: destination.cid, library: mediaLibrary, appState: appState)
                return "已移动到「\(name)」"
            }
        case .copy:
            runOperation("正在复制 \(chosen.count) 项…") { client in
                try await client.copy(ids, to: destination.cid)
                return "已复制到「\(name)」"
            }
        }
    }

    private func delete(_ chosen: [P115File]) {
        let alsoLibrary = removeFromLibrary
        runOperation("正在移入回收站…") { client in
            try await client.moveToRecycleBin(chosen.map { $0.id })
            let removed = LibraryFileSync.didDelete(chosen, removeFromLibrary: alsoLibrary, library: mediaLibrary,
                                                    recents: RecentStore.shared, appState: appState)
            if removed > 0 { return "已移入回收站，并从资料库移除 \(removed) 个视频" }
            return "已移入回收站"
        }
    }

    private func download(_ chosen: [P115File]) {
        let summary = DownloadManager.shared.enqueue(chosen, folderLabel: FileOperationText.pathLabel(trail))
        if summary.added > 0 { Haptics.success() } else { Haptics.warning() }
        message = FileOperationText.downloadResult(summary)
        if selecting { exitSelection() }
    }

    private func addToHome(_ videos: [P115File]) {
        guard currentAccountOwnsFiles, !videos.isEmpty else { return }
        mediaLibrary.add(videos, for: appState)
        Haptics.success()
        message = "已把 \(videos.count) 个视频加入首页"
        if selecting { exitSelection() }
    }

    // MARK: 排序

    /// 点当前排序方式再点一次就反向；换一种方式时，名称从 A 到 Z，大小和日期从大到小、从新到旧。
    private func chooseSort(_ key: FileSortKey) {
        if key == sortKey {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = key == .name
        }
    }

    private func applySort() {
        items = sortedFiles(files)
    }

    /// 管理模式可以显示全部类型的文件，其余情况只留文件夹和视频
    private func applyVisibility() {
        let showEverything = management && showAllFiles
        files = showEverything ? listed : listed.filter { $0.isDir || $0.isVideo }
        items = sortedFiles(files)
        selection = selection.intersection(Set(items.map { $0.id }))
    }

    private func sortedFiles(_ source: [P115File]) -> [P115File] {
        let key = sortKey
        let isAscending = ascending
        let pinFolders = foldersFirst
        // 日期要从文本里解析，先算好一遍，排序时直接取
        let dates: [String: Date] = key == .date
            ? Dictionary(source.map { ($0.id, $0.updatedDate ?? Date.distantPast) }, uniquingKeysWith: { first, _ in first })
            : [:]

        return source.sorted { a, b in
            if pinFolders, a.isDir != b.isDir { return a.isDir }
            let order: ComparisonResult
            switch key {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .size:
                order = Self.compare(a.size, b.size)
            case .date:
                order = Self.compare(dates[a.id] ?? Date.distantPast, dates[b.id] ?? Date.distantPast)
            }
            if order == .orderedSame {
                // 大小、日期相同时按名称从 A 到 Z，顺序保持稳定
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return isAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    // MARK: 加载

    private var currentAccountOwnsFiles: Bool {
        InterfacePreview.active || (appState.isAuthenticated && loadedSessionID == appState.sessionID)
    }

    /// `silent` 为 true 时不出现转圈，也不会因为失败把已有的列表换成错误页（操作之后的刷新、下拉刷新用）
    private func load(silent: Bool = false) async {
        let sessionID = appState.sessionID
        let requestID = UUID()
        loadRequestID = requestID
        if loadedSessionID != sessionID {
            listed = []; files = []; items = []; selection = []; selecting = false
            loadedSessionID = nil
        }
        guard appState.isAuthenticated, let direct = appState.directClient() else {
            loading = false
            error = "请先登录 115"
            return
        }
        let showsSpinner = !silent || loadedSessionID == nil
        if showsSpinner {
            loading = true
            error = ""
        }
        defer {
            if loadRequestID == requestID { loading = false }
        }
        do {
            let result = try await direct.files(cid: cid)
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
            listed = result
            applyVisibility()
            loadedSessionID = sessionID
            error = ""
            if !silent {
                selection = []
                selecting = false
            }
        } catch {
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
            if showsSpinner { self.error = error.localizedDescription }
        }
    }
}

/// 115 文件行：左边是 96×54 的缩略图（视频用网盘截图，文件夹用金色线框文件夹），右边是名称和说明。
struct FileRow: View {
    let file: P115File
    var selecting = false
    var selected = false
    /// 这个视频已经在 HPlayer 资料库里
    var inLibrary = false

    private static let tileSize = CGSize(width: 96, height: 54)

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                CheckBadge(selected: selected, size: 24)
                    .transition(.scale.combined(with: .opacity))
            }

            thumbnail
                .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty || inLibrary {
                    HStack(spacing: 6) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        if inLibrary {
                            Text("已入库")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .fixedSize()
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            if file.isDir && !selecting {
                Image(systemName: AppIcon.forward.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .animation(Motion.snappy, value: selecting)
    }

    private var subtitle: String {
        var parts: [String] = []
        let size = formatSize(file.size)
        if !file.isDir, !size.isEmpty { parts.append(size) }
        if let date = file.updatedDate { parts.append(Self.dayFormatter.string(from: date)) }
        return parts.joined(separator: "  ·  ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @ViewBuilder
    private var thumbnail: some View {
        if file.isDir {
            Image(systemName: AppIcon.folder.name)
                .font(.system(size: 24, weight: Theme.iconWeight))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.tileTint)
        } else if let url = URL(string: file.thumbUrl), !file.thumbUrl.isEmpty {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: file.isVideo ? AppIcon.video.name : AppIcon.file.name)
            .font(.system(size: 18, weight: Theme.iconWeight))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceRaised)
    }
}
