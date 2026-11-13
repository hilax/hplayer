import SwiftUI

/// 网盘页导航栈里的页面：某个文件夹，或文件管理的二级页面（离线下载、回收站、下载管理）
enum CloudRoute: Hashable {
    case folder(Crumb)
    case page(ManagementPage)
}

/// 网盘：115 账号卡片、全部文件、离线下载与本机视频（2.0：磁力播放和磁力聚合移到「磁力」Tab）。
struct CloudTab: View {
    var onSearch: () -> Void = {}
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
    @State private var connecting = false
    @State private var connectionError = ""
    @State private var openRequestID = UUID()

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
                CookieWebLoginView {
                    showDirectLogin = false
                    path.append(.folder(Crumb(cid: "0", name: "115 网盘")))
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDirectLogin = false } } }
            }
        }
        .alert("无法连接 115", isPresented: Binding(get: { !connectionError.isEmpty }, set: { if !$0 { connectionError = "" } })) {
            Button("重新登录 115") { connectionError = ""; showDirectLogin = true }
            Button("关闭", role: .cancel) { connectionError = "" }
        } message: { Text(connectionError) }
        .onChange(of: appState.sessionID) { _ in
            openRequestID = UUID()
            path = []; playing = nil
            connecting = false; connectionError = ""
        }
        .onDisappear {
            openRequestID = UUID()
            connecting = false
        }
    }

    private var rootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitleBar(title: "网盘") {
                    BarIconButton(icon: .search, label: "搜索网盘", identifier: "cloud.search", action: onSearch)
                }
                .padding(.horizontal, -Theme.contentInset)
                accountCard.reveal(0)
                toolRows.reveal(1)
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
        .designScreen(appState.isAuthenticated ? "library" : "library-empty")
    }

    private var accountCard: some View {
        Button { Task { await open115() } } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("115")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color(uiColor: UIColor(hex: 0x2A6BFF)), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.isAuthenticated ? "115 网盘" : "连接 115 网盘")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        Text(status?.userName ?? "把云端收藏，变成私人影院")
                            .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if connecting { ProgressView() } else {
                        Text(syncText).font(.caption2.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(statusColor.opacity(0.14), in: Capsule())
                    }
                }
                if let quota {
                    VStack(spacing: 8) {
                        QuotaBar(ratio: quotaRatio(quota))
                        HStack {
                            Text("已使用 \(quota.usedText)")
                            Spacer()
                            Text("共 \(quota.totalText)")
                        }
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(appState.isAuthenticated ? primaryActionTitle : "登录并连接")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Image(systemName: AppIcon.forward.name).font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(appState.isAuthenticated ? Theme.accent : Theme.onPrimary)
                .padding(.horizontal, appState.isAuthenticated ? 0 : 16)
                .frame(minHeight: appState.isAuthenticated ? 28 : 44)
                .background(appState.isAuthenticated ? Color.clear : Theme.primaryAction, in: Capsule())
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
        .buttonStyle(.pressable(scale: 0.98))
        .disabled(connecting)
        .accessibilityIdentifier("library.account")
    }

    /// 全部文件、传输中心、本机视频：一组简洁的列表，只写标题，右边是数量。
    private var toolRows: some View {
        DesignGroup {
            Button { Task { await open115() } } label: {
                LibraryActionRow(symbol: AppIcon.allFiles.name, title: "全部文件",
                                 value: appState.isAuthenticated ? "" : "未登录")
            }
            .buttonStyle(.pressable(scale: 0.985))
            .disabled(connecting)
            .accessibilityIdentifier("cloud.browse")
            Divider().padding(.leading, LibraryActionRow.dividerInset)
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
            NavigationLink { LocalVideosView() } label: {
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
            let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
            playing = PlaybackQueue(source: source, items: files.map { .p115(title: $0.name, pickCode: $0.pickCode) })
        }, management: true, onOpenPage: { path.append(.page($0)) },
                      initialFiles: previewFiles(in: crumb))
        .navigationTitle(crumb.name)
        .toolbar(.visible, for: .navigationBar)
    }

    private func previewFiles(in crumb: Crumb) -> [P115File]? {
        #if DEBUG
        return InterfacePreview.cloudFiles(cid: crumb.cid)
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
        }
    }

    /// 只有文件夹页面才算面包屑里的一级
    private var folderCrumbs: [Crumb] {
        path.compactMap { route -> Crumb? in
            if case .folder(let crumb) = route { return crumb }
            return nil
        }
    }

    /// 从网盘根目录到这一层的路径，用来画面包屑
    private func trail(to crumb: Crumb) -> [Crumb] {
        let crumbs = folderCrumbs
        guard let index = crumbs.firstIndex(of: crumb) else { return [crumb] }
        return Array(crumbs.prefix(through: index))
    }

    /// 回到面包屑里的第 `index` 级文件夹：它上面的页面全部收起
    private func jump(to index: Int) {
        var seen = -1
        var target: Int?
        for (position, route) in path.enumerated() {
            if case .folder = route {
                seen += 1
                if seen == index {
                    target = position
                    break
                }
            }
        }
        guard let target, target < path.count - 1 else { return }
        path.removeLast(path.count - 1 - target)
    }

    /// 离线任务页的「在网盘中查看」：直接定位到那个文件夹
    private func showFolder(_ entries: [Direct115PathEntry]) {
        guard let first = entries.first else { return }
        var routes: [CloudRoute] = [.folder(Crumb(cid: first.id, name: "115 网盘"))]
        for entry in entries.dropFirst() {
            routes.append(.folder(Crumb(cid: entry.id, name: entry.name)))
        }
        path = routes
    }

    /// 打开离线下载这类二级页面；没登录时先去登录
    private func openPage(_ page: ManagementPage) {
        guard appState.isAuthenticated, appState.directClient() != nil else {
            showDirectLogin = true
            return
        }
        path.append(.page(page))
    }

    // MARK: 状态文字

    private var primaryActionTitle: String {
        appState.isAuthenticated ? "浏览全部文件" : "登录 115"
    }

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

    private func open115() async {
        guard !connecting else { return }
        guard let direct = appState.directClient() else { showDirectLogin = true; return }
        #if DEBUG
        if InterfacePreview.active {
            path.append(.folder(Crumb(cid: "0", name: "115 网盘")))
            return
        }
        #endif
        let sessionID = appState.sessionID
        let requestID = UUID()
        openRequestID = requestID
        connecting = true
        defer {
            if openRequestID == requestID { connecting = false }
        }
        do {
            let loadedStatus = try await direct.user()
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == openRequestID else { return }
            accountInfo.record(loadedStatus, for: sessionID)
            path.append(.folder(Crumb(cid: "0", name: "115 网盘")))
        } catch {
            guard !Task.isCancelled, sessionID == appState.sessionID, requestID == openRequestID else { return }
            connectionError = error.localizedDescription
        }
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
