import SwiftUI

struct LibraryTab: View {
    @EnvironmentObject private var appState: AppState

    @State private var status: P115Status?
    @State private var quota: QuotaResponse?
    @State private var path: [Crumb] = []
    @State private var playing: PlaybackSource?
    @State private var showAddSource = false

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
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("115 网盘", systemImage: "cloud.fill") {
                            path.append(Crumb(cid: "0", name: "115 网盘"))
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
        .task {
            await load()
        }
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
            path.append(Crumb(cid: "0", name: "115 网盘"))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(status?.userName ?? "115 网盘")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Text("5")
                                .font(.headline)
                                .foregroundStyle(.white)
                        )
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
                path.append(Crumb(cid: "0", name: "115 网盘"))
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
        appState.isAuthenticated ? "已连接" : "未连接"
    }

    private func load() async {
        guard appState.isAuthenticated, let client = appState.client() else {
            status = nil
            quota = nil
            return
        }

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
}
