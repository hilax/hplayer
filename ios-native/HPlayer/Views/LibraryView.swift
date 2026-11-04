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

struct DirectoryView: View {
    let cid: String
    /// 从网盘根目录到当前目录的路径，用来画面包屑；为空时不显示
    var trail: [Crumb] = []
    /// 点面包屑里的上级目录，参数是它在 trail 里的位置
    var onJump: ((Int) -> Void)? = nil
    let onOpenDir: (Crumb) -> Void
    let onPlay: (P115File, [P115File]) -> Void
    var onImported: (() -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @AppStorage("hplayer.library.sortKey") private var sortKey: FileSortKey = .name
    @AppStorage("hplayer.library.sortAscending") private var ascending = true
    @AppStorage("hplayer.library.foldersFirst") private var foldersFirst = true
    /// 目录里的全部内容（只保留文件夹和视频）
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

    init(cid: String, trail: [Crumb] = [], onJump: ((Int) -> Void)? = nil,
         onOpenDir: @escaping (Crumb) -> Void, onPlay: @escaping (P115File, [P115File]) -> Void,
         onImported: (() -> Void)? = nil, initialFiles: [P115File]? = nil, initialSelection: Set<String>? = nil) {
        self.cid = cid; self.trail = trail; self.onJump = onJump
        self.onOpenDir = onOpenDir; self.onPlay = onPlay; self.onImported = onImported
        _files = State(initialValue: initialFiles ?? [])
        _items = State(initialValue: initialFiles ?? [])
        _loading = State(initialValue: initialFiles == nil)
        _selecting = State(initialValue: initialSelection != nil)
        _selection = State(initialValue: initialSelection ?? [])
    }

    var body: some View {
        Group {
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
                EmptyStateView(
                    icon: AppIcon.folder.name,
                    title: "这个文件夹是空的",
                    message: "这里没有视频或子文件夹。"
                )
            } else {
                fileList
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen(selecting ? "files-select" : "files")
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 「加入首页」和「选择」都在右上角的更多菜单里，底部只在选择模式下显示操作栏
            if selecting { selectionBar }
        }
        .task(id: "\(cid)|\(appState.sessionID.uuidString)") {
            if !InterfacePreview.active { await load() }
        }
        .toolbar {
            if selecting {
                ToolbarItem(placement: .principal) { Text("选择视频").font(.headline) }
            }
            ToolbarItem(placement: .primaryAction) {
                toolbarControls
            }
        }
        .onChange(of: sortKey) { _ in applySort() }
        .onChange(of: ascending) { _ in applySort() }
        .onChange(of: foldersFirst) { _ in applySort() }
        .alert("已加入首页媒体库", isPresented: $addedToHome) {
            Button("好", role: .cancel) { }
        } message: {
            Text("首页会自动匹配这些视频的海报，点击海报即可在线播放。")
        }
    }

    // MARK: 列表

    private var fileList: some View {
        List {
            listHeader
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

            ForEach(Array(items.filter { !selecting || ($0.isVideo && !$0.pickCode.isEmpty) }.enumerated()), id: \.element.id) { index, file in
                Button {
                    tap(file)
                } label: {
                    FileRow(file: file, selecting: selecting, selected: selection.contains(file.id))
                }
                .buttonStyle(.pressable(scale: 0.98))
                .reveal(index, id: file.id)
                .listRowBackground(Color.clear)
                .listRowSeparator(.visible)
                .listRowSeparatorTint(Theme.hairline)
                .listRowInsets(EdgeInsets(top: 8, leading: Theme.contentInset, bottom: 8, trailing: Theme.contentInset))
                .accessibilityIdentifier("library.file.\(file.id)")
                .accessibilityAddTraits(selection.contains(file.id) ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: 面包屑与排序

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trail.count > 1 { breadcrumb }
            PageIntroduction(eyebrow: selecting ? "Select files" : "Your cloud library",
                             title: selecting ? "选择视频" : trail.last?.name ?? "115 网盘",
                             subtitle: "\(items.filter(\.isDir).count) 个文件夹 · \(items.filter { $0.isVideo }.count) 个视频", showsTitle: false)
                .padding(.vertical, 10)
            sortBar
        }
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
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("路径")
    }

    /// 排序方式常驻在列表顶部，点当前的那项再点一次就反向
    private var sortBar: some View {
        ScrollView(.horizontal) { HStack(spacing: 8) {
            ForEach(FileSortKey.allCases) { key in
                let active = key == sortKey
                Button {
                    chooseSort(key)
                } label: {
                    HStack(spacing: 4) {
                        Text(key.title)
                        if active {
                            Image(systemName: ascending ? AppIcon.sortAscending.name : AppIcon.sortDescending.name)
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .font(.system(size: 13, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(active ? Theme.tileTint : Color.clear, in: Capsule())
                }
                .buttonStyle(.pressable(scale: 0.93))
                .accessibilityAddTraits(active ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }

            Button {
                foldersFirst.toggle()
            } label: {
                HStack(spacing: 4) {
                    if foldersFirst {
                        Image(systemName: AppIcon.check.name)
                            .font(.caption2.weight(.bold))
                    }
                    Text("文件夹置顶")
                }
                .font(.system(size: 13, weight: foldersFirst ? .bold : .regular))
                .foregroundStyle(foldersFirst ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(foldersFirst ? Theme.tileTint : Color.clear, in: Capsule())
            }
            .buttonStyle(.pressable(scale: 0.93))
            .accessibilityAddTraits(foldersFirst ? AccessibilityTraits.isSelected : AccessibilityTraits())

        }}.scrollIndicators(.hidden)
    }

    private func tap(_ file: P115File) {
        guard currentAccountOwnsFiles else { return }
        if selecting {
            toggleSelection(file)
        } else if file.isDir {
            onOpenDir(Crumb(cid: file.id, name: file.name))
        } else {
            onPlay(file, items.filter { !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty })
        }
    }

    // MARK: 右上角菜单

    @ViewBuilder
    private var toolbarControls: some View {
        if selecting {
            HStack(spacing: 16) {
                Button(allSelected ? "全不选" : "全选") { toggleSelectAll() }
                Button("完成") { exitSelection() }
                    .fontWeight(.semibold)
            }
        } else {
            Menu {
                menuContent
            } label: {
                Image(systemName: AppIcon.more.name)
            }
            .disabled(loading)
            .accessibilityLabel("更多")
            .accessibilityIdentifier("library.menu")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button {
            startSelecting()
        } label: {
            Label("选择", systemImage: AppIcon.success.name)
        }
        .disabled(items.isEmpty)

        Section {
            Button {
                addAllToHome()
            } label: {
                Label("加入首页", systemImage: AppIcon.addToLibrary.name)
            }
            .disabled(!files.contains { $0.isVideo && !$0.pickCode.isEmpty })
        }
    }

    // MARK: 选择模式

    private var selectedVideos: [P115File] {
        items.filter { selection.contains($0.id) && !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty }
    }

    private var allSelected: Bool {
        let eligible = items.filter { $0.isVideo && !$0.pickCode.isEmpty }
        return !eligible.isEmpty && selection.count == eligible.count
    }

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

    private func actionPill(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let enabled = !selectedVideos.isEmpty
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(prominent ? Theme.onPrimary : Color.primary)
                .background(prominent ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(Theme.surfaceRaised), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
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
    }

    private func toggleSelectAll() {
        selection = allSelected ? [] : Set(items.filter { $0.isVideo && !$0.pickCode.isEmpty }.map(\.id))
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

    private func load() async {
        let sessionID = appState.sessionID
        let requestID = UUID()
        loadRequestID = requestID
        if loadedSessionID != sessionID {
            files = []; items = []; selection = []; selecting = false
            loadedSessionID = nil
        }
        guard appState.isAuthenticated, let direct = appState.directClient() else {
            loading = false
            error = "请先登录 115"
            return
        }
        loading = true
        error = ""
        defer {
            if loadRequestID == requestID { loading = false }
        }
        do {
            let listed = try await direct.files(cid: cid)
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
            files = listed.filter { $0.isDir || $0.isVideo }
            items = sortedFiles(files)
            loadedSessionID = sessionID
            selection = []
            selecting = false
        } catch {
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == loadRequestID else { return }
            self.error = error.localizedDescription
        }
    }
}

/// 115 文件行：左边是 96×54 的缩略图（视频用网盘截图，文件夹用金色线框文件夹），右边是名称和说明。
struct FileRow: View {
    let file: P115File
    var selecting = false
    var selected = false

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
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
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
                    videoPlaceholder
                }
            }
        } else {
            videoPlaceholder
        }
    }

    private var videoPlaceholder: some View {
        Image(systemName: AppIcon.video.name)
            .font(.system(size: 18, weight: Theme.iconWeight))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceRaised)
    }
}
