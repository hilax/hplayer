import SwiftUI

/// 待扫描的一个 115 文件夹目标。
struct ScanFolderTarget: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 选择要扫描的 115 文件夹：支持单选（清理失效文件）和多选（媒体库管理）。
/// 多选模式下可在不同层级勾选多个文件夹，底部统一启动扫描并在扫到视频时自动匹配封面。
struct ScanFolderPicker: View {
    private let allowsMultipleSelection: Bool
    private let onSelectSingle: ((String, String) -> Void)?
    private let onSelectMultiple: (([ScanFolderTarget]) -> Void)?
    var initialFolders: [P115File]? = nil
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Crumb] = []
    @State private var selectedFolders: [ScanFolderTarget] = []

    init(onSelect: @escaping (String, String) -> Void, initialFolders: [P115File]? = nil) {
        self.allowsMultipleSelection = false
        self.onSelectSingle = onSelect
        self.onSelectMultiple = nil
        self.initialFolders = initialFolders
    }

    init(onSelectFolders: @escaping ([ScanFolderTarget]) -> Void, initialFolders: [P115File]? = nil) {
        self.allowsMultipleSelection = true
        self.onSelectSingle = nil
        self.onSelectMultiple = onSelectFolders
        self.initialFolders = initialFolders
    }

    var body: some View {
        NavigationStack(path: $path) {
            FolderList(
                cid: "0",
                name: "115 网盘",
                allowsMultipleSelection: allowsMultipleSelection,
                selectedFolders: $selectedFolders,
                onOpen: { path.append($0) },
                onConfirm: confirm,
                initialFolders: initialFolders
            )
            .libraryFormStyle()
            .navigationTitle("选择要扫描的文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Crumb.self) { crumb in
                FolderList(
                    cid: crumb.cid,
                    name: crumb.name,
                    allowsMultipleSelection: allowsMultipleSelection,
                    selectedFolders: $selectedFolders,
                    onOpen: { path.append($0) },
                    onConfirm: confirm
                )
                .libraryFormStyle()
                .navigationTitle(crumb.name)
                .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .navigationButtonTint()
        .hudHost(.sheet)
        .onChange(of: appState.sessionID) { _ in
            path = []
            selectedFolders = []
        }
    }

    private func confirm(_ targets: [ScanFolderTarget]) {
        guard let first = targets.first else { return }
        if allowsMultipleSelection {
            onSelectMultiple?(targets)
        } else {
            onSelectSingle?(first.id, first.name)
        }
        dismiss()
    }
}

private struct FolderList: View {
    let cid: String
    let name: String
    let allowsMultipleSelection: Bool
    @Binding var selectedFolders: [ScanFolderTarget]
    let onOpen: (Crumb) -> Void
    let onConfirm: ([ScanFolderTarget]) -> Void
    @EnvironmentObject private var appState: AppState
    @State private var folders: [P115File] = []
    @State private var loading = true
    @State private var error = ""
    @State private var requestID = UUID()

    init(
        cid: String,
        name: String,
        allowsMultipleSelection: Bool,
        selectedFolders: Binding<[ScanFolderTarget]>,
        onOpen: @escaping (Crumb) -> Void,
        onConfirm: @escaping ([ScanFolderTarget]) -> Void,
        initialFolders: [P115File]? = nil
    ) {
        self.cid = cid
        self.name = name
        self.allowsMultipleSelection = allowsMultipleSelection
        _selectedFolders = selectedFolders
        self.onOpen = onOpen
        self.onConfirm = onConfirm
        _folders = State(initialValue: initialFolders ?? [])
        _loading = State(initialValue: initialFolders == nil)
    }

    private var currentTarget: ScanFolderTarget { ScanFolderTarget(id: cid, name: name) }
    private var currentSelected: Bool { isSelected(cid) }

    private func isSelected(_ id: String) -> Bool {
        selectedFolders.contains { $0.id == id }
    }

    private func toggleSelection(_ target: ScanFolderTarget) {
        Haptics.select()
        if let index = selectedFolders.firstIndex(where: { $0.id == target.id }) {
            selectedFolders.remove(at: index)
        } else {
            selectedFolders.append(target)
        }
    }

    private var primaryButtonTitle: String {
        if allowsMultipleSelection && !selectedFolders.isEmpty {
            if selectedFolders.count == 1 {
                return "扫描「\(selectedFolders[0].name)」"
            }
            return "扫描已选的 \(selectedFolders.count) 个文件夹"
        }
        return cid == "0" ? "扫描整个网盘" : "扫描此文件夹"
    }

    private var subtitleText: String {
        allowsMultipleSelection
            ? "可勾选多个文件夹一并扫描，扫到视频后会自动匹配封面。"
            : "只整理需要的文件夹，保留目录中的原文件。"
    }

    private var noticeText: String {
        if allowsMultipleSelection {
            return cid == "0"
                ? "可勾选多个存放影片的文件夹一起扫描，扫描到视频后会自动匹配封面。整个网盘文件较多时耗时较长。"
                : "会扫描所选文件夹及其中的所有子文件夹，并在扫描到视频后自动匹配封面。"
        }
        return cid == "0"
            ? "整个网盘文件较多时耗时较长，建议只选择存放影片的文件夹。"
            : "会扫描「\(name)」及其中的所有子文件夹。"
    }

    var body: some View {
        DesignPage(eyebrow: "Choose a folder", title: "选择扫描目录", subtitle: subtitleText) {
            currentFolderCard
            GroupLabel(title: "子文件夹")
            DesignGroup {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                } else if !error.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                    }.padding(20)
                } else if folders.isEmpty {
                    Text("没有子文件夹").font(.subheadline).foregroundStyle(.secondary).padding(24)
                }
                ForEach(folders) { folder in
                    folderRow(folder)
                    if folder.id != folders.last?.id {
                        Divider().padding(.leading, allowsMultipleSelection ? 56 : LibraryActionRow.dividerInset)
                    }
                }
            }
            DesignNotice(text: noticeText)
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .designScreen("folder-picker")
        .task(id: appState.sessionID) {
            if !InterfacePreview.active { folders = []; await load() }
        }
    }

    private var currentFolderCard: some View {
        HStack(spacing: 10) {
            Image(appIconNamed: cid == "0" ? AppIcon.cloud.name : AppIcon.folder.name)
                .font(.scaled(15, weight: Theme.iconWeight))
                .foregroundStyle(Theme.accent)
            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: Theme.Space.sm)
            if allowsMultipleSelection && cid != "0" {
                Button {
                    toggleSelection(currentTarget)
                } label: {
                    HStack(spacing: 4) {
                        Image(appIconNamed: currentSelected ? AppIcon.check.name : AppIcon.add.name)
                            .font(.scaled(11, weight: .bold))
                        Text(currentSelected ? "已选" : "选择此文件夹")
                            .font(Theme.Typo.caption.weight(.semibold))
                    }
                    .foregroundStyle(currentSelected ? Theme.onPrimary : Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(currentSelected ? Theme.gold : Theme.tileTint, in: Capsule())
                    .contentShape(VerticalHitArea(extra: 8))
                }
                .buttonStyle(.pressable(scale: 0.94))
                .accessibilityIdentifier("scan.folder.toggleCurrent")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    @ViewBuilder
    private func folderRow(_ folder: P115File) -> some View {
        if allowsMultipleSelection {
            let selected = isSelected(folder.id)
            HStack(spacing: 0) {
                Button {
                    toggleSelection(ScanFolderTarget(id: folder.id, name: folder.name))
                } label: {
                    CheckBadge(selected: selected, size: 22)
                        .frame(width: 44, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected ? "取消选择 \(folder.name)" : "选择 \(folder.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("scan.folder.toggle.\(folder.id)")

                Button {
                    onOpen(Crumb(cid: folder.id, name: folder.name))
                } label: {
                    HStack(spacing: 12) {
                        IconTile(icon: .folder, size: 34, tone: selected ? .accent : .neutral)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                                .font(Theme.Typo.row.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(selected ? "已加入扫描列表 · 点按进入子文件夹" : "进入子文件夹")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.sm)
                        Image(icon: .forward)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.trailing, Theme.Space.lg)
                    .padding(.vertical, 10)
                    .frame(minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityLabel("进入 \(folder.name)")
                .accessibilityIdentifier("scan.folder.open.\(folder.id)")
            }
            .padding(.leading, 6)
        } else {
            Button { onOpen(Crumb(cid: folder.id, name: folder.name)) } label: {
                LibraryActionRow(symbol: AppIcon.folder.name, title: folder.name, subtitle: "进入文件夹")
            }
            .buttonStyle(.pressable(scale: 0.985))
        }
    }

    private var bottomBar: some View {
        VStack(spacing: Theme.Space.sm + 2) {
            if allowsMultipleSelection && !selectedFolders.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    HStack {
                        Text("已选 \(selectedFolders.count) 个文件夹")
                            .font(Theme.Typo.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("清空") {
                            Haptics.tap()
                            selectedFolders.removeAll()
                        }
                        .font(Theme.Typo.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("scan.folder.clearSelection")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.xs + 2) {
                            ForEach(selectedFolders) { item in
                                Button {
                                    toggleSelection(item)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(appIconNamed: AppIcon.folder.name)
                                            .font(.scaled(11, weight: Theme.iconWeight))
                                            .foregroundStyle(Theme.accent)
                                        Text(item.name)
                                            .font(Theme.Typo.caption.weight(.medium))
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1)
                                        Image(appIconNamed: AppIcon.close.name)
                                            .font(.scaled(9, weight: .bold))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(Theme.surfaceRaised, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除 \(item.name)")
                            }
                        }
                    }
                }
            }

            Button {
                let targets = (allowsMultipleSelection && !selectedFolders.isEmpty)
                    ? selectedFolders
                    : [currentTarget]
                onConfirm(targets)
            } label: {
                Label(primaryButtonTitle, image: AppIcon.scan.name)
            }
            .buttonStyle(PrimaryActionStyle())
            .accessibilityIdentifier("scan.pickFolder")
            .disabled(!appState.isAuthenticated)
        }
        .padding(Theme.contentInset)
        .background(Theme.pageBackground)
        .overlay(alignment: .top) {
            if allowsMultipleSelection && !selectedFolders.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: Theme.Stroke.hairline)
            }
        }
    }

    private func load() async {
        let request = UUID(), session = appState.sessionID
        requestID = request
        loading = true
        error = ""
        defer { if requestID == request && session == appState.sessionID { loading = false } }
        guard let client = appState.directClient() else { loading = false; error = "请先登录 115"; return }
        var offset = 0
        var result: [P115File] = []
        do {
            for _ in 0..<20 {
                let page = try await client.filesPage(cid: cid, offset: offset)
                guard !Task.isCancelled, requestID == request, session == appState.sessionID else { return }
                result += page.files.filter { $0.isDir && !$0.id.isEmpty }
                guard let next = page.nextOffset, next > offset else { break }
                offset = next
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            folders = result
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, requestID == request, session == appState.sessionID else { return }
            self.error = "读取文件夹失败：\(error.userMessage)"
        }
    }
}
