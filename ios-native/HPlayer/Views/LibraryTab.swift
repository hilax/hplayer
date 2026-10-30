import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore

    @State private var status: P115Status?
    @State private var quota: QuotaResponse?
    @State private var path: [Crumb] = []
    @State private var playing: PlaybackQueue?
    @State private var showDirectLogin = false
    @State private var connecting = false
    @State private var connectionError = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    accountCard

                    VStack(spacing: 10) {
                        GroupLabel(title: "播放与下载")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            NavigationLink {
                                MagnetPlayerView()
                            } label: {
                                toolCard(
                                    icon: "link",
                                    colors: [Theme.brandCyan, Theme.brandBlue],
                                    title: "磁力播放",
                                    subtitle: "粘贴磁力链接，边缓冲边播放"
                                )
                            }
                            .buttonStyle(PosterButtonStyle())

                            NavigationLink {
                                TorrentView()
                            } label: {
                                toolCard(
                                    icon: "arrow.down.circle",
                                    colors: [Theme.brandBlue, Theme.brandViolet],
                                    title: "BT 云下载",
                                    subtitle: "解析种子，交给 115 下载"
                                )
                            }
                            .buttonStyle(PosterButtonStyle())
                        }
                    }

                    VStack(spacing: 10) {
                        GroupLabel(title: "本机")
                        NavigationLink {
                            LocalVideosView()
                        } label: {
                            localRow
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 10) {
                        GroupLabel(title: "更多来源 · 开发中")
                        HStack(spacing: 10) {
                            upcomingTile(icon: "externaldrive.connected.to.line.below", title: "WebDAV")
                            upcomingTile(icon: "desktopcomputer", title: "SMB 共享")
                            upcomingTile(icon: "play.tv", title: "Emby")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle("资源库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("115 网盘", systemImage: "cloud.fill") {
                            Task { await open115() }
                        }
                        Button("WebDAV", systemImage: "externaldrive.fill") { }
                            .disabled(true)
                        Button("SMB", systemImage: "desktopcomputer") { }
                            .disabled(true)
                        Button("Emby / Jellyfin", systemImage: "play.tv.fill") { }
                            .disabled(true)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加资源")
                }
            }
            .navigationDestination(for: Crumb.self) { crumb in
                DirectoryView(
                    cid: crumb.cid,
                    trail: trail(to: crumb),
                    onJump: { index in jump(to: index) },
                    onOpenDir: { path.append($0) },
                    onPlay: { file, files in
                        let source = PlaybackSource.p115(title: file.name, pickCode: file.pickCode)
                        let items = files.map { PlaybackSource.p115(title: $0.name, pickCode: $0.pickCode) }
                        playing = PlaybackQueue(source: source, items: items)
                    }
                )
                .navigationTitle(crumb.name)
            }
        }
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
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
        .task {
            await load()
        }
        .onChange(of: appState.isAuthenticated) { _ in Task { await load() } }
    }

    // MARK: 115 账号卡片

    private var accountCard: some View {
        Button {
            Task { await open115() }
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Text("115")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("115 网盘")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(status?.userName ?? "手机直连")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if connecting {
                        ProgressView()
                    } else {
                        statusPill
                    }
                }

                if let quota {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("已用 \(quota.usedText)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("共 \(quota.totalText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        QuotaBar(ratio: quotaRatio(quota))
                    }
                }

                HStack {
                    Text(primaryActionTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(18)
            .surfaceCard(cornerRadius: 24)
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(syncText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceRaised, in: Capsule())
    }

    // MARK: 行

    private func toolCard(icon: String, colors: [Color], title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IconTile(systemImage: icon, colors: colors, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .surfaceCard(cornerRadius: 20)
        .contentShape(Rectangle())
    }

    private var localRow: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: "iphone", colors: [Color(uiColor: UIColor(hex: 0x3EC6A8)), Color(uiColor: UIColor(hex: 0x1E8F7A))], size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("本机视频")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.primary)
                Text(localStore.files.isEmpty ? "从「文件」App 导入视频" : "\(localStore.files.count) 个视频 · 从「文件」App 导入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .surfaceCard(cornerRadius: 20)
        .contentShape(Rectangle())
    }

    private func upcomingTile(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            IconTile(systemImage: icon, colors: [Color(uiColor: .systemGray2), Color(uiColor: .systemGray)], size: 36)
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .surfaceCard(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityHint("开发中")
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
