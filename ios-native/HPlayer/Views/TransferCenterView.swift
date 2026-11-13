import SwiftUI

/// 传输中心：把以前分散在三处、容易混淆的「下载」放到一页里，并讲清楚各自是什么：
/// - 115 云端离线：链接交给 115 下载到网盘，之后原画播放（不占手机空间）
/// - 下载到本机：把网盘里的文件下到手机，没网也能看
/// - 磁力边下边播：不经过网盘，手机直接用 BT 边下边播
struct TransferCenterView: View {
    let onOpenPage: (ManagementPage) -> Void

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var history = MagnetHistoryStore.shared
    @State private var cloudTasks: [Direct115OfflineTask]?
    @State private var cloudError = ""

    init(onOpenPage: @escaping (ManagementPage) -> Void, previewTasks: [Direct115OfflineTask]? = nil) {
        self.onOpenPage = onOpenPage
        _cloudTasks = State(initialValue: previewTasks)
    }

    private var cloudRunning: [Direct115OfflineTask] {
        (cloudTasks ?? []).filter { $0.status == .downloading || $0.status == .waiting }
    }

    private var localActive: [DownloadItem] {
        downloads.items.filter { $0.state == .downloading || $0.state == .queued || $0.state == .paused }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary.reveal(0)

                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: "115 云端离线")
                    DesignGroup {
                        Button { onOpenPage(.offline) } label: {
                            LibraryActionRow(symbol: AppIcon.cloudDownload.name, title: "云端任务",
                                             subtitle: cloudSubtitle,
                                             value: cloudRunning.isEmpty ? "" : "\(cloudRunning.count)")
                        }
                        .buttonStyle(.pressable(scale: 0.985))
                        .accessibilityIdentifier("transfers.offline")
                        ForEach(cloudRunning.prefix(3)) { task in
                            Divider().padding(.leading, LibraryActionRow.dividerInset)
                            progressRow(title: task.name, fraction: task.percent / 100,
                                        detail: task.status == .waiting ? "排队中" : "\(Int(task.percent))%")
                        }
                    }
                }
                .reveal(1)

                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: "下载到本机")
                    DesignGroup {
                        Button { onOpenPage(.downloads) } label: {
                            LibraryActionRow(symbol: AppIcon.download.name, title: "本机下载",
                                             subtitle: localSubtitle,
                                             value: localActive.isEmpty ? "" : "\(localActive.count)")
                        }
                        .buttonStyle(.pressable(scale: 0.985))
                        .accessibilityIdentifier("transfers.downloads")
                        ForEach(localActive.prefix(3)) { item in
                            Divider().padding(.leading, LibraryActionRow.dividerInset)
                            progressRow(title: item.name, fraction: item.fraction,
                                        detail: item.state == .paused ? "已暂停" : item.state == .queued ? "排队中" : "\(Int(item.fraction * 100))%")
                        }
                    }
                }
                .reveal(2)

                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: "磁力边下边播")
                    DesignGroup {
                        NavigationLink { MagnetPlayerView() } label: {
                            LibraryActionRow(symbol: AppIcon.magnet.name, title: "边下边播",
                                             subtitle: history.items.isEmpty ? "不经过网盘，手机直接用 BT 播放" : "最近播放过 \(history.items.count) 个磁力资源")
                        }
                        .buttonStyle(.pressable(scale: 0.985))
                        .accessibilityIdentifier("transfers.bt")
                    }
                }
                .reveal(3)

                explainer.reveal(4)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("传输中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("transfers")
        .task(id: appState.sessionID) { await loadCloud() }
    }

    // MARK: 顶部三格

    private var summary: some View {
        HStack(spacing: 10) {
            summaryTile(value: cloudTasks == nil ? "–" : "\(cloudRunning.count)", label: "云端进行中", color: Theme.Source.cloud115)
            summaryTile(value: "\(localActive.count)", label: "本机下载中", color: Theme.Source.local)
            summaryTile(value: "\(history.items.count)", label: "边下边播记录", color: Theme.Source.magnet)
        }
    }

    private func summaryTile(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func progressRow(title: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            GlassProgressBar(value: min(max(fraction, 0), 1))
        }
        .padding(.leading, 60)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            explainerLine(color: Theme.Source.cloud115, title: "云端离线",
                          text: "链接交给 115 下载进网盘，热门资源几秒完成，之后原画播放，不占手机空间。")
            explainerLine(color: Theme.Source.local, title: "本机下载",
                          text: "把网盘里的视频下到手机，没有网络也能看。")
            explainerLine(color: Theme.Source.magnet, title: "边下边播",
                          text: "不经过网盘，手机直接连 BT 节点播放，适合冷门或只看一次的资源。")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private func explainerLine(color: Color, title: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            (Text(title).font(.caption.weight(.semibold)).foregroundColor(Theme.textPrimary)
             + Text("  " + text).font(.caption).foregroundColor(Theme.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 数据

    private var cloudSubtitle: String {
        if !appState.isAuthenticated { return "登录 115 后可用" }
        if !cloudError.isEmpty { return "暂时没取到任务列表" }
        guard let tasks = cloudTasks else { return "正在读取…" }
        if !cloudRunning.isEmpty { return "\(cloudRunning.count) 个任务进行中" }
        return tasks.isEmpty ? "磁力、HTTP、ed2k 链接交给 115 下载" : "全部任务已完成"
    }

    private var localSubtitle: String {
        if !localActive.isEmpty { return "\(localActive.count) 个文件正在下载" }
        let done = downloads.items.filter { $0.state == .completed }.count
        return done == 0 ? "把网盘视频下到手机离线看" : "已下载 \(done) 个文件"
    }

    private func loadCloud() async {
        guard !InterfacePreview.active, let client = appState.directClient() else {
            if !InterfacePreview.active { cloudTasks = [] }
            return
        }
        do {
            let tasks = try await client.offlineTasks(page: 1)
            cloudTasks = tasks
            cloudError = ""
        } catch {
            guard !(error is CancellationError) else { return }
            cloudError = error.localizedDescription
            if cloudTasks == nil { cloudTasks = [] }
        }
    }
}
