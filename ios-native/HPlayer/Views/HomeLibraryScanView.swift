import SwiftUI

/// 文件扫描和封面匹配各自展示状态；文件扫描完成不代表所有影片都能识别。
struct HomeLibraryScanView: View {
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var local: LocalMediaStore
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var recents = RecentStore.shared
    @ObservedObject private var magnetHistory = MagnetHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
    @AppStorage(CoverMatchingSettings.automaticKey) private var automaticMatching = false

    let onStart: (Bool) -> Void
    let onStartFolder: (String, String) -> Void
    @State private var pickingFolder = false
    @State private var copiedDiagnostics = false
    private var hasDMMKey: Bool { DMMClient.storedCredentials() != nil }
    let onRetryMatching: () -> Void

    @State private var totalVideos = 0
    @State private var confirmClearHistory = false
    @State private var matchedVideos = 0
    @State private var performerStats = (have: 0, total: 0)

    private func refreshMatched() {
        // 只在匹配结果变化时数一次，不在每次扫描进度刷新时重算。
        let files = HomeLibrary.media(local: local, cloud: library, appState: appState)
        totalVideos = files.count
        matchedVideos = files.filter { metadata.metadataByMediaID[$0.id]?.hasUsablePoster == true }.count
        let coverage = metadata.performerCoverage()
        performerStats = (coverage.withPerformers, coverage.total)
    }

    private var performerSummary: String {
        performerStats.total == 0 ? "还没有匹配到番号影片" : "\(performerStats.have) / \(performerStats.total) 部"
    }

    private var performerEnrichmentActive: Bool {
        metadata.performerEnrichmentState == .waiting || metadata.performerEnrichmentState == .running
    }

    @ViewBuilder
    private var performerEnrichmentStatus: some View {
        switch metadata.performerEnrichmentState {
        case .waiting:
            Label("封面匹配完成后将自动开始补全演员", systemImage: AppIcon.clock.name)
                .font(.subheadline).foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView()
                    Text("正在补全演员资料")
                }
                .font(.subheadline)
                Text("已处理 \(metadata.performerEnrichmentProcessed) / \(metadata.performerEnrichmentTotal) 个番号")
                    .font(.subheadline).foregroundStyle(.secondary)
                if metadata.performerEnrichmentTotal > 0 {
                    ProgressView(value: Double(metadata.performerEnrichmentProcessed),
                                 total: Double(metadata.performerEnrichmentTotal))
                }
            }
            .accessibilityElement(children: .combine)
        case .failed:
            Label("部分资料暂时无法获取，请检查网络后重试。", systemImage: AppIcon.alert.name)
                .font(.subheadline).foregroundStyle(Theme.warning)
        case .completed:
            Text(metadata.performerEnrichmentFailures > 0 ? "补全结束，部分资料暂时无法获取，可稍后重试。" : "本轮补全已结束，未收录的演员信息可能仍为空。")
                .font(.subheadline).foregroundStyle(.secondary)
        case .stopped:
            Text("已停止，可随时重新补全。")
                .font(.subheadline).foregroundStyle(.secondary)
        case .idle:
            if performerStats.total == 0 {
                Text("尚无已识别的番号影片，扫描并匹配后可补全演员资料。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("可补查已识别影片中缺失的演员信息。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// 排查「为什么没匹配上、为什么慢」：开关和 Key 的状态加上最近的查找记录，不含 Cookie 和 Key 本身。
    private func copyDiagnostics() {
        let media = library.media(for: appState)
        var lines = [
            "HPlayer 匹配诊断",
            "番号匹配：\(adultMatching ? "开" : "关")；DMM 接口 Key：\(hasDMMKey ? "已填" : "未填")；TMDB Key：\(TMDBClient.storedKey.isEmpty ? "未填" : "已填")",
            "片库 \(media.count) 部，已有封面 \(matchedVideos) 部，自动匹配：\(metadata.isMatching ? "进行中" : "空闲")，扫描：\(status)",
            "番号影片 \(performerStats.total) 部，已有演员信息 \(performerStats.have) 部，演员补全：\(metadata.performerEnrichmentState)，已处理 \(metadata.performerEnrichmentProcessed) / \(metadata.performerEnrichmentTotal) 个番号，失败 \(metadata.performerEnrichmentFailures) 个",
            "最近记录（新的在后）：",
        ]
        let recent = MatchDiagnostics.shared.snapshot
        lines += recent.isEmpty ? ["（还没有记录。先点「重新匹配未识别封面」再复制）"] : recent
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copiedDiagnostics = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copiedDiagnostics = false
        }
    }

    private var status: String {
        switch scanner.phase {
        case .idle: return "扫描你的 115 片库"
        case .running: return "正在扫描全盘"
        case .paused: return "扫描已暂停"
        case .failed: return "扫描尚未完成"
        case .completed: return "文件扫描完成"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageIntroduction(eyebrow: "Keep your library in shape", title: "媒体库管理", subtitle: "整理你的文件、封面与影片资料。", showsTitle: false)
                    .accessibilityElement(children: .combine)

                    scanCard
                    scanActions
                    if !appState.isAuthenticated {
                        NavigationLink { CookieWebLoginView(onConnected: {}) } label: {
                            Label("连接 115 后可扫描云端目录", systemImage: AppIcon.cloudLocked.name)
                                .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        libraryMetric("片库视频", value: totalVideos)
                        libraryMetric("已匹配", value: matchedVideos)
                        libraryMetric("未匹配", value: max(0, totalVideos - matchedVideos))
                    }
                    NavigationLink { HomeUnmatchedMediaView() } label: {
                        LibraryActionRow(symbol: AppIcon.poster.name, title: "未匹配影片", subtitle: "查看、播放或手动校正", value: "\(max(0, totalVideos - matchedVideos))")
                            .surfaceCard()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("scan.unmatched")
                    automaticMatchingCard
                    if metadata.isMatching { coverCard }
                    sourceCard
                    if adultMatching { performerCard }
                    toolsCard

                    Label("只读取文件列表，不下载整部视频，也不删除网盘文件。扫描在前台进行，退出后可继续。", systemImage: AppIcon.privacy.name)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 14)
                .padding(.bottom, 36)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .task(id: "\(metadata.revision)|\(library.revision)|\(local.files.count)|\(appState.libraryAccountID ?? "local")") { refreshMatched() }
            .navigationTitle("媒体库管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .designScreen("manage")
        .confirmationDialog("清空继续观看记录？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) { recents.clear(); magnetHistory.removeAll() }
        }
        .sheet(isPresented: $pickingFolder) {
            ScanFolderPicker(onSelect: onStartFolder).environmentObject(appState)
        }
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ProgressRing(value: scanRingValue, lineWidth: 5) {
                    Image(systemName: scanner.phase == .completed ? AppIcon.success.name : AppIcon.autoMatch.name)
                        .font(.system(size: 20, weight: Theme.iconWeight))
                        .foregroundStyle(Theme.accent)
                        .morphSymbol()
                }
                .frame(width: 56, height: 56)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(scanner.phase == .running ? "正在扫描" : status)
                VStack(alignment: .leading, spacing: 5) {
                    Text(status).font(.system(size: 17, weight: .bold))
                    Text(scanDescription).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("扫描范围").foregroundStyle(.secondary)
                Spacer()
                Text(scanner.scopeName ?? "整个网盘")
            }.font(.caption)
            if scanner.phase != .idle {
                Divider()
                HStack {
                    scanMetric("已扫描", value: "\(scanner.progress.scannedFolders)", unit: "文件夹")
                    Spacer()
                    scanMetric("已发现", value: "\(scanner.progress.discoveredFolders)", unit: "文件夹")
                    Spacer()
                    scanMetric("发现视频", value: "\(scanner.progress.discoveredVideos)", unit: "本次")
                }
                if scanner.phase == .running, !scanner.currentFolderName.isEmpty {
                    Label(scanner.currentFolderName, systemImage: AppIcon.folder.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !scanner.lastError.isEmpty {
                Label(scanner.lastError, systemImage: AppIcon.alert.name)
                    .font(.subheadline).foregroundStyle(Theme.warning)
                Text("已发现的影片和扫描进度都已保留，可稍后继续。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scanCard()
    }

    /// 圆环进度：已扫描的文件夹占已发现文件夹的比例；扫完是满环，没开始是空环。
    private var scanRingValue: Double {
        switch scanner.phase {
        case .idle: return 0
        case .completed: return 1
        default:
            let found = max(scanner.progress.discoveredFolders, 1)
            return min(Double(scanner.progress.scannedFolders) / Double(found), 1)
        }
    }

    private func libraryMetric(_ title: String, value: Int) -> some View {
        VStack(spacing: 8) {
            Text("\(value)").font(.display(22).monospacedDigit()).rollingNumber()
                .animation(Motion.smooth, value: value)
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 18).surfaceCard()
    }

    private var scanDescription: String {
        switch scanner.phase {
        case .idle: return "手动开始，或选择一个文件夹扫描"
        case .running: return "正在发现文件夹和视频"
        case .paused: return "进度已保存，可以随时继续"
        case .failed: return "进度已保留，请检查原因后继续"
        case .completed: return "文件扫描已结束，封面匹配可能仍在进行"
        }
    }

    private func scanMetric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.display(22)).monospacedDigit().rollingNumber()
                .animation(Motion.smooth, value: value)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)\(value)\(unit)")
    }

    @ViewBuilder
    private var scanActions: some View {
        VStack(spacing: 10) {
            if scanner.phase == .running {
                Button {
                    scanner.pause()
                    metadata.stopByUser()
                    library.flush()
                } label: {
                    primaryAction("暂停扫描", icon: AppIcon.pause.name)
                }
                .accessibilityIdentifier("scan.pause")
            } else if scanner.canResume {
                Button { onStart(false) } label: {
                    primaryAction("继续全盘扫描", icon: AppIcon.play.name)
                }
                .accessibilityIdentifier("scan.resume")
                Button("从头重新扫描", systemImage: AppIcon.refresh.name) { onStart(true) }
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button { onStart(scanner.phase == .completed) } label: {
                    primaryAction(scanner.phase == .completed ? "重新扫描全盘" : "开始全盘扫描", icon: AppIcon.autoMatch.name)
                }
                .accessibilityIdentifier("scan.start")
            }
            if scanner.phase != .running {
                Button("选择文件夹扫描", systemImage: AppIcon.folderSettings.name) { pickingFolder = true }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("scan.chooseFolder")
            }
        }
        .buttonStyle(.plain)
        .disabled(!appState.isAuthenticated)
    }

    private func primaryAction(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.primaryAction, in: Capsule())
    }

    private var automaticMatchingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("自动匹配封面", isOn: $automaticMatching)
                .font(.headline)
                .accessibilityIdentifier("scan.automaticMatching")
            Text("关闭时不会自动匹配；可随时手动重新匹配未识别封面。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .scanCard()
    }

    private var coverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("封面与影片资料", systemImage: AppIcon.posterBatch.name)
                    .font(.headline)
                Spacer(minLength: 8)
                if metadata.isMatching { ProgressView().accessibilityLabel("正在匹配封面") }
            }
            Text(metadata.isMatching ? "正在自动匹配封面" : "封面匹配当前空闲")
                .font(.subheadline).foregroundStyle(.secondary)
            LabeledContent("片库已匹配视频", value: "\(matchedVideos) 部")
                .font(.subheadline)
            Text("文件扫描与封面匹配分别进行。未匹配的文件仍可在资源库播放。")
                .font(.footnote).foregroundStyle(.secondary)
            if metadata.isMatching {
                Button("停止匹配封面", systemImage: AppIcon.stop.name, role: .destructive) {
                    metadata.stopByUser()
                    library.flush()
                }
                .accessibilityIdentifier("scan.stopMatching")
            }
        }
        .scanCard()
    }

    private var sourceCard: some View {
        NavigationLink { MetadataSourcesView() } label: {
            LibraryActionRow(symbol: AppIcon.tune.name, title: "资料来源", subtitle: "番组计划、IMDb、TMDB 与番号资料")
                .surfaceCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scan.sources")
    }

    private var performerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("演员资料", systemImage: AppIcon.people.name)
                .font(.headline)
            LabeledContent("已识别影片的演员信息", value: performerSummary)
                .font(.subheadline)
            performerEnrichmentStatus
            Button(performerEnrichmentActive ? "停止补全演员" : "补全演员资料",
                   systemImage: performerEnrichmentActive ? AppIcon.stop.name : AppIcon.peopleAdd.name) {
                if performerEnrichmentActive {
                    metadata.stopPerformerEnrichment()
                } else {
                    metadata.startPerformerEnrichment(force: true)
                }
            }
            .disabled(!performerEnrichmentActive && !metadata.isMatching && performerStats.have >= performerStats.total)
            .accessibilityIdentifier("scan.enrichPerformers")
            Text("先扫描并识别番号影片，再补查缺失的演员信息。来源不一定收录所有演员；同一演员有两部以上影片时，首页会显示演员合集。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .scanCard()
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("匹配与管理", systemImage: AppIcon.tune.name)
                .font(.headline).padding(.bottom, 8)
            Button(action: onRetryMatching) {
                toolRow("重新匹配未识别封面", icon: AppIcon.posterSearch.name)
            }
            .disabled(library.files(for: appState).isEmpty && local.files.isEmpty)
            Divider()
            Button {
                local.refresh()
                let files = HomeLibrary.media(local: local, cloud: library, appState: appState)
                if automaticMatching {
                    metadata.resumeAutomatic()
                    metadata.sync(files: files)
                } else {
                    metadata.hydrate(files: files)
                }
            } label: { toolRow("刷新媒体库", icon: AppIcon.refresh.name) }
            Divider()
            Button(role: .destructive) { confirmClearHistory = true } label: { toolRow("清空继续观看", icon: AppIcon.history.name) }
            Divider()
            Button { copyDiagnostics() } label: {
                toolRow(copiedDiagnostics ? "已复制" : "复制匹配诊断信息", icon: AppIcon.copy.name)
            }
            .accessibilityIdentifier("scan.copyDiagnostics")
        }
        .buttonStyle(.plain)
        .scanCard()
    }

    private func toolRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: AppIcon.forward.name).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

}

private extension View {
    func scanCard() -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }
    }
}

/// 未识别文件不占用首页，但仍可以从扫描页播放或手动校正封面。
struct HomeUnmatchedMediaView: View {
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var local: LocalMediaStore
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var appState: AppState
    @State private var matching: MatchRequest?
    @State private var playing: PlaybackQueue?

    private var items: [HomeMediaItem] {
        HomeLibrary.items(HomeLibrary.media(local: local, cloud: library, appState: appState), metadata: metadata.metadataByMediaID)
            .filter { $0.metadata?.hasUsablePoster != true }
    }

    var body: some View {
        DesignPage(eyebrow: "A little attention", title: "未匹配影片", subtitle: "\(items.count) 个视频可以手动补充资料，也可以直接播放。") {
            if items.isEmpty {
                EmptyStateView(icon: AppIcon.success.name, title: "片库已经整理好了", message: "当前没有待匹配影片。")
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: AppIcon.video.name).font(.title).foregroundStyle(Theme.accent)
                            .frame(width: 52, height: 68).background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.media.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            Text([item.sourceLabel, formatSize(item.media.size)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { matching = MatchRequest(item: item) } label: { Label("匹配封面", systemImage: AppIcon.poster.name) }
                            .buttonStyle(PrimaryActionStyle())
                        Button { playing = PlaybackQueue(source: item.media.source, items: [item.media.source]) } label: { Label("直接播放", systemImage: AppIcon.play.name) }
                            .buttonStyle(SecondaryActionStyle())
                    }
                }.padding(16).surfaceCard()
            }
        }
        .navigationTitle("未匹配影片")
        .designScreen("unmatched")
        .sheet(item: $matching) { request in
            MetadataMatchView(file: request.file, current: request.current, onMatch: { result in
                await metadata.match(result, to: request.file)
            }, onClear: nil)
        }
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
    }
}
