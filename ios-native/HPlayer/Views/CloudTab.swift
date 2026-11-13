import SwiftUI

/// 网盘页导航栈里的页面：某个文件夹，或文件管理的二级页面（离线下载、回收站、下载管理）
enum CloudRoute: Hashable {
    case folder(Crumb)
    case page(ManagementPage)
}

/// 网盘：登录了 115 就直接是根目录的文件，顶上是账号条和快捷入口（传输中心、离线下载、本机视频、回收站）；
/// 没登录时是登录引导，传输中心和本机视频不用登录也能用。「我的」页和这里共用同一个 115 登录。
struct CloudTab: View {
    var onSearch: () -> Void = {}
    /// 点账号条：去「我的」页看账号详情
    var onOpenAccount: () -> Void = {}
    /// 同一套网盘页面由 HomeView 的公共导航栈呈现；nil 为标签根页。
    var route: CloudRoute? = nil
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var accountInfo: P115AccountInfoStore
    @EnvironmentObject private var navigation: HomeNavigation
    private var path: [CloudRoute] {
        get { navigation.cloudRoutes }
        nonmutating set { navigation.setCloudRoutes(newValue) }
    }
    @State private var playing: PlaybackQueue?
    @State private var showDirectLogin = false

    @ObservedObject private var downloads = DownloadManager.shared

    private var activeDownloads: Int {
        downloads.items.filter { $0.state == .downloading || $0.state == .queued }.count
    }

    private var status: P115Status? { appState.isAuthenticated ? accountInfo.status(for: appState.sessionID) : nil }
    private var quota: QuotaResponse? { appState.isAuthenticated ? accountInfo.quota(for: appState.sessionID) : nil }

    var body: some View {
        Group {
            if let route {
                destination(route)
            } else {
                rootPage
            }
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
        .sheet(isPresented: $showDirectLogin) {
            NavigationStack {
                // 登录成功后根页自动换成文件列表
                CookieWebLoginView {
                    showDirectLogin = false
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDirectLogin = false } } }
            }
        }
        .onChange(of: appState.sessionID) { _ in
            path = []; playing = nil
        }
    }

    @ViewBuilder
    private var rootPage: some View {
        if appState.isAuthenticated {
            DirectoryView(cid: "0", onOpenDir: { path.append(.folder($0)) }, onPlay: { file, files in
                play(file, files)
            }, management: true, onOpenPage: { openPage($0) },
                          initialFiles: previewFiles(cid: "0"),
                          rootTitle: "网盘", rootHeader: AnyView(rootHeader), onSearch: onSearch)
            .id(appState.sessionID)
            .navigationTitle("")
        } else {
            signedOutPage
        }
    }

    // MARK: 已登录：账号条和快捷入口

    private var rootHeader: some View {
        VStack(spacing: 12) {
            accountStrip
            quickEntries
        }
    }

    /// 账号、连接状态和容量缩成一条；点它去「我的」页看账号详情
    private var accountStrip: some View {
        Button(action: onOpenAccount) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("115")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color(uiColor: UIColor(hex: 0x2A6BFF)), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("115 网盘")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(status?.userName ?? "正在读取账号")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(syncText)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    Image(systemName: AppIcon.forward.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let quota {
                    HStack(spacing: 10) {
                        QuotaBar(ratio: quotaRatio(quota))
                        Text("已用 \(quota.usedText) / \(quota.totalText)")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
        .buttonStyle(.pressable(scale: 0.98))
        .accessibilityIdentifier("library.account")
    }

    /// 传输中心、离线下载、本机视频、回收站：一排四个方块
    private var quickEntries: some View {
        HStack(spacing: 8) {
            QuickEntryButton(icon: .transfers, title: "传输中心",
                             detail: activeDownloads == 0 ? "" : "\(activeDownloads) 个下载中",
                             highlighted: activeDownloads > 0, identifier: "cloud.transfers") {
                path.append(.page(.transfers))
            }
            QuickEntryButton(icon: .cloudDownload, title: "离线下载", identifier: "cloud.offline") {
                openPage(.offline)
            }
            QuickEntryButton(icon: .device, title: "本机视频",
                             detail: localStore.files.isEmpty ? "" : "\(localStore.files.count) 个",
                             identifier: "cloud.local") {
                path.append(.page(.localVideos))
            }
            QuickEntryButton(icon: .recycleBin, title: "回收站", identifier: "cloud.recycleBin") {
                openPage(.recycleBin)
            }
        }
    }

    // MARK: 未登录

    private var signedOutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitleBar(title: "网盘") { EmptyView() }
                    .padding(.horizontal, -Theme.contentInset)
                loginCard.reveal(0)
                VStack(alignment: .leading, spacing: 8) {
                    Text("不用登录也能用")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 4)
                    offlineRows
                }
                .reveal(1)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .designScreen("library-empty")
    }

    private var loginCard: some View {
        VStack(spacing: 12) {
            Text("115")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color(uiColor: UIColor(hex: 0x2A6BFF)), in: Circle())
            Text("登录 115，文件直接显示在这里")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Text("登录一次就行。「我的」页和这里用的是同一个账号，在哪边登录都可以。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                showDirectLogin = true
            } label: {
                Text("登录 115")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.primaryAction, in: Capsule())
            }
            .buttonStyle(.pressable(scale: 0.97))
            .padding(.top, 8)
            .accessibilityIdentifier("cloud.login")
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
    }

    /// 传输中心、本机视频：不用 115 登录
    private var offlineRows: some View {
        DesignGroup {
            Button {
                // 本机下载和边下边播不需要 115 登录，传输中心直接进；里面的云端离线再按需登录
                path.append(.page(.transfers))
            } label: {
                LibraryActionRow(symbol: AppIcon.transfers.name, title: "传输中心",
                                 value: activeDownloads == 0 ? "" : "\(activeDownloads) 个下载中",
                                 valueHighlighted: activeDownloads > 0)
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("cloud.transfers")
            Divider().padding(.leading, LibraryActionRow.dividerInset)
            Button {
                path.append(.page(.localVideos))
            } label: {
                LibraryActionRow(symbol: AppIcon.device.name, title: "本机视频",
                                 value: localStore.files.isEmpty ? "" : "\(localStore.files.count)")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .accessibilityIdentifier("cloud.local")
        }
    }

    // MARK: 路径

    @ViewBuilder
    private func destination(_ route: CloudRoute) -> some View {
        switch route {
        case .folder(let crumb):
            folderPage(crumb)
        case .page(let page):
            managementPage(page)
        }
    }

    private func folderPage(_ crumb: Crumb) -> some View {
        DirectoryView(cid: crumb.cid, trail: trail(to: crumb), onJump: { jump(to: $0) },
                      onOpenDir: { path.append(.folder($0)) }, onPlay: { file, files in
            play(file, files)
        }, management: true, onOpenPage: { openPage($0) },
                      initialFiles: previewFiles(cid: crumb.cid))
        .navigationTitle(crumb.name)
        .toolbar(.visible, for: .navigationBar)
    }

    private func play(_ file: P115File, _ files: [P115File]) {
        let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
        playing = PlaybackQueue(source: source, items: files.map { .p115(title: $0.name, pickCode: $0.pickCode) })
    }

    private func previewFiles(cid: String) -> [P115File]? {
        #if DEBUG
        return InterfacePreview.cloudFiles(cid: cid)
        #else
        return nil
        #endif
    }

    @ViewBuilder
    private func managementPage(_ page: ManagementPage) -> some View {
        switch page {
        case .transfers:
            TransferCenterView(onOpenPage: { openPage($0) })
        case .offline:
            OfflineTasksView(onShowFolder: { showFolder($0) })
        case .recycleBin:
            RecycleBinView()
        case .downloads:
            DownloadsView()
        case .localVideos:
            LocalVideosView()
        }
    }

    /// 只有文件夹页面才算面包屑里的一级
    private var folderCrumbs: [Crumb] {
        path.compactMap { route -> Crumb? in
            if case .folder(let crumb) = route { return crumb }
            return nil
        }
    }

    /// 根目录就是网盘标签页本身，面包屑的第一级固定是它
    private static let rootCrumb = Crumb(cid: "0", name: "115 网盘")

    /// 从网盘根目录到这一层的路径，用来画面包屑
    private func trail(to crumb: Crumb) -> [Crumb] {
        let crumbs = folderCrumbs
        guard let index = crumbs.firstIndex(of: crumb) else { return [Self.rootCrumb, crumb] }
        return [Self.rootCrumb] + Array(crumbs.prefix(through: index))
    }

    /// 回到面包屑里的第 `index` 级：0 是网盘根页（收起全部子页面），其余是导航栈里的文件夹
    private func jump(to index: Int) {
        guard index > 0 else {
            path = []
            return
        }
        let folderIndex = index - 1
        var seen = -1
        var target: Int?
        for (position, route) in path.enumerated() {
            if case .folder = route {
                seen += 1
                if seen == folderIndex {
                    target = position
                    break
                }
            }
        }
        guard let target, target < path.count - 1 else { return }
        path.removeLast(path.count - 1 - target)
    }

    /// 离线任务页的「在网盘中查看」：直接定位到那个文件夹。第一级是根目录，也就是网盘标签页本身
    private func showFolder(_ entries: [Direct115PathEntry]) {
        guard !entries.isEmpty else { return }
        path = entries.dropFirst().map { .folder(Crumb(cid: $0.id, name: $0.name)) }
    }

    /// 打开二级页面；离线下载、回收站要 115 登录，没登录时先去登录
    private func openPage(_ page: ManagementPage) {
        switch page {
        case .offline, .recycleBin:
            guard appState.isAuthenticated, appState.directClient() != nil else {
                showDirectLogin = true
                return
            }
        case .transfers, .downloads, .localVideos:
            break
        }
        path.append(.page(page))
    }

    // MARK: 状态文字

    private var syncText: String {
        guard appState.isAuthenticated else { return "未连接" }
        if !accountInfo.error(for: appState.sessionID).isEmpty { return "状态待确认" }
        guard let status else { return "检查中" }
        return status.error == nil ? "已连接" : "状态待确认"
    }

    private var statusColor: Color {
        guard appState.isAuthenticated else { return Color(uiColor: .systemGray3) }
        if !accountInfo.error(for: appState.sessionID).isEmpty { return Theme.warning }
        guard let status else { return Color(uiColor: .systemGray3) }
        return status.error == nil ? Theme.success : Theme.warning
    }

    private func quotaRatio(_ quota: QuotaResponse) -> Double {
        guard quota.totalBytes > 0 else { return 0 }
        return min(max(Double(quota.usedBytes) / Double(quota.totalBytes), 0), 1)
    }

}

/// 网盘容量条
private struct QuotaBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: max(6, proxy.size.width * ratio))
                    .animation(Motion.smooth, value: ratio)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("网盘已用 \(Int((ratio * 100).rounded()))%")
    }
}

/// 网盘根页的快捷入口：圆形图标、标题，下面一行小字（有下载时显示数量）
private struct QuickEntryButton: View {
    let icon: AppIcon
    let title: String
    var detail = ""
    var highlighted = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon.name)
                    .font(.system(size: 17, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceRaised, in: Circle())
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // 没有数量时也占一行，四个方块高度一致
                Text(detail.isEmpty ? " " : detail)
                    .font(.system(size: 10, weight: highlighted ? .semibold : .regular))
                    .foregroundStyle(highlighted ? Theme.accent : Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.95))
        .accessibilityIdentifier(identifier)
    }
}
