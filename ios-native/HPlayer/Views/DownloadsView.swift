import SwiftUI

/// 下载管理：下载到手机的文件。下载中的可以暂停、继续、重试，下载好的可以播放或导出，左滑删除。
struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager: DownloadManager

    @State private var tab: String
    @State private var storage: DownloadStorageSummary
    @State private var playing: PlaybackQueue?
    @State private var removal: DownloadItem?
    @State private var message: String?
    /// 界面预览时固定的存储数字，正常使用时为 nil，由页面自己读取
    private let fixedStorage: DownloadStorageSummary?

    private static let recentWindow: TimeInterval = 600

    init(manager: DownloadManager? = nil, initialTab: String = "active", fixedStorage: DownloadStorageSummary? = nil) {
        _manager = ObservedObject(wrappedValue: manager ?? DownloadManager.shared)
        _tab = State(initialValue: initialTab)
        _storage = State(initialValue: fixedStorage ?? DownloadStorageSummary(libraryBytes: 0, freeBytes: nil, totalBytes: nil))
        self.fixedStorage = fixedStorage
    }

    var body: some View {
        List {
            header
            if tab == "done" {
                completedSections
            } else {
                activeSections
            }
            tip
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
        .designScreen("downloads")
        .toast($message)
        .task {
            if fixedStorage != nil || InterfacePreview.active { return }
            while !Task.isCancelled {
                storage = manager.storageSummary()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
        .confirmationDialog("删除这个下载？", isPresented: removalBinding, titleVisibility: .visible,
                            presenting: removal) { item in
            Button("删除文件", role: .destructive) { manager.delete(item.id) }
            Button("取消", role: .cancel) { }
        } message: { item in
            Text("「" + item.name + "」会从手机上删除，释放存储空间，不影响网盘里的文件。")
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    // MARK: 页首

    private var segments: [CountSegment] {
        [
            CountSegment(id: "active", title: "下载中", count: manager.unfinished.count),
            CountSegment(id: "done", title: "已完成", count: manager.completed.count),
        ]
    }

    private var header: some View {
        VStack(spacing: 12) {
            CountSegmentedControl(segments: segments, selection: $tab, identifierPrefix: "library.downloads.segment")
            storageCard
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private var storageCard: some View {
        let used = DownloadFormat.bytes(storage.libraryBytes)
        let free = storage.freeBytes.map { DownloadFormat.bytes($0) } ?? "未知"
        let total = storage.totalBytes ?? 0
        let fraction = total > 0 ? Double(storage.libraryBytes) / Double(total) : 0
        return VStack(spacing: 8) {
            HStack {
                HStack(spacing: 0) {
                    Text("已下载视频占用 ")
                    Text(used).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    Text("手机剩余 ")
                    Text(free).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                }
            }
            .font(.scaled(12))
            .foregroundStyle(Theme.textSecondary)
            ThinProgressBar(fraction: storage.libraryBytes > 0 ? max(fraction, 0.02) : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.downloads.storage")
    }

    private var hasResumable: Bool {
        manager.items.contains { $0.state == .paused || $0.state == .failed }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                manager.pauseAll()
            } label: {
                Label("全部暂停", systemImage: AppIcon.pause.name)
            }
            .disabled(manager.activeCount == 0)
            Button {
                manager.resumeAll()
            } label: {
                Label("全部继续", systemImage: AppIcon.play.name)
            }
            .disabled(!hasResumable)
            Button {
                manager.clearCompletedRecords()
                message = "已清除下载记录，文件仍保留在手机上"
            } label: {
                Label("清除已完成记录", systemImage: AppIcon.trash.name)
            }
            .disabled(manager.completed.isEmpty)
        } label: {
            Image(systemName: AppIcon.more.name)
        }
        .accessibilityLabel("更多")
        .accessibilityIdentifier("library.downloads.menu")
    }

    // MARK: 分组

    private var recentCompleted: [DownloadItem] {
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        return Array(manager.completed.filter { ($0.finishedAt ?? Date.distantPast) > cutoff }.prefix(3))
    }

    @ViewBuilder
    private var activeSections: some View {
        let running = manager.unfinished
        let recent = recentCompleted
        if running.isEmpty && recent.isEmpty {
            EmptyStateView(
                icon: AppIcon.download.name,
                title: "没有正在下载的文件",
                message: "在网盘里选择文件，点「下载」就会出现在这里。"
            )
            .frame(height: 360)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        if !running.isEmpty {
            sectionLabel("下载中")
            ForEach(running) { item in
                activeCard(item)
            }
        }
        if !recent.isEmpty {
            sectionLabel("刚刚完成")
            ForEach(recent) { item in
                completedCard(item)
            }
        }
    }

    @ViewBuilder
    private var completedSections: some View {
        let finished = manager.completed
        if finished.isEmpty {
            EmptyStateView(
                icon: AppIcon.cloudReady.name,
                title: "还没有下载完成的文件",
                message: "下载好的视频会保存在「本地视频」里，可以离线观看。"
            )
            .frame(height: 360)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            sectionLabel("已完成")
            ForEach(finished) { item in
                completedCard(item)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.scaled(12))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
    }

    private var tip: some View {
        Text("下载的视频保存在 HPlayer 的「本地视频」中，可离线观看；在列表左滑可删除，删除后释放手机空间，不影响网盘里的文件。下载只在 HPlayer 打开时进行，离开后会自动暂停，回来后继续，已经下载的部分不会重来。")
            .font(.scaled(12))
            .lineSpacing(3)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 24, trailing: 16))
    }

    // MARK: 下载中的卡片

    private func activeCard(_ item: DownloadItem) -> some View {
        let waiting = item.state == .paused || item.state == .failed
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                fileTile(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.scaled(14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(DownloadsText.subtitle(item))
                        .font(.scaled(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                controlButton(item)
            }
            ThinProgressBar(fraction: item.fraction, paused: waiting)
                .padding(.top, 8)
                .padding(.bottom, 8)
            metaRow(item)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if waiting { manager.resume(item.id) }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                manager.delete(item.id)
            } label: {
                Label("删除", systemImage: AppIcon.trash.name)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.downloads.item.\(item.id.uuidString)")
    }

    private func metaRow(_ item: DownloadItem) -> some View {
        let tint: Color = item.state == .downloading ? Theme.accent : Theme.textSecondary
        let rightColor: Color = item.state == .failed ? Theme.danger : Theme.textSecondary
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text(DownloadsText.percent(item))
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                Text(DownloadsText.amount(item))
            }
            Spacer(minLength: 8)
            Text(DownloadsText.status(item, speed: manager.speeds[item.id], remaining: manager.remainingSeconds(for: item)))
                .foregroundStyle(rightColor)
                .multilineTextAlignment(.trailing)
        }
        .font(.scaled(12))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func controlButton(_ item: DownloadItem) -> some View {
        switch item.state {
        case .downloading, .queued:
            circleButton(AppIcon.pause, label: "暂停", tinted: true) { manager.pause(item.id) }
        case .paused:
            circleButton(AppIcon.play, label: "继续", tinted: false) { manager.resume(item.id) }
        case .failed:
            circleButton(AppIcon.refresh, label: "重试", tinted: false) { manager.resume(item.id) }
        case .completed:
            EmptyView()
        }
    }

    private func circleButton(_ glyph: AppIcon, label: String, tinted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph.name)
                .font(.scaled(14, weight: .semibold))
                .foregroundStyle(tinted ? Theme.accent : Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(tinted ? Theme.tileTint : Theme.surfaceHigh, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(label)
    }

    private func fileTile(_ item: DownloadItem) -> some View {
        Image(systemName: item.isVideo ? AppIcon.video.name : AppIcon.file.name)
            .font(.scaled(18, weight: Theme.iconWeight))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 72, height: 44)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
    }

    // MARK: 已完成的卡片

    private func completedCard(_ item: DownloadItem) -> some View {
        let url = manager.fileURL(for: item)
        return HStack(spacing: 12) {
            fileTile(item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.scaled(14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                doneLine(item, exists: url != nil)
            }
            Spacer(minLength: 0)
            trailingAction(item, url: url)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                removal = item
            } label: {
                Label("删除", systemImage: AppIcon.trash.name)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.downloads.item.\(item.id.uuidString)")
    }

    @ViewBuilder
    private func doneLine(_ item: DownloadItem, exists: Bool) -> some View {
        if exists {
            HStack(spacing: 6) {
                Image(systemName: AppIcon.success.name)
                    .font(.scaled(12, weight: .semibold))
                Text(DownloadsText.savedLine(item))
                    .lineLimit(1)
            }
            .font(.scaled(12))
            .foregroundStyle(Theme.success)
        } else {
            Text("文件已经不在手机上")
                .font(.scaled(12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    @ViewBuilder
    private func trailingAction(_ item: DownloadItem, url: URL?) -> some View {
        if let url {
            if item.isVideo {
                Button {
                    play(item, url: url)
                } label: {
                    pillLabel("播放", glyph: AppIcon.play)
                }
                .buttonStyle(.pressable(scale: 0.92))
                .accessibilityIdentifier("library.downloads.play.\(item.id.uuidString)")
            } else {
                ShareLink(item: url) {
                    pillLabel("导出", glyph: AppIcon.share)
                }
                .accessibilityIdentifier("library.downloads.share.\(item.id.uuidString)")
            }
        }
    }

    private func pillLabel(_ title: String, glyph: AppIcon) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph.name)
                .font(.scaled(12, weight: .bold))
            Text(title)
                .font(.scaled(13, weight: .semibold))
        }
        .foregroundStyle(Theme.onPrimary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Theme.primaryAction, in: Capsule())
    }

    private func play(_ item: DownloadItem, url: URL) {
        let others = manager.completed.compactMap { entry -> PlaybackSource? in
            guard entry.isVideo, let fileURL = manager.fileURL(for: entry) else { return nil }
            return PlaybackSource.direct(title: entry.savedName ?? entry.name, url: fileURL)
        }
        playing = PlaybackQueue(source: .direct(title: item.savedName ?? item.name, url: url), items: others)
    }
}

/// 下载卡片上的文字
enum DownloadsText {
    /// 「4.37 GB · 网盘 / 电影 · 已暂停」
    static func subtitle(_ item: DownloadItem) -> String {
        var parts: [String] = []
        if item.totalBytes > 0 { parts.append(DownloadFormat.bytes(item.totalBytes)) }
        if !item.folderLabel.isEmpty { parts.append(item.folderLabel) }
        switch item.state {
        case .queued: parts.append("排队中")
        case .paused: parts.append("已暂停")
        case .failed: parts.append("下载失败")
        case .downloading, .completed: break
        }
        return parts.joined(separator: " · ")
    }

    /// 「41%」
    static func percent(_ item: DownloadItem) -> String {
        "\(Int((item.fraction * 100).rounded()))%"
    }

    /// 「 · 1.79 GB / 4.37 GB」；不知道总大小时只写已经下载的部分
    static func amount(_ item: DownloadItem) -> String {
        if item.totalBytes > 0 {
            return " · " + DownloadFormat.bytes(item.receivedBytes) + " / " + DownloadFormat.bytes(item.totalBytes)
        }
        return item.receivedBytes > 0 ? " · " + DownloadFormat.bytes(item.receivedBytes) : ""
    }

    /// 右侧状态：速度和剩余时间、排队、暂停提示或失败原因
    static func status(_ item: DownloadItem, speed: Double?, remaining: Int?) -> String {
        switch item.state {
        case .downloading:
            if !item.message.isEmpty { return item.message }
            let speedText = DownloadFormat.speed(speed ?? 0)
            guard !speedText.isEmpty else { return "正在连接…" }
            if let remaining { return speedText + " · " + DownloadFormat.remaining(remaining) }
            return speedText
        case .queued:
            return "排队中"
        case .paused:
            return "点按继续，支持断点续传"
        case .failed:
            return item.message.isEmpty ? "下载失败，点按重试" : item.message
        case .completed:
            return ""
        }
    }

    /// 「已保存到「本地视频」· 7.05 GB」
    static func savedLine(_ item: DownloadItem) -> String {
        let place = item.savedInLibrary ? "已保存到「本地视频」" : "已保存到 App 的「下载」文件夹"
        let size = item.totalBytes > 0 ? " · " + DownloadFormat.bytes(item.totalBytes) : ""
        return place + size
    }
}
