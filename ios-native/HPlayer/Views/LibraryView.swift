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
            } else if items.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "这个文件夹是空的",
                    message: "这里没有视频或子文件夹。"
                )
            } else {
                fileList
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar }
        }
        .task(id: cid) {
            await load()
        }
        .toolbar {
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

            ForEach(items) { file in
                Button {
                    tap(file)
                } label: {
                    FileRow(file: file, selecting: selecting, selected: selection.contains(file.id))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.visible)
                .listRowSeparatorTint(Theme.hairline)
                .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
                .accessibilityAddTraits(selection.contains(file.id) ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: 面包屑与排序

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trail.count > 1 {
                breadcrumb
            }
            sortBar
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(trail.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
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
                                .background(Theme.surface, in: Capsule())
                                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                        }
                        .buttonStyle(.plain)
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
        HStack(spacing: 8) {
            ForEach(FileSortKey.allCases) { key in
                let active = key == sortKey
                Button {
                    chooseSort(key)
                } label: {
                    HStack(spacing: 4) {
                        Text(key.title)
                        if active {
                            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .font(.footnote.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Theme.surface, in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }

            Button {
                foldersFirst.toggle()
            } label: {
                HStack(spacing: 4) {
                    if foldersFirst {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                    }
                    Text("文件夹置顶")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(foldersFirst ? Theme.accent : Color.secondary)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(foldersFirst ? AnyShapeStyle(Theme.tileTint) : AnyShapeStyle(Theme.surface), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(foldersFirst ? AccessibilityTraits.isSelected : AccessibilityTraits())

            Spacer(minLength: 0)
        }
    }

    private func tap(_ file: P115File) {
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
                Image(systemName: "ellipsis.circle")
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
            Label("选择", systemImage: "checkmark.circle")
        }
        .disabled(items.isEmpty)

        Section {
            Button {
                addAllToHome()
            } label: {
                Label("加入首页", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(!files.contains { $0.isVideo && !$0.pickCode.isEmpty })
        }
    }

    // MARK: 选择模式

    private var selectedVideos: [P115File] {
        items.filter { selection.contains($0.id) && !$0.isDir && $0.isVideo && !$0.pickCode.isEmpty }
    }

    private var allSelected: Bool {
        !items.isEmpty && selection.count == items.count
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "请选择文件" : "已选 \(selection.count) 项")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if onImported == nil {
                actionPill("播放", systemImage: "play.fill", prominent: false) { playSelected() }
            }
            actionPill("加入首页", systemImage: "rectangle.stack.badge.plus", prominent: true) { addSelectedToHome() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func actionPill(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let enabled = !selectedVideos.isEmpty
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceRaised), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func startSelecting() {
        selection = []
        withAnimation(.easeOut(duration: 0.2)) { selecting = true }
    }

    private func exitSelection() {
        withAnimation(.easeOut(duration: 0.2)) { selecting = false }
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
        selection = allSelected ? [] : Set(items.map { $0.id })
    }

    private func playSelected() {
        let videos = selectedVideos
        guard let first = videos.first else { return }
        exitSelection()
        onPlay(first, videos)
    }

    private func addSelectedToHome() {
        let videos = selectedVideos
        guard !videos.isEmpty else { return }
        mediaLibrary.add(videos, for: appState)
        exitSelection()
        finishImport()
    }

    private func addAllToHome() {
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

    private func load() async {
        guard appState.isAuthenticated else {
            loading = false
            error = "请先登录 115"
            return
        }
        loading = true
        error = ""
        do {
            let listed: [P115File]
            guard let direct = appState.directClient() else { throw APIError.server("未连接 115") }
            listed = try await direct.files(cid: cid)
            files = listed.filter { $0.isDir || $0.isVideo }
            items = sortedFiles(files)
            selection = []
            selecting = false
        } catch let err {
            error = err.localizedDescription
        }
        loading = false
    }
}

/// 115 文件行：左边是淡色圆角底块，文件夹放黄色文件夹图标，视频优先显示网盘缩略图；右边是名称和说明。
struct FileRow: View {
    let file: P115File
    var selecting = false
    var selected = false

    private static let tileSize = CGSize(width: 96, height: 54)

    var body: some View {
        HStack(spacing: 14) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Theme.accent : Color(uiColor: .tertiaryLabel))
                    .transition(.scale.combined(with: .opacity))
            }

            thumbnail
                .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(file.name)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: selecting)
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
            FolderGlyph()
                .frame(width: 44, height: 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.folderTile)
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
            .font(.system(size: 18, weight: .semibold))
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
