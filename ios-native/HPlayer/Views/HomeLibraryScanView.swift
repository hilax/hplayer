import SwiftUI
import UIKit

/// 媒体库管理：
/// 1. 顶部合并后的「片库工作台」：扫描控制、片库概况、封面覆盖率与实时进度统一在一张卡片里；
/// 2. 「封面与资料」组：自动匹配开关、未匹配影片、资料来源摘要、重新匹配，以及开启番号后的演员补全；
/// 3. 「整理与清理」组：失效文件清理、隐藏精选恢复、清空继续观看；低频刷新与诊断信息收在右上角「⋯」菜单。
///
/// 性能隔离：只有顶部控制台子视图观察 `CloudLibraryScanner`，扫描文件夹高频更新进度时，
/// 下方的设置分组与维护项不会跟着整页重绘。
struct HomeLibraryScanView: View {
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var local: LocalMediaStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var librarySnapshots: LibrarySnapshotStore
    @ObservedObject private var featuredStore = FeaturedStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AdultMetadataSettings.enabledKey) private var adultMatching = false
    @AppStorage(CoverMatchingSettings.automaticKey) private var automaticMatching = false

    let onStart: (Bool) -> Void
    let onStartFolders: ([ScanFolderTarget]) -> Void
    let onRetryMatching: () -> Void
    /// 从「我的」或片库频道压进公共导航栈时为 true：用系统返回键，和其他二级页面一样从右侧推入。
    /// 单独作为根页面（界面截图、扫描页测试）时为 false：自带导航栈和返回键。
    var pushed = false

    @State private var pickingFolder = false
    @State private var showCleanup = false
    @State private var confirmClearHistory = false
    @State private var hasTMDBKey = !TMDBClient.storedKey.isEmpty
    @State private var hasDMMKey = DMMClient.storedCredentials() != nil
    @State private var performerStats = (have: 0, total: 0)

    private var stats: LibraryOverviewCounts {
        if librarySnapshots.ready {
            let total = librarySnapshots.home.items.count
            let unmatched = librarySnapshots.home.unmatched.count
            return LibraryOverviewCounts(total: total, matched: max(0, total - unmatched), unmatched: unmatched)
        }
        let files = HomeLibrary.media(local: local, cloud: library, appState: appState)
        let matched = files.filter { metadata.metadataByMediaID[$0.id]?.hasUsablePoster == true }.count
        return LibraryOverviewCounts(total: files.count, matched: matched, unmatched: max(0, files.count - matched))
    }

    private var sourcesSummary: String {
        switch (hasTMDBKey, adultMatching) {
        case (true, true): return "TMDB · 番号"
        case (true, false): return "TMDB"
        case (false, true): return "含番号"
        case (false, false): return "默认"
        }
    }

    private var hasExtraSources: Bool { hasTMDBKey || adultMatching }

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
                                    NavigationIcon(.back)
                                }
                                .accessibilityLabel("返回")
                                .accessibilityIdentifier("manage.back")
                            }
                        }
                }
            }
        }
        .navigationButtonTint()
        .designScreen("manage")
        .sheet(isPresented: $pickingFolder) {
            ScanFolderPicker(onSelectFolders: onStartFolders).environmentObject(appState)
        }
        .sheet(isPresented: $showCleanup) {
            LibraryCleanupView(appState: appState, library: library).environmentObject(appState)
        }
    }

    private var page: some View {
        let counts = stats
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                LibraryConsoleCard(
                    counts: counts,
                    onStart: onStart,
                    onPickFolder: { pickingFolder = true }
                )

                coverSection(counts: counts)

                maintenanceSection
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.section + Theme.Space.xs)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            // 页面里的开关和进度条用琥珀；导航栏按键跟随全局正文色
            .tint(Theme.accentFill)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("媒体库管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu(counts: counts)
            }
        }
        .onAppear {
            refreshSourceState()
            refreshPerformerStats()
        }
        .task(id: "\(metadata.revision)|\(adultMatching)") {
            refreshPerformerStats()
        }
    }

    // MARK: 导航栏更多菜单

    private func moreMenu(counts: LibraryOverviewCounts) -> some View {
        Menu {
            Button("刷新片库列表", icon: AppIcon.refresh.name) {
                refreshLibrary()
            }
            Button("复制匹配诊断信息", icon: AppIcon.copy.name) {
                copyDiagnostics(counts: counts)
            }
            .accessibilityIdentifier("scan.copyDiagnostics")
        } label: {
            NavigationIcon(.more)
        }
        .accessibilityLabel("更多维护选项")
        .accessibilityIdentifier("manage.more")
    }

    private func refreshSourceState() {
        hasTMDBKey = !TMDBClient.storedKey.isEmpty
        hasDMMKey = DMMClient.storedCredentials() != nil
    }

    private func refreshPerformerStats() {
        guard adultMatching else {
            performerStats = (0, 0)
            return
        }
        let coverage = metadata.performerCoverage()
        performerStats = (coverage.withPerformers, coverage.total)
    }

    private func refreshLibrary() {
        local.refresh()
        let files = HomeLibrary.media(local: local, cloud: library, appState: appState)
        Task {
            await metadata.prewarmNames(files.map(\.name), priority: .utility)
            if automaticMatching {
                metadata.resumeAutomatic()
                metadata.sync(files: files)
            } else {
                metadata.hydrate(files: files)
            }
        }
        HUD.show("已刷新片库列表", .success)
    }

    /// 排查「为什么没匹配上、为什么慢」：开关和 Key 的状态加上最近的查找记录，不含 Cookie 和 Key 本身。
    private func copyDiagnostics(counts: LibraryOverviewCounts) {
        let media = library.media(for: appState)
        var lines = [
            "HPlayer 匹配诊断",
            "番号匹配：\(adultMatching ? "开" : "关")；DMM 接口 Key：\(hasDMMKey ? "已填" : "未填")；TMDB Key：\(hasTMDBKey ? "已填" : "未填")",
            "片库 \(media.count) 部，已有封面 \(counts.matched) 部，自动匹配：\(metadata.isMatching ? "进行中" : "空闲")",
            "番号影片 \(performerStats.total) 部，已有演员信息 \(performerStats.have) 部，演员补全：\(metadata.performerEnrichmentState)，已处理 \(metadata.performerEnrichmentProcessed) / \(metadata.performerEnrichmentTotal) 个番号，失败 \(metadata.performerEnrichmentFailures) 个",
            "最近记录（新的在后）：",
        ]
        let recent = MatchDiagnostics.shared.snapshot
        lines += recent.isEmpty ? ["（还没有记录。先点「重新匹配未识别封面」再复制）"] : recent
        UIPasteboard.general.string = lines.joined(separator: "\n")
        HUD.show("已复制匹配诊断信息", .success)
    }

    // MARK: 封面与资料

    private func coverSection(counts: LibraryOverviewCounts) -> some View {
        let nothingToMatch = counts.total == 0
        return SettingsSection(
            title: "封面与资料",
            footnote: adultMatching
                ? "开启番号匹配后可补查缺失的演员资料；同一演员有两部以上影片时，首页会自动生成演员合集。"
                : "关闭自动匹配后，仅在点击「重新匹配未识别封面」或手动选择封面时联网查找。"
        ) {
            SettingRow(icon: .autoMatch, title: "自动匹配封面", subtitle: "入库后自动查找海报与简介") {
                Toggle("自动匹配封面", isOn: $automaticMatching)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("scan.automaticMatching")
            }

            NavigationLink { HomeUnmatchedMediaView() } label: {
                LibraryActionRow(
                    symbol: AppIcon.poster.name,
                    title: "未匹配影片",
                    subtitle: "查看、播放或手动校正封面",
                    value: counts.unmatched > 0 ? "\(counts.unmatched)" : "已齐全",
                    valueHighlighted: counts.unmatched > 0
                )
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("scan.unmatched")

            NavigationLink { MetadataSourcesView() } label: {
                LibraryActionRow(
                    symbol: AppIcon.tune.name,
                    title: "资料来源",
                    subtitle: "番组计划、IMDb、TMDB 与番号",
                    value: sourcesSummary,
                    valueHighlighted: hasExtraSources
                )
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("scan.sources")

            Button(action: {
                Haptics.tap()
                onRetryMatching()
            }) {
                LibraryActionRow(
                    symbol: AppIcon.posterSearch.name,
                    title: "重新匹配未识别封面",
                    subtitle: metadata.isMatching ? "正在匹配中，可在上方工作台停止" : "对还没有封面的影片重新查一次",
                    showsChevron: false
                )
            }
            .buttonStyle(.pressable(scale: 0.985))
            .disabled(nothingToMatch || metadata.isMatching)

            if adultMatching {
                PerformerEnrichmentRow(stats: performerStats)
            }
        }
    }

    // MARK: 整理与清理

    private var maintenanceSection: some View {
        SettingsSection(
            title: "整理与清理",
            footnote: "只读取网盘文件列表并更新本机片库记录，不下载整部视频，也不会删除网盘里的任何文件。"
        ) {
            Button { showCleanup = true } label: {
                LibraryActionRow(
                    symbol: AppIcon.checklist.name,
                    title: "清理已失效文件",
                    subtitle: "核对网盘中已删视频，从首页和片库移除"
                )
            }
            .buttonStyle(.pressable(scale: 0.985))
            .disabled(!appState.isAuthenticated)
            .accessibilityIdentifier("scan.cleanup")

            if !featuredStore.hidden.isEmpty {
                Button {
                    let count = featuredStore.hidden.count
                    featuredStore.restoreAll()
                    HUD.show("已恢复 \(count) 部精选影片", .success)
                } label: {
                    LibraryActionRow(
                        symbol: AppIcon.hidden.name,
                        title: "恢复隐藏的精选影片",
                        subtitle: "恢复后将重新参与首页大图展示",
                        value: "\(featuredStore.hidden.count) 部",
                        showsChevron: false
                    )
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("manage.restoreFeatured")
            }

            Button(role: .destructive) { confirmClearHistory = true } label: {
                LibraryActionRow(
                    symbol: AppIcon.history.name,
                    title: "清空继续观看",
                    subtitle: "只清除观看进度，不影响影片",
                    showsChevron: false,
                    tone: .danger
                )
            }
            .buttonStyle(.pressable(scale: 0.985))
            .confirmationDialog("清空继续观看记录？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) {
                    RecentStore.shared.clear()
                    MagnetHistoryStore.shared.removeAll()
                    PlaybackFrameStore.shared.removeAll()
                    HUD.show("已清空继续观看", .success)
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

// MARK: - 片库工作台主卡（扫描 + 概况 + 实时任务）

private struct LibraryOverviewCounts {
    let total: Int
    let matched: Int
    let unmatched: Int

    var ratio: Double {
        total > 0 ? Double(matched) / Double(total) : 0
    }
}

/// 独立观察 `CloudLibraryScanner` 的顶部工作台卡片：
/// 扫描期间进度每秒更新只重绘这一张卡片，下方设置与维护区完全不受影响。
private struct LibraryConsoleCard: View {
    @EnvironmentObject private var scanner: CloudLibraryScanner
    @EnvironmentObject private var metadata: MediaMetadataStore
    @EnvironmentObject private var library: MediaLibraryStore
    @EnvironmentObject private var appState: AppState

    let counts: LibraryOverviewCounts
    let onStart: (Bool) -> Void
    let onPickFolder: () -> Void

    private var statusTitle: String {
        switch scanner.phase {
        case .idle: return "扫描你的 115 片库"
        case .running: return "正在扫描 \(scanner.scopeName ?? "整个网盘")"
        case .paused: return "扫描已暂停"
        case .failed: return "扫描尚未完成"
        case .completed: return "文件扫描完成"
        }
    }

    private var statusSubtitle: String {
        switch scanner.phase {
        case .idle:
            return appState.isAuthenticated
                ? "选择全盘或指定文件夹扫描，自动整理电影与剧集"
                : "连接 115 网盘后，即可扫描并整理云端影片"
        case .running:
            return scanner.currentFolderName.isEmpty
                ? "正在发现文件夹与视频，切回首页时也在后台平稳进行"
                : "正在读取：\(scanner.currentFolderName)"
        case .paused:
            return "扫描进度已保存，可随时继续或更换文件夹"
        case .failed:
            return "已发现的视频和进度都已保留，可稍后继续"
        case .completed:
            return metadata.isMatching ? "文件扫描已完成，正在自动补充封面" : "所有目录已扫描，可随时重新扫描或增量清理"
        }
    }

    private var ringValue: Double {
        switch scanner.phase {
        case .running, .paused, .failed:
            let found = max(scanner.progress.discoveredFolders, 1)
            return min(Double(scanner.progress.scannedFolders) / Double(found), 1)
        case .completed:
            return counts.total > 0 ? counts.ratio : 1
        case .idle:
            return counts.ratio
        }
    }

    private var ringIcon: AppIcon {
        switch scanner.phase {
        case .running: return .scan
        case .completed: return .success
        case .failed: return .alert
        case .paused: return .pause
        case .idle: return .autoMatch
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            // 顶部：环形进度 + 状态说明
            HStack(spacing: Theme.Space.md + 2) {
                ProgressRing(value: ringValue, lineWidth: 5) {
                    Image(icon: ringIcon)
                        .font(.scaled(20, weight: Theme.iconWeight))
                        .foregroundStyle(scanner.phase == .failed ? Theme.warning : Theme.accent)
                        .morphSymbol()
                }
                .frame(width: 56, height: 56)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(scanner.phase == .running ? "正在扫描" : statusTitle)

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(alignment: .center, spacing: Theme.Space.sm) {
                        Text(statusTitle)
                            .font(Theme.Typo.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if appState.isAuthenticated {
                            scopeChip
                        }
                    }
                    Text(statusSubtitle)
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 中部：合并后的片库概况指标条 + 封面覆盖率进度
            overviewStrip

            // 实时任务信息（仅在扫描非空闲或封面自动匹配中显示）
            if scanner.phase != .idle || metadata.isMatching || !scanner.lastError.isEmpty {
                liveActivitySection
            }

            // 底部：主次扫描操作（未登录时直接引导连接 115）
            actionsSection
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    /// 右上角扫描范围胶囊：点按可直接更换要扫描的文件夹
    private var scopeChip: some View {
        Button {
            Haptics.tap()
            onPickFolder()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(icon: .folder)
                    .font(.scaled(11, weight: Theme.iconWeight))
                Text(scanner.scopeName ?? "全盘")
                    .font(Theme.Typo.badge)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Space.sm)
            .frame(maxWidth: 160, minHeight: 24)
            .background(Theme.surfaceRaised, in: Capsule())
            .contentShape(VerticalHitArea(extra: 10))
        }
        .buttonStyle(.pressable(scale: 0.94))
        .disabled(scanner.phase == .running)
        .accessibilityLabel("当前扫描范围：\(scanner.scopeName ?? "整个网盘")")
    }

    /// 三列概况指标 + 底部 4pt 琥珀覆盖条；点击「待匹配」直达未匹配列表
    private var overviewStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: 0) {
                metricCell(title: "片库视频", value: "\(counts.total)", color: Theme.textPrimary)
                metricDivider
                metricCell(
                    title: counts.total > 0 ? "已有封面 \(Int((counts.ratio * 100).rounded()))%" : "已有封面",
                    value: "\(counts.matched)",
                    color: Theme.textPrimary
                )
                metricDivider
                NavigationLink { HomeUnmatchedMediaView() } label: {
                    VStack(alignment: .leading, spacing: Theme.Space.hair) {
                        HStack(spacing: Theme.Space.hair) {
                            Text("待匹配")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Image(icon: .forward)
                                .font(.scaled(9, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Text("\(counts.unmatched)")
                            .font(.display(20).monospacedDigit())
                            .foregroundStyle(counts.unmatched > 0 ? Theme.accent : Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Theme.Space.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.96))
                .accessibilityLabel("待匹配 \(counts.unmatched) 部，点按查看")
            }

            ThinProgressBar(fraction: counts.ratio, paused: counts.total == 0)
        }
        .padding(Theme.Space.md)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private func metricCell(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
            Text(title)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(.display(20).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: Theme.Stroke.hairline, height: 32)
            .padding(.horizontal, Theme.Space.xs)
    }

    @ViewBuilder
    private var liveActivitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if scanner.phase != .idle {
                HStack(spacing: Theme.Space.sm) {
                    if scanner.phase == .running {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(icon: scanner.phase == .completed ? .success : .folder)
                            .font(.scaled(13, weight: Theme.iconWeight))
                            .foregroundStyle(scanner.phase == .completed ? Theme.success : Theme.textSecondary)
                    }
                    Text("文件夹 \(scanner.progress.scannedFolders) / \(scanner.progress.discoveredFolders)")
                        .font(Theme.Typo.meta.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Text("·")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textMuted)
                    Text("本次发现 \(scanner.progress.discoveredVideos) 部")
                        .font(Theme.Typo.meta.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm + 2)
                .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }

            if !scanner.lastError.isEmpty {
                DesignNotice(symbol: AppIcon.alert.name, text: scanner.lastError, warning: true)
            }

            if metadata.isMatching {
                HStack(spacing: Theme.Space.md) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在匹配封面")
                    VStack(alignment: .leading, spacing: Theme.Space.hair) {
                        Text("正在自动匹配封面")
                            .font(Theme.Typo.meta.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("已有封面 \(counts.matched) 部，未匹配视频仍可播放")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Button {
                        metadata.stopByUser()
                        library.flush()
                    } label: {
                        Text("停止")
                            .font(Theme.Typo.meta.weight(.semibold))
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, Theme.Space.md)
                            .frame(minHeight: 32)
                            .background(Theme.danger.opacity(0.12), in: Capsule())
                            .contentShape(VerticalHitArea(extra: 6))
                    }
                    .buttonStyle(.pressable(scale: 0.94))
                    .accessibilityIdentifier("scan.stopMatching")
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm + 2)
                .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: Theme.Space.sm + 2) {
            if !appState.isAuthenticated {
                NavigationLink { CookieWebLoginView(onConnected: {}) } label: {
                    HStack(spacing: Theme.Space.md) {
                        RowIcon(icon: .cloudLocked, tint: Theme.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Space.hair) {
                            Text("连接 115 后可扫描云端目录")
                                .font(Theme.Typo.row.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("登录后就能扫描并整理你的云端片库")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: Theme.Space.sm)
                        Image(icon: .forward)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.md)
                    .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.985))
            }

            VStack(spacing: Theme.Space.sm + 2) {
                if scanner.phase == .running {
                    Button {
                        scanner.pause()
                        metadata.stopByUser()
                        library.flush()
                    } label: {
                        Label("暂停扫描", icon: .pause)
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .accessibilityIdentifier("scan.pause")
                } else {
                    if scanner.canResume {
                        Button { onStart(false) } label: {
                            Label("继续扫描", icon: .play)
                        }
                        .buttonStyle(PrimaryActionStyle())
                        .accessibilityIdentifier("scan.resume")
                    } else {
                        Button { onStart(scanner.phase == .completed) } label: {
                            Label(scanner.phase == .completed ? "重新扫描全盘" : "开始全盘扫描", icon: .autoMatch)
                        }
                        .buttonStyle(PrimaryActionStyle())
                        .accessibilityIdentifier("scan.start")
                    }

                    HStack(spacing: Theme.Space.sm + 2) {
                        if scanner.canResume {
                            Button { onStart(true) } label: {
                                Label("从头重扫", icon: .refresh)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .buttonStyle(SecondaryActionStyle())
                        }
                        Button(action: onPickFolder) {
                            Label("选择文件夹扫描", icon: .folderSettings)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .buttonStyle(SecondaryActionStyle())
                        .accessibilityIdentifier("scan.chooseFolder")
                    }
                }
            }
            .disabled(!appState.isAuthenticated)
        }
    }
}

// MARK: - 演员资料补全行（合入「封面与资料」组）

/// 将原本独立占满半屏的「演员资料」卡片精炼为「封面与资料」组内的一行：
/// 显示覆盖数量与实时补全进度，右侧直接一键开始或停止。
private struct PerformerEnrichmentRow: View {
    @EnvironmentObject private var metadata: MediaMetadataStore
    let stats: (have: Int, total: Int)

    private var active: Bool {
        metadata.performerEnrichmentState == .waiting || metadata.performerEnrichmentState == .running
    }

    private var canStart: Bool {
        active || metadata.isMatching || stats.have < stats.total
    }

    private var subtitleText: String {
        switch metadata.performerEnrichmentState {
        case .waiting:
            return "封面匹配完成后自动开始补全"
        case .running:
            return "正在补全 · 已处理 \(metadata.performerEnrichmentProcessed) / \(metadata.performerEnrichmentTotal) 个番号"
        case .failed:
            return "部分资料暂时无法获取，请检查网络后重试"
        case .completed:
            return metadata.performerEnrichmentFailures > 0
                ? "补全结束（部分失败），已有 \(stats.have) / \(stats.total) 部"
                : "补全完成 · 已有 \(stats.have) / \(stats.total) 部"
        case .stopped:
            return "已停止 · 已有 \(stats.have) / \(stats.total) 部"
        case .idle:
            return stats.total == 0
                ? "尚无已识别的番号影片"
                : "已有 \(stats.have) / \(stats.total) 部 · 可补查缺失演员"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 14) {
                RowIcon(icon: .people, tint: metadata.performerEnrichmentState == .failed ? Theme.warning : Theme.textPrimary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("演员资料")
                        .font(Theme.Typo.row)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitleText)
                        .font(Theme.Typo.caption.monospacedDigit())
                        .foregroundStyle(metadata.performerEnrichmentState == .failed ? Theme.warning : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Space.sm)

                Button {
                    Haptics.tap()
                    if active {
                        metadata.stopPerformerEnrichment()
                    } else {
                        metadata.startPerformerEnrichment(force: true)
                    }
                } label: {
                    Text(active ? "停止" : "补全")
                        .font(Theme.Typo.meta.weight(.semibold))
                        .foregroundStyle(active ? Theme.danger : (canStart ? Theme.onPrimary : Theme.textMuted))
                        .padding(.horizontal, Theme.Space.md)
                        .frame(minHeight: 32)
                        .background(
                            active ? Theme.danger.opacity(0.12) : (canStart ? Theme.primaryAction : Theme.tileTint),
                            in: Capsule()
                        )
                        .contentShape(VerticalHitArea(extra: 6))
                }
                .buttonStyle(.pressable(scale: 0.94))
                .disabled(!canStart)
                .accessibilityLabel(active ? "停止补全演员" : "补全演员资料")
                .accessibilityIdentifier("scan.enrichPerformers")
            }

            if metadata.performerEnrichmentState == .running, metadata.performerEnrichmentTotal > 0 {
                ThinProgressBar(
                    fraction: Double(metadata.performerEnrichmentProcessed) / Double(metadata.performerEnrichmentTotal)
                )
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(minHeight: 52)
    }
}

// MARK: - 未匹配影片列表

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
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
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
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.section + Theme.Space.xs)
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
        VStack(alignment: .leading, spacing: Theme.Space.md + 2) {
            HStack(spacing: Theme.Space.md + 2) {
                Image(icon: .video)
                    .font(.scaled(22, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 48, height: 64)
                    .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    Text(item.media.name)
                        .font(Theme.Typo.row.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text([item.sourceLabel, formatSize(item.media.size)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.Typo.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: Theme.Space.sm + 2) {
                Button(action: onMatch) { Label("匹配封面", icon: .poster) }
                    .buttonStyle(PrimaryActionStyle())
                Button(action: onPlay) { Label("直接播放", icon: .play) }
                    .buttonStyle(SecondaryActionStyle())
            }
        }
        .padding(Theme.Space.lg)
        .surfaceCard()
    }
}
