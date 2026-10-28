import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject private var appState: AppState

    @State private var status: P115Status?
    @State private var quota: QuotaResponse?
    @State private var path: [Crumb] = []
    @State private var playing: PlaybackSource?
    @State private var showAddSource = false
    @State private var showSetup = false
    @State private var showOfficial = false
    @State private var showDirectLogin = false
    @State private var connecting = false
    @State private var connectionError = ""

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("资源库")
                        .font(.system(size: 40, weight: .bold))
                        .padding(.top, 8)

                    searchEntry

                    LazyVGrid(columns: columns, spacing: 14) {
                        p115Card
                        addCard
                    }
                    NavigationLink {
                        TorrentView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title2).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("BT 种子与云下载").font(.headline)
                                Text("解析种子、选择文件并查看任务")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(18).glassCard(cornerRadius: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
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
                }
            }
            .navigationDestination(for: Crumb.self) { crumb in
                DirectoryView(
                    cid: crumb.cid,
                    onOpenDir: { path.append($0) },
                    onPlay: { file in
                        playing = .p115(title: file.name, pickCode: file.pickCode)
                    }
                )
                .navigationTitle(crumb.name)
            }
        }
        .fullScreenCover(item: $playing) { source in
            PlayerView(source: source)
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

    private var searchEntry: some View {
        NavigationLink {
            SearchView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("搜索")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .glassCapsule()
        }
        .buttonStyle(.plain)
    }

    private var p115Card: some View {
        Button {
            Task { await open115() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(status?.userName ?? "115 网盘")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if connecting { ProgressView().frame(width: 34, height: 34) } else { Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Text("5")
                                .font(.headline)
                                .foregroundStyle(.white)
                        ) }
                }

                Spacer(minLength: 8)

                Text(quotaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Text("115 网盘")
                        .font(.caption)
                    Spacer()
                    Text(syncText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(height: 150)
            .glassCard()
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    private var addCard: some View {
        Button {
            showAddSource = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("添加资源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .glassCard()
        }
        .buttonStyle(.plain)
        .confirmationDialog("添加资源", isPresented: $showAddSource, titleVisibility: .visible) {
            Button("115 网盘") {
                Task { await open115() }
            }
            Button("WebDAV") { }
                .disabled(true)
            Button("SMB") { }
                .disabled(true)
            Button("Emby / Jellyfin") { }
                .disabled(true)
            Button("取消", role: .cancel) { }
        } message: {
            Text("WebDAV、SMB、Emby 正在开发中")
        }
    }

    private var quotaLine: String {
        guard let quota else {
            return appState.isAuthenticated ? "点击查看" : "未连接"
        }
        return "\(quota.usedText) / \(quota.totalText)"
    }

    private var syncText: String {
        guard appState.isAuthenticated else { return "未连接" }
        guard let status else { return "待检查" }
        return status.configured && status.error == nil ? "已连接" : "待授权"
    }

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
