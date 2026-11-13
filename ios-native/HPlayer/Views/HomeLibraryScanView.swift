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
    @ObservedObject private var featuredStore = FeaturedStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var showCleanup = false
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

    /// 从「我的」或片库频道压进公共导航栈时为 true：用系统返回键，和其他二级页面一样从右侧推入。
    /// 单独作为根页面（界面截图、扫描页测试）时为 false：自带导航栈和返回键。
    var pushed = false

    var body: some View {
        Group {
            if pushed {
                page
                    .toolbar(.visible, for: .navigationBar)
            } else {
                NavigationStack {
                    page
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button { dismiss() } label: {
                                    Image(systemName: AppIcon.back.name)
                                        .font(.scaled(17, weight: .semibold))
                                }
                                .accessibilityLabel("返回")
                                .accessibilityIdentifier("manage.back")
                            }
                        }
                }
            }
        }
        .tint(Theme.textPrimary)
        .designScreen("manage")
        .confirmationDialog("清空继续观看记录？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清空记录", role: .destructive) { recents.clear(); magnetHistory.removeAll() }
        }
        .sheet(isPresented: $pickingFolder) {
            ScanFolderPicker(onSelect: onStartFolder).environmentObject(appState)
        }
        .sheet(isPresented: $showCleanup) {
            LibraryCleanupView(appState: appState, library: library).environmentObject(appState)
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                scanCard
                if !appState.isAuthenticated { loginHint }
                overviewCard
                coverGroup
                if adultMatching { performerCard }
                maintenanceGroup
                DesignNotice(symbol: AppIcon.privacy.name,
                             text: "只读取文件列表，不下载整部视频，也不删除网盘文件。扫描在前台进行，退出后可继续。")
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 14)
            .padding(.bottom, 36)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            // 页面里的开关用琥珀；导航栏（返回键）跟随全局的正文色
            .tint(Theme.accentFill)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .task(id: "\(metadata.revision)|\(library.revision)|\(local.files.count)|\(appState.libraryAccountID ?? "local")") { refreshMatched() }
        .navigationTitle("媒体库管理")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var unmatchedCount: Int { max(0, totalVideos - matchedVideos) }

    // MARK: 扫描

    /// 页面最上面的主卡片：扫描状态、进度和主操作都在这一张里。
    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                ProgressRing(value: scanRingValue, lineWidth: 6) {
                    Image(systemName: scanner.phase == .completed ? AppIcon.success.name : AppIcon.autoMatch.name)
                        .font(.scaled(22, weight: Theme.iconWeight))
                        .foregroundStyle(Theme.accent)
                        .morphSymbol()
                }
                .frame(width: 64, height: 64)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(scanner.phase == .running ? "正在扫描" : status)
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.scaled(18, weight: .bold))
                    Text(scanDescription)
                        .font(.scaled(13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: AppIcon.folder.name).font(.scaled(11, weight: Theme.iconWeight))
                Text("扫描范围").foregroundStyle(Theme.textSecondary)
                Text(scanner.scopeName ?? "整个网盘").fontWeight(.semibold).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.surfaceRaised, in: Capsule())
            if scanner.phase != .idle {
                scanMetrics
                if scanner.phase == .running, !scanner.currentFolderName.isEmpty {
                    Label(scanner.currentFolderName, systemImage: AppIcon.folder.name)
                        .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            if !scanner.lastError.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    DesignNotice(symbol: AppIcon.alert.name, text: scanner.lastError, warning: true)
                    Text("已发现的影片和扫描进度都已保留，可稍后继续。")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            scanActions
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: Theme.Radius.sheet)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center))
                .allowsHitTesting(false)
        }
    }

    private var scanMetrics: some View {
        HStack(spacing: 0) {
            scanMetric("已扫描", value: "\(scanner.progress.scannedFolders)", unit: "文件夹")
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 40)
            scanMetric("已发现", value: "\(scanner.progress.discoveredFolders)", unit: "文件夹")
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 40)
            scanMetric("发现视频", value: "\(scanner.progress.discoveredVideos)", unit: "本次")
        }
        .padding(.vertical, 14)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
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
        VStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(.display(22)).monospacedDigit().rollingNumber()
                .animation(Motion.smooth, value: value)
            Text(unit).font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
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
                    Label("暂停扫描", systemImage: AppIcon.pause.name)
                }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityIdentifier("scan.pause")
            } else {
                if scanner.canResume {
                    Button { onStart(false) } label: {
                        Label("继续全盘扫描", systemImage: AppIcon.play.name)
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("scan.resume")
                } else {
                    Button { onStart(scanner.phase == .completed) } label: {
                        Label(scanner.phase == .completed ? "重新扫描全盘" : "开始全盘扫描", systemImage: AppIcon.autoMatch.name)
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("scan.start")
                }
                HStack(spacing: 10) {
                    if scanner.canResume {
                        Button { onStart(true) } label: {
                            Label("从头重新扫描", systemImage: AppIcon.refresh.name).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .buttonStyle(SecondaryActionStyle())
                    }
                    Button { pickingFolder = true } label: {
                        Label("选择文件夹扫描", systemImage: AppIcon.folderSettings.name).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .accessibilityIdentifier("scan.chooseFolder")
                }
            }
        }
        .disabled(!appState.isAuthenticated)
    }

    private var loginHint: some View {
        NavigationLink { CookieWebLoginView(onConnected: {}) } label: {
            LibraryActionRow(symbol: AppIcon.cloudLocked.name, title: "连接 115 后可扫描云端目录", subtitle: "登录后就能开始扫描你的片库")
                .surfaceCard()
        }
        .buttonStyle(.pressable(scale: 0.985))
    }

    // MARK: 概况

    private var overviewCard: some View {
        let ratio = totalVideos == 0 ? 0 : Double(matchedVideos) / Double(totalVideos)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("片库概况").font(.scaled(15, weight: .semibold))
                Spacer(minLength: 8)
                if totalVideos > 0 {
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(.display(22).monospacedDigit()).foregroundStyle(Theme.accent).rollingNumber()
                        .animation(Motion.smooth, value: matchedVideos)
                    Text("已有封面").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: ratio > 0 ? max(proxy.size.width * ratio, 8) : 0)
                        .animation(reduceMotion ? nil : Motion.smooth, value: ratio)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 12) {
                overviewStat("片库视频", value: totalVideos, dot: Theme.textPrimary)
                overviewStat("已匹配", value: matchedVideos, dot: Theme.accent)
                overviewStat("未匹配", value: unmatchedCount, dot: Theme.textTertiary)
            }
        }
        .padding(18)
        .surfaceCard()
    }

    private func overviewStat(_ title: String, value: Int, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Text("\(value)").font(.display(24).monospacedDigit()).rollingNumber()
                .animation(Motion.smooth, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)\(value)")
    }

    // MARK: 封面与资料

    private var rowDivider: some View { Divider().padding(.leading, LibraryActionRow.dividerInset) }

    private var coverGroup: some View {
        DesignGroup {
            Toggle(isOn: $automaticMatching) {
                HStack(spacing: 12) {
                    RowIcon(icon: .autoMatch)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动匹配封面").font(.scaled(14, weight: .medium))
                        Text("关闭后只在手动重新匹配时查找").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 58)
            .accessibilityIdentifier("scan.automaticMatching")
            rowDivider
            if metadata.isMatching {
                matchingRow
                rowDivider
            }
            NavigationLink { HomeUnmatchedMediaView() } label: {
                LibraryActionRow(symbol: AppIcon.poster.name, title: "未匹配影片", subtitle: "查看、播放或手动校正", value: "\(unmatchedCount)")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("scan.unmatched")
            rowDivider
            NavigationLink { MetadataSourcesView() } label: {
                LibraryActionRow(symbol: AppIcon.tune.name, title: "资料来源", subtitle: "番组计划、IMDb、TMDB 与番号资料")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("scan.sources")
            rowDivider
            let nothingToMatch = library.files(for: appState).isEmpty && local.files.isEmpty
            Button(action: onRetryMatching) {
                LibraryActionRow(symbol: AppIcon.posterSearch.name, title: "重新匹配未识别封面", subtitle: "对还没有封面的影片再查一次", showsChevron: false)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .disabled(nothingToMatch)
            .opacity(nothingToMatch ? 0.4 : 1)
        }
    }

    private var matchingRow: some View {
        HStack(spacing: 12) {
            ProgressView().frame(width: 34, height: 34).accessibilityLabel("正在匹配封面")
            VStack(alignment: .leading, spacing: 3) {
                Text("正在自动匹配封面").font(.scaled(14, weight: .medium))
                Text("已有封面 \(matchedVideos) 部；未匹配的文件仍可播放").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button {
                metadata.stopByUser()
                library.flush()
            } label: {
                Label("停止", systemImage: AppIcon.stop.name)
                    .font(.scaled(13, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(.pressable(scale: 0.94))
            .accessibilityIdentifier("scan.stopMatching")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 58)
    }

    private var performerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RowIcon(icon: .people)
                VStack(alignment: .leading, spacing: 3) {
                    Text("演员资料").font(.scaled(14, weight: .medium))
                    Text(performerSummary).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            performerEnrichmentStatus
            Button {
                if performerEnrichmentActive {
                    metadata.stopPerformerEnrichment()
                } else {
                    metadata.startPerformerEnrichment(force: true)
                }
            } label: {
                Label(performerEnrichmentActive ? "停止补全演员" : "补全演员资料",
                      systemImage: performerEnrichmentActive ? AppIcon.stop.name : AppIcon.peopleAdd.name)
            }
            .buttonStyle(SecondaryActionStyle())
            .disabled(!performerEnrichmentActive && !metadata.isMatching && performerStats.have >= performerStats.total)
            .accessibilityIdentifier("scan.enrichPerformers")
            DesignNotice(text: "先扫描并识别番号影片，再补查缺失的演员信息。来源不一定收录所有演员；同一演员有两部以上影片时，首页会显示演员合集。")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    // MARK: 维护

    private var maintenanceGroup: some View {
        DesignGroup {
            Button {
                local.refresh()
                let files = HomeLibrary.media(local: local, cloud: library, appState: appState)
                if automaticMatching {
                    metadata.resumeAutomatic()
                    metadata.sync(files: files)
                } else {
                    metadata.hydrate(files: files)
                }
            } label: {
                LibraryActionRow(symbol: AppIcon.refresh.name, title: "刷新媒体库", subtitle: "重新读取本机和云端的影片列表", showsChevron: false)
            }
            .buttonStyle(.pressable(scale: 0.985))
            rowDivider
            Button { showCleanup = true } label: {
                LibraryActionRow(symbol: AppIcon.checklist.name, title: "清理已失效文件",
                                 subtitle: "网盘里已经删掉的视频，从首页和片库里一并去掉", showsChevron: false)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .disabled(!appState.isAuthenticated)
            .accessibilityIdentifier("scan.cleanup")
            if !featuredStore.hidden.isEmpty {
                rowDivider
                Button { featuredStore.restoreAll() } label: {
                    LibraryActionRow(symbol: AppIcon.hidden.name, title: "恢复精选中隐藏的影片",
                                     subtitle: "已隐藏 \(featuredStore.hidden.count) 部，恢复后可能再次出现在首页大图", showsChevron: false)
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("manage.restoreFeatured")
            }
            rowDivider
            Button { copyDiagnostics() } label: {
                LibraryActionRow(symbol: copiedDiagnostics ? AppIcon.success.name : AppIcon.copy.name,
                                 title: copiedDiagnostics ? "已复制" : "复制匹配诊断信息",
                                 subtitle: "匹配不上时，把它发给开发者", showsChevron: false)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("scan.copyDiagnostics")
            rowDivider
            Button(role: .destructive) { confirmClearHistory = true } label: {
                LibraryActionRow(symbol: AppIcon.history.name, title: "清空继续观看", subtitle: "只清除观看进度，不影响影片", showsChevron: false, tone: .danger)
            }
            .buttonStyle(.pressable(scale: 0.985))
        }
    }
}

/// 未识别文件不占用首页，但仍可以从扫描页播放或手动校正封面。
///
/// 列表直接读首页后台算好的分组结果（LibrarySnapshotStore.unmatched），不在界面里重新解析整个片库的文件名；
/// 用懒加载列表，只画屏幕上看得到的行。以前每次刷新要把全部文件名解析好几遍、再一次性画出全部行，
/// 片库大时点进来会卡很久，匹配期间还会一直卡。
struct HomeUnmatchedMediaView: View {
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var librarySnapshots: LibrarySnapshotStore
    @State private var matching: MatchRequest?
    @State private var playing: PlaybackQueue?

    var body: some View {
        let items = librarySnapshots.home.unmatched
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageIntroduction(eyebrow: "A little attention", title: "未匹配影片",
                                 subtitle: "\(items.count) 个视频可以手动补充资料，也可以直接播放。", showsTitle: false)
                if items.isEmpty {
                    EmptyStateView(icon: AppIcon.success.name, title: "片库已经整理好了", message: "当前没有待匹配影片。")
                }
                ForEach(items) { item in
                    UnmatchedRow(item: item,
                                 onMatch: { matching = MatchRequest(item: item) },
                                 onPlay: { playing = PlaybackQueue(source: item.media.source, items: [item.media.source]) })
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 14)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("未匹配影片")
        .designScreen("unmatched")
        .sheet(item: $matching) { request in
            MetadataMatchView(file: request.file, current: request.current, onMatch: { result in
                await metadata.match(result, to: request.file)
            }, onClear: nil)
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
    }
}

private struct UnmatchedRow: View {
    let item: HomeMediaItem
    let onMatch: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: AppIcon.video.name).font(.title).foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 68).background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.tile))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.media.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text([item.sourceLabel, formatSize(item.media.size)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(action: onMatch) { Label("匹配封面", systemImage: AppIcon.poster.name) }
                    .buttonStyle(PrimaryActionStyle())
                Button(action: onPlay) { Label("直接播放", systemImage: AppIcon.play.name) }
                    .buttonStyle(SecondaryActionStyle())
            }
        }
        .padding(16).surfaceCard()
    }
}
