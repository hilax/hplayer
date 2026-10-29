import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject private var appState: AppState

    @State private var status: P115Status?
    @State private var quota: QuotaResponse?
    @State private var path: [Crumb] = []
    @State private var playing: PlaybackQueue?
    @State private var showSetup = false
    @State private var showOfficial = false
    @State private var showDirectLogin = false
    @State private var connecting = false
    @State private var connectionError = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    searchEntry

                    accountCard

                    VStack(spacing: 10) {
                        GroupLabel(title: "播放与下载")
                        VStack(spacing: 0) {
                            NavigationLink {
                                MagnetPlayerView()
                            } label: {
                                toolRow(
                                    icon: "link",
                                    colors: [Theme.brandCyan, Theme.brandBlue],
                                    title: "磁力在线播放",
                                    subtitle: "粘贴磁力链接，边缓冲边播放"
                                )
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 66)

                            NavigationLink {
                                TorrentView()
                            } label: {
                                toolRow(
                                    icon: "arrow.down.circle",
                                    colors: [Theme.brandBlue, Theme.brandViolet],
                                    title: "BT 种子与云下载",
                                    subtitle: "解析种子，选择文件后交给 115 下载"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .surfaceCard(cornerRadius: 20)
                    }

                    VStack(spacing: 10) {
                        GroupLabel(title: "更多来源")
                        VStack(spacing: 0) {
                            upcomingRow(icon: "externaldrive.connected.to.line.below", title: "WebDAV")
                            Divider().padding(.leading, 66)
                            upcomingRow(icon: "desktopcomputer", title: "SMB 共享")
                            Divider().padding(.leading, 66)
                            upcomingRow(icon: "play.tv", title: "Emby / Jellyfin")
                        }
                        .surfaceCard(cornerRadius: 20)
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
        .sheet(isPresented: $showSetup) { SettingsView() }
        .sheet(isPresented: $showDirectLogin) {
            NavigationStack {
                CookieWebLoginView {
                    showDirectLogin = false
                    path.append(Crumb(cid: "0", name: "115 网盘"))
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDirectLogin = false } } }
            }
        }
        .sheet(isPresented: $showOfficial) {
            NavigationStack {
                Official115SettingsView {
                    showOfficial = false
                    Task { await open115() }
                }
            }
        }
        .alert("无法连接 115", isPresented: Binding(get: { !connectionError.isEmpty }, set: { if !$0 { connectionError = "" } })) {
            Button("重新登录 115") { connectionError = ""; if appState.isDirect { showDirectLogin = true } else { showOfficial = true } }
            Button("关闭", role: .cancel) { connectionError = "" }
        } message: { Text(connectionError) }
        .task {
            await load()
        }
        .onChange(of: appState.isAuthenticated) { _ in Task { await load() } }
        .onChange(of: appState.mode) { _ in status = nil; quota = nil; path.removeAll(); Task { await load() } }
    }

    // MARK: 搜索入口

    private var searchEntry: some View {
        NavigationLink {
            SearchView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("搜索 115 网盘里的视频")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Theme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
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
                        Text(status?.userName ?? "115 网盘")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(appState.isDirect ? "手机直连" : "服务器模式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
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

    private func toolRow(icon: String, colors: [Color], title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            IconTile(systemImage: icon, colors: colors)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func upcomingRow(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            IconTile(systemImage: icon, colors: [Color(uiColor: .systemGray2), Color(uiColor: .systemGray)])
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("开发中")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surfaceRaised, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    // MARK: 状态文字

    private var primaryActionTitle: String {
        if !appState.isAuthenticated { return appState.isDirect ? "登录 115" : "连接服务器" }
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

        if appState.isDirect {
            guard let direct = appState.directClient() else { return }
            status = try? await direct.user()
            quota = try? await direct.quota()
            return
        }
        guard let client = appState.client() else { return }

        do {
            status = try await client.get("/api/115/status")
        } catch {
            status = nil
        }

        do {
            quota = try await client.get("/api/115/quota")
        } catch {
            quota = nil
        }
    }

    private func open115() async {
        guard !connecting else { return }
        if appState.isDirect {
            guard let direct = appState.directClient() else { showDirectLogin = true; return }
            connecting = true
            defer { connecting = false }
            do {
                status = try await direct.user()
                path.append(Crumb(cid: "0", name: "115 网盘"))
            } catch { connectionError = error.localizedDescription }
            return
        }
        guard appState.hasServer, appState.isAuthenticated, let client = appState.client() else {
            showSetup = true
            return
        }
        connecting = true
        defer { connecting = false }
        do {
            let current: P115Status = try await client.get("/api/115/status")
            status = current
            if !current.configured {
                showOfficial = true
            } else if let problem = current.error {
                connectionError = current.message ?? problem
            } else {
                path.append(Crumb(cid: "0", name: "115 网盘"))
            }
        } catch {
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
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("网盘已用 \(Int((ratio * 100).rounded()))%")
    }
}
