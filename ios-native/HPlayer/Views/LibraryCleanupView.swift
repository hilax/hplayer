import SwiftUI

/// 清理已失效文件：网盘里已经删掉、片库里还记着的视频。
/// 可以核对整个网盘，也可以只核对某个文件夹；先出清单，确认了才从片库移除（不会动网盘里的文件）。
struct LibraryCleanupView: View {
    @StateObject private var cleanup: LibraryCleanup
    @Environment(\.dismiss) private var dismiss
    private let appState: AppState
    @State private var pickingFolder = false
    @State private var selected = Set<String>()
    @State private var confirming = false

    init(appState: AppState, library: MediaLibraryStore) {
        self.appState = appState
        _cleanup = StateObject(wrappedValue: LibraryCleanup(appState: appState, library: library))
    }

    var body: some View {
        NavigationStack {
            DesignPage(eyebrow: "Tidy up", title: "清理已失效文件") {
                content
            }
            .navigationTitle("清理已失效文件")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $pickingFolder) {
            ScanFolderPicker(onSelect: { id, name in cleanup.start(scope: (id: id, name: name)) })
                .environmentObject(appState)
        }
        .onChange(of: cleanup.phase) { phase in
            if phase == .review { selected = Set(cleanup.groups.map(\.folderID)) }
        }
        .onDisappear { cleanup.cancel() }
        .designScreen("cleanup")
    }

    @ViewBuilder private var content: some View {
        switch cleanup.phase {
        case .choosing: chooser
        case .scanning: CleanupProgress(scanner: cleanup.scanner, scopeName: cleanup.scopeName, onStop: { cleanup.stop() })
        case .review: review
        case .nothing:
            message(symbol: AppIcon.success.name, title: "没有发现失效文件",
                    text: "「\(cleanup.scopeName)」里，片库记着的视频在网盘里都还在。")
        case .suspicious:
            message(symbol: AppIcon.alert.name, title: "已取消清理",
                    text: "这次读整个网盘一个视频都没读到，多半是网络或 115 临时出了问题。为避免把正常的视频误当成失效的，没有做任何改动，请稍后再试。",
                    actionTitle: "返回") { cleanup.stop() }
        case .done:
            message(symbol: AppIcon.success.name, title: "已移除 \(cleanup.removedCount) 个失效视频",
                    text: "它们已经从首页和片库里去掉；网盘里的文件没有被动过。", actionTitle: "完成") { dismiss() }
        case .failed(let reason):
            VStack(spacing: 12) {
                DesignNotice(symbol: AppIcon.alert.name, text: reason, warning: true)
                Button { cleanup.retry() } label: { Label("继续核对", systemImage: AppIcon.refresh.name) }
                    .buttonStyle(PrimaryActionStyle())
                Button { cleanup.stop() } label: { Text("返回") }
                    .buttonStyle(SecondaryActionStyle())
            }
        }
    }

    // MARK: 选择范围

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("在网盘里删掉的视频，首页和片库里还会留着。选一个范围，我去网盘里核对，把已经找不到的列出来给你确认。")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DesignGroup {
                Button { cleanup.start(scope: nil) } label: {
                    LibraryActionRow(symbol: AppIcon.cloud.name, title: "核对整个网盘",
                                     subtitle: "最全面，也最慢：要把整个网盘的文件夹都读一遍")
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("cleanup.all")
                Divider().padding(.leading, 62)
                Button { pickingFolder = true } label: {
                    LibraryActionRow(symbol: AppIcon.folder.name, title: "只核对某个文件夹",
                                     subtitle: "选一个你删过东西的文件夹，只读它和它下面的子文件夹")
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("cleanup.folder")
            }
            DesignNotice(symbol: AppIcon.privacy.name,
                         text: "只更新这台设备上的片库记录，不会动网盘里的任何文件。找到后先给你看清单，确认了才移除。")
            DesignNotice(text: "整个文件夹被你删掉了？选它的上一级文件夹就行。文件夹的位置是扫描时记下的，以前扫描的片库第一次需要先「核对整个网盘」一次，之后就可以只核对某个文件夹。")
        }
    }

    // MARK: 清单

    private var total: Int { cleanup.groups.reduce(0) { $0 + $1.files.count } }
    private var chosenCount: Int { cleanup.groups.filter { selected.contains($0.folderID) }.reduce(0) { $0 + $1.files.count } }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("在「\(cleanup.scopeName)」里，发现 \(total) 个视频已经不在网盘里了。取消勾选的会保留。")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if total >= 20, total * 2 > cleanup.libraryCount {
                DesignNotice(symbol: AppIcon.alert.name,
                             text: "超过一半的视频被判定失效。请确认网盘里真的删除了这些内容，再继续。", warning: true)
            }
            if cleanup.isFolderScope {
                DesignNotice(text: "只核对了这个文件夹：如果某个视频只是被你移到了这个文件夹外面，它也会出现在这里，请取消勾选，或者改用「核对整个网盘」。")
            }
            DesignGroup {
                ForEach(Array(cleanup.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().padding(.leading, 52) }
                    StaleGroupRow(group: group, isSelected: selected.contains(group.folderID)) {
                        if selected.contains(group.folderID) { selected.remove(group.folderID) } else { selected.insert(group.folderID) }
                    }
                }
            }
            Button { confirming = true } label: {
                Label("移除选中的 \(chosenCount) 个视频", systemImage: AppIcon.trash.name)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(chosenCount == 0)
            .accessibilityIdentifier("cleanup.remove")
            .confirmationDialog("从首页和片库移除 \(chosenCount) 个视频？", isPresented: $confirming, titleVisibility: .visible) {
                Button("移除", role: .destructive) { cleanup.remove(folderIDs: selected) }
                    .accessibilityIdentifier("cleanup.confirmRemove")
                Button("取消", role: .cancel) {}
            } message: {
                Text("只移除这台设备上的记录，网盘里的文件不受影响。")
            }
            Button { cleanup.stop() } label: { Text("重新选择范围") }
                .buttonStyle(SecondaryActionStyle())
        }
    }

    private func message(symbol: String, title: String, text: String, actionTitle: String = "完成", action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: Theme.iconWeight))
                .foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 18, weight: .bold))
            Text(text)
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { if let action { action() } else { dismiss() } } label: { Text(actionTitle) }
                .buttonStyle(PrimaryActionStyle())
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .surfaceCard()
    }
}

/// 核对进度：单独一个小视图，只在扫描器变化时刷新。
private struct CleanupProgress: View {
    @ObservedObject var scanner: CloudLibraryScanner
    let scopeName: String
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在核对「\(scopeName)」").font(.system(size: 16, weight: .bold)).lineLimit(1)
            }
            Text(scanner.currentFolderName.isEmpty ? "准备中…" : "正在读取：\(scanner.currentFolderName)")
                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text("已读 \(scanner.progress.scannedFolders) 个文件夹，发现 \(scanner.progress.discoveredVideos) 个视频")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Button(action: onStop) { Text("停止核对") }
                .buttonStyle(SecondaryActionStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .accessibilityIdentifier("cleanup.progress")
    }
}

private struct StaleGroupRow: View {
    let group: StaleFileGroup
    let isSelected: Bool
    let onToggle: () -> Void

    private var detail: String {
        switch group.reason {
        case .fileGone: return "文件夹还在，\(group.files.count) 个视频已不在里面"
        case .folderGone: return "找不到这个文件夹了（已删除或被移走），里面 \(group.files.count) 个视频"
        }
    }

    private var samples: String {
        let names = group.files.prefix(2).map(\.name)
        return names.joined(separator: "、") + (group.files.count > 2 ? " 等" : "")
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? AppIcon.selected.name : AppIcon.unselected.name)
                    .font(.system(size: 20, weight: Theme.iconWeight))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.folderName).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(samples).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
