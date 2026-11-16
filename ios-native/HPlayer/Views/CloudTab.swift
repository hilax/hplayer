import SwiftUI

/// 网盘页导航栈里的页面：某个文件夹，或文件管理的二级页面（离线下载、回收站、下载管理）
enum CloudRoute: Hashable {
    case folder(Crumb)
    case page(ManagementPage)
    /// 115 账号：点账号条推进来的整页（切换账号、刷新登录状态、退出 115）
    case account
}

/// 网盘：登录了 115 就直接是根目录的文件，顶上是账号条和快捷入口（传输中心、离线下载、本机视频、回收站）；
/// 没登录时是登录引导，传输中心和本机视频不用登录也能用。「我的」页和这里共用同一个 115 登录。
struct CloudTab: View {
    var onSearch: () -> Void = {}
    /// 同一套网盘页面由 HomeView 的公共导航栈呈现；nil 为标签根页。
    var route: CloudRoute? = nil
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accountInfo: P115AccountInfoStore
    @EnvironmentObject private var navigation: HomeNavigation
    private var path: [CloudRoute] {
        get { navigation.cloudRoutes }
        nonmutating set { navigation.setCloudRoutes(newValue) }
    }
    @State private var playing: PlaybackQueue?
    @State private var showDirectLogin = false
    @State private var confirmLogout = false
    /// 未登录页的大标题已经滚出屏幕
    @State private var titleAway = false

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
            .navigationButtonTint()
            .hudHost(.sheet)
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
        VStack(spacing: Theme.Space.md) {
            accountStrip
            quickEntries
        }
    }

    /// 115 字样的小圆标：中性底，不再用 115 品牌蓝（全应用只有琥珀一种彩色）
    private func monogram(size: CGFloat) -> some View {
        Text("115")
            .font(.scaled(size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
            .background(Theme.surfaceHigh, in: Circle())
            .accessibilityHidden(true)
    }

    /// 账号、连接状态和容量缩成一条；点它推进 115 账号页（切换账号、刷新、退出）
    private var accountStrip: some View {
        Button { path.append(.account) } label: {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.md) {
                    monogram(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status?.userName ?? "正在读取账号")
                            .font(Theme.Typo.row.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 6, height: 6)
                            Text("115 网盘 · \(syncText)")
                        }
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: Theme.Space.xs)
                    Text("账号")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: AppIcon.forward.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                if let quota {
                    VStack(spacing: 6) {
                        QuotaBar(ratio: quotaRatio(quota))
                        HStack {
                            Text("已用 \(quota.usedText)")
                            Spacer(minLength: Theme.Space.sm)
                            Text("共 \(quota.totalText)")
                        }
                        .font(Theme.Typo.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .transition(.opacity)
                }
            }
            .padding(Theme.Space.lg)
            .surfaceCard()
            .animation(Motion.smooth, value: quota != nil)
        }
        .buttonStyle(.pressable(scale: 0.98))
        .accessibilityIdentifier("library.account")
    }

    /// 离线下载、回收站：一张卡片里的两格。本机视频在「我的」，下载进度也在那里看
    private var quickEntries: some View {
        HStack(spacing: 0) {
            QuickEntryButton(icon: .cloudDownload, title: "离线下载", identifier: "cloud.offline") {
                openPage(.offline)
            }
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: Theme.Stroke.hairline, height: 20)
            QuickEntryButton(icon: .recycleBin, title: "回收站", identifier: "cloud.recycleBin") {
                openPage(.recycleBin)
            }
        }
        .surfaceCard()
    }

    // MARK: 账号页

    /// 115 账号：头像、名字、容量；切换账号（重新扫码 / Cookie 登录）、刷新登录状态、退出 115。
    /// 点网盘页的账号条推进来；退出或换了账号后 sessionID 变化，导航栈会回到网盘根页。
    private var accountPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                accountSummary
                SettingsSection(title: "") {
                    Button {
                        showDirectLogin = true
                    } label: {
                        LibraryActionRow(symbol: AppIcon.switchAccount.name, title: "切换账号", value: "重新登录")
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                    .accessibilityIdentifier("cloud.account.switch")
                    RowDivider()
                    Button {
                        Task { await accountInfo.refreshIfNeeded(session: appState.sessionID, client: appState.directClient()) }
                    } label: {
                        LibraryActionRow(symbol: AppIcon.refresh.name, title: "刷新登录状态",
                                         value: accountInfo.isLoading(for: appState.sessionID) ? "检查中" : "", showsChevron: false)
                    }
                    .buttonStyle(.pressable(scale: 0.985))
                    .accessibilityIdentifier("cloud.account.refresh")
                }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Button("退出 115 登录") { confirmLogout = true }
                        .buttonStyle(ActionButtonStyle(kind: .secondaryDestructive, minHeight: 46))
                        .accessibilityIdentifier("cloud.account.logout")
                        .confirmationDialog("退出后将断开 115 网盘连接", isPresented: $confirmLogout, titleVisibility: .visible) {
                            Button("退出 115", role: .destructive) { appState.logout() }
                                .accessibilityIdentifier("cloud.account.confirmLogout")
                            Button("取消", role: .cancel) {}
                        }
                    Text("退出后网盘和「115 播放」不能用；本机视频、磁力播放和 HPlayer 账号不受影响。")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.xs)
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("115 账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("cloud-account")
    }

    /// 账号页顶上：头像、名字、连接状态和容量
    private var accountSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                monogram(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status?.userName ?? "115 网盘")
                        .font(Theme.Typo.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text("115 网盘 · \(syncText)")
                    }
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            if let quota {
                VStack(spacing: 6) {
                    QuotaBar(ratio: quotaRatio(quota))
                    HStack {
                        Text("已用 \(quota.usedText)")
                        Spacer()
                        Text("共 \(quota.totalText)")
                    }
                    .font(Theme.Typo.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    // MARK: 未登录

    private var signedOutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ScreenTitleBar(title: "网盘") { EmptyView() }
                    .padding(.horizontal, -Theme.contentInset)
                    .scrolledAway($titleAway)
                loginCard.reveal(0)
                Text("本机视频和下载进度在「我的」页；磁力边下边播不需要登录。")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .reveal(1)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.section + Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .overlay(alignment: .top) { CompactTitleBar(title: "网盘", visible: titleAway) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .designScreen("library-empty")
    }

    private var loginCard: some View {
        VStack(spacing: Theme.Space.md) {
            monogram(size: 56)
            VStack(spacing: Theme.Space.sm) {
                Text("登录 115，文件直接显示在这里")
                    .font(Theme.Typo.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("115 的登录、切换和退出都在这一页。")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Space.xs)
            Button("登录 115") { showDirectLogin = true }
                .buttonStyle(PrimaryActionStyle())
                .padding(.top, Theme.Space.sm)
                .accessibilityIdentifier("cloud.login")
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.page)
        .frame(maxWidth: .infinity)
        .surfaceCard()
    }

    // MARK: 路径

    @ViewBuilder
    private func destination(_ route: CloudRoute) -> some View {
        switch route {
        case .folder(let crumb):
            folderPage(crumb)
        case .page(let page):
            managementPage(page)
        case .account:
            accountPage
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
        case .downloads, .localVideos:
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
        guard appState.isAuthenticated else { return Theme.textMuted }
        if !accountInfo.error(for: appState.sessionID).isEmpty { return Theme.warning }
        guard let status else { return Theme.textMuted }
        return status.error == nil ? Theme.success : Theme.warning
    }

    private func quotaRatio(_ quota: QuotaResponse) -> Double {
        guard quota.totalBytes > 0 else { return 0 }
        return min(max(Double(quota.usedBytes) / Double(quota.totalBytes), 0), 1)
    }

}

/// 网盘容量条：4pt 琥珀实色，压在轨道上
private struct QuotaBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, proxy.size.width * ratio))
                    .animation(Motion.smooth, value: ratio)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("网盘已用 \(Int((ratio * 100).rounded()))%")
    }
}

/// 网盘根页的快捷入口：线框图标、标题，下面一行小字（有下载时显示数量，琥珀色）
private struct QuickEntryButton: View {
    let icon: AppIcon
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: icon.name)
                    .font(.scaled(17, weight: Theme.iconWeight))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 24)
                Text(title)
                    .font(Theme.Typo.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .accessibilityIdentifier(identifier)
    }
}
