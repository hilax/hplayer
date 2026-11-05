import SwiftUI

/// 网盘：115 账号卡片、四个工具入口，以及进入网盘文件浏览的入口。
struct CloudTab: View {
    var onSearch: () -> Void = {}
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var accountInfo: P115AccountInfoStore
    @State private var path: [Crumb] = []
    @State private var playing: PlaybackQueue?
    @State private var showDirectLogin = false
    @State private var connecting = false
    @State private var connectionError = ""
    @State private var openRequestID = UUID()

    private var status: P115Status? { appState.isAuthenticated ? accountInfo.status(for: appState.sessionID) : nil }
    private var quota: QuotaResponse? { appState.isAuthenticated ? accountInfo.quota(for: appState.sessionID) : nil }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenTitleBar(title: "网盘") {
                        BarIconButton(icon: .search, label: "搜索网盘", identifier: "cloud.search", action: onSearch)
                    }
                    .padding(.horizontal, -Theme.contentInset)
                    accountCard.reveal(0)
                    toolGrid.reveal(1)
                    browseRow.reveal(2)
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
            .navigationDestination(for: Crumb.self) { crumb in
                DirectoryView(cid: crumb.cid, trail: trail(to: crumb), onJump: { jump(to: $0) },
                              onOpenDir: { path.append($0) }, onPlay: { file, files in
                    let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
                    playing = PlaybackQueue(source: source, items: files.map { .p115(title: $0.name, pickCode: $0.pickCode) })
                })
                .navigationTitle(crumb.name)
                .toolbar(.visible, for: .navigationBar)
                .hidesTabBar()
            }
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
        .sheet(isPresented: $showDirectLogin) {
            NavigationStack {
                CookieWebLoginView {
                    showDirectLogin = false
                    path.append(Crumb(cid: "0", name: "115 网盘"))
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

    /// 四个工具入口：磁力播放、BT 云下载、本机视频、磁力聚合。
    /// 媒体库管理放在「我的」页，这里不再重复。
    private var toolGrid: some View {
        HStack(spacing: 8) {
            NavigationLink { MagnetPlayerView().hidesTabBar() } label: {
                toolTile(icon: .link, title: "磁力播放")
            }
            NavigationLink { TorrentView().hidesTabBar() } label: {
                toolTile(icon: .download, title: "BT 云下载")
            }
            NavigationLink { LocalVideosView().hidesTabBar() } label: {
                toolTile(icon: .device, title: "本机视频", badge: localStore.files.isEmpty ? "" : "\(localStore.files.count)")
            }
            NavigationLink { MagnetSearchView().hidesTabBar() } label: {
                toolTile(icon: .search, title: "磁力聚合")
            }
            .accessibilityIdentifier("library.magnet")
        }
        .buttonStyle(.pressable(scale: 0.94))
    }

    private func toolTile(icon: AppIcon, title: String, badge: String = "") -> some View {
        VStack(spacing: 7) {
            IconTile(icon: icon, size: 34)
            Text(title).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile + 2, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                    .background(Theme.gold, in: Capsule())
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
    }

    /// 全部文件入口：登录后进入网盘根目录。
    private var browseRow: some View {
        Button { Task { await open115() } } label: {
            LibraryActionRow(symbol: AppIcon.folder.name, title: "全部文件",
                             subtitle: appState.isAuthenticated ? "按目录浏览，选中文件夹加入首页" : "登录 115 后浏览网盘文件")
                .surfaceCard()
        }
        .buttonStyle(.pressable(scale: 0.98))
        .disabled(connecting)
        .accessibilityIdentifier("cloud.browse")
    }

    // MARK: 路径

    /// 从网盘根目录到这一层的路径，用来画面包屑
    private func trail(to crumb: Crumb) -> [Crumb] {
        guard let index = path.firstIndex(of: crumb) else { return [crumb] }
        return Array(path.prefix(through: index))
    }

    private func jump(to index: Int) {
        guard index >= 0, index < path.count - 1 else { return }
        path.removeLast(path.count - 1 - index)
    }

    // MARK: 状态文字

    private var primaryActionTitle: String {
        if !appState.isAuthenticated { return "登录 115" }
        if let status, !status.configured { return "完成 115 授权" }
        return "浏览全部文件"
    }

    private var syncText: String {
        guard appState.isAuthenticated else { return "未连接" }
        if !accountInfo.error(for: appState.sessionID).isEmpty { return "状态待确认" }
        guard let status else { return "检查中" }
        return status.configured && status.error == nil ? "已连接" : "待授权"
    }

    private var statusColor: Color {
        guard appState.isAuthenticated else { return Color(uiColor: .systemGray3) }
        if !accountInfo.error(for: appState.sessionID).isEmpty { return Theme.warning }
        guard let status else { return Color(uiColor: .systemGray3) }
        return status.configured && status.error == nil ? Theme.success : Theme.warning
    }

    private func quotaRatio(_ quota: QuotaResponse) -> Double {
        guard quota.totalBytes > 0 else { return 0 }
        return min(max(Double(quota.usedBytes) / Double(quota.totalBytes), 0), 1)
    }

    private func open115() async {
        guard !connecting else { return }
        guard let direct = appState.directClient() else { showDirectLogin = true; return }
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
            path.append(Crumb(cid: "0", name: "115 网盘"))
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
