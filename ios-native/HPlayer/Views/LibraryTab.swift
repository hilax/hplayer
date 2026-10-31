import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore
    @State private var status: P115Status?
    @State private var quota: QuotaResponse?
    @State private var path: [Crumb] = []
    @State private var playing: PlaybackQueue?
    @State private var showDirectLogin = false
    @State private var showManagement = false
    @State private var connecting = false
    @State private var connectionError = ""

    init(initialStatus: P115Status? = nil, initialQuota: QuotaResponse? = nil) {
        _status = State(initialValue: initialStatus)
        _quota = State(initialValue: initialQuota)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageIntroduction(eyebrow: "Your sources", title: "资源库", subtitle: "你的文件，随时可看。")
                        .padding(.bottom, 3)
                    accountCard
                    HStack(spacing: 12) {
                        NavigationLink { MagnetPlayerView() } label: {
                            toolCard(icon: "link", title: "磁力播放", subtitle: "粘贴链接，即刻开始")
                        }
                        NavigationLink { TorrentView() } label: {
                            toolCard(icon: "arrow.down.to.line", title: "BT 云下载", subtitle: "种子解析与任务管理")
                        }
                    }
                    .buttonStyle(PosterButtonStyle())
                    NavigationLink { LocalVideosView() } label: {
                        LibraryActionRow(symbol: "folder", title: "本机视频", subtitle: "从「文件」导入视频",
                                         value: localStore.files.isEmpty ? "" : "\(localStore.files.count) 个视频")
                            .surfaceCard()
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 10) {
                        GroupLabel(title: "片库管理")
                        Button { showManagement = true } label: {
                            LibraryActionRow(symbol: "viewfinder", title: "媒体库管理", subtitle: "扫描目录、整理封面与影片资料")
                                .surfaceCard()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.manage")
                    }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 14)
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
            }
        }
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
        .sheet(isPresented: $showManagement) { LibraryManagementView() }
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
        .task { await load() }
        .onChange(of: appState.isAuthenticated) { _ in Task { await load() } }
    }

    private var accountCard: some View {
        Button { Task { await open115() } } label: {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 13) {
                    Text("115")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Theme.primaryAction, in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(appState.isAuthenticated ? "115 网盘" : "连接 115 网盘")
                            .font(.headline).foregroundStyle(.primary)
                        Text(status?.userName ?? "把云端收藏，变成私人影院")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if connecting { ProgressView() } else {
                        Text(syncText).font(.caption2.weight(.medium))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if let quota {
                    VStack(spacing: 10) {
                        HStack {
                            Text("已使用 \(quota.usedText)")
                            Spacer()
                            Text("共 \(quota.totalText)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        QuotaBar(ratio: quotaRatio(quota))
                    }
                }
                HStack {
                    Text(appState.isAuthenticated ? primaryActionTitle : "登录并连接").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundStyle(appState.isAuthenticated ? Theme.accent : .white)
                .padding(.horizontal, appState.isAuthenticated ? 0 : 14)
                .frame(minHeight: appState.isAuthenticated ? 32 : 46)
                .background(appState.isAuthenticated ? Color.clear : Theme.primaryAction, in: RoundedRectangle(cornerRadius: 13))
            }
            .padding(21)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .disabled(connecting)
        .accessibilityIdentifier("library.account")
    }

    private func toolCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: icon).font(.system(size: 23, weight: .regular)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
        .surfaceCard()
        .contentShape(Rectangle())
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
        guard let status else { return "检查中" }
        return status.configured && status.error == nil ? "已连接" : "待授权"
    }

    private var statusColor: Color {
        guard appState.isAuthenticated else { return Color(uiColor: .systemGray3) }
        guard let status else { return Color(uiColor: .systemGray3) }
        return status.configured && status.error == nil ? Theme.success : Theme.warning
    }

    private func quotaRatio(_ quota: QuotaResponse) -> Double {
        guard quota.totalBytes > 0 else { return 0 }
        return min(max(Double(quota.usedBytes) / Double(quota.totalBytes), 0), 1)
    }

    // MARK: 加载

    private func load() async {
        guard !InterfacePreview.active else { return }
        guard appState.isAuthenticated else {
            status = nil
            quota = nil
            return
        }

        guard let direct = appState.directClient() else { return }
        status = try? await direct.user()
        quota = try? await direct.quota()
    }

    private func open115() async {
        guard !connecting else { return }
        guard let direct = appState.directClient() else { showDirectLogin = true; return }
        connecting = true
        defer { connecting = false }
        do {
            status = try await direct.user()
            path.append(Crumb(cid: "0", name: "115 网盘"))
        } catch { connectionError = error.localizedDescription }
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
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("网盘已用 \(Int((ratio * 100).rounded()))%")
    }
}
