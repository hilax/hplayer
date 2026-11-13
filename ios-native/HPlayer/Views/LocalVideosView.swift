import SwiftUI
import UniformTypeIdentifiers

/// 本机视频：手机上能离线看的视频都在这一页。
/// 顶部是正在下载的文件（暂停、继续、重试），下面是下载完成和从「文件」App 导入的视频。
/// 以前分散在「传输中心 › 本机下载」和「网盘 › 本机视频」两处，现在合并到「我的」里。
struct LocalVideosView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @ObservedObject private var downloads = DownloadManager.shared

    @State private var showImporter = false
    @State private var importError = ""
    @State private var playing: PlaybackQueue?
    @State private var showDownloads = false

    private var isEmpty: Bool {
        localStore.files.isEmpty && downloads.unfinished.isEmpty
    }

    var body: some View {
        Group {
            if isEmpty && !localStore.isImporting {
                EmptyStateView(
                    icon: AppIcon.device.name,
                    title: "手机上还没有视频",
                    message: "在网盘里选择文件点「下载」，或者从「文件」App 导入，都会出现在这里，没网也能看。",
                    actionTitle: "导入视频",
                    action: { showImporter = true }
                )
            } else {
                list
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("local")
        .navigationTitle("本机视频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: {
                    Image(systemName: AppIcon.add.name)
                }
                .disabled(localStore.isImporting)
                .accessibilityLabel("导入视频")
                .accessibilityIdentifier("local.import")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { importError = await localStore.importFiles(urls).joined(separator: "\n") }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { !importError.isEmpty },
            set: { if !$0 { importError = "" } }
        )) {
            Button("好", role: .cancel) { importError = "" }
        } message: {
            Text(importError)
        }
        .playerWindow(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
        .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
        .task { localStore.refresh() }
        // 下载完成的文件移进本机视频目录后，列表跟着刷新
        .onChange(of: downloads.completed.count) { _ in localStore.refresh() }
    }

    private var list: some View {
        List {
            if localStore.isImporting {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView()
                    Text("正在导入视频…")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .plainRow(top: 12, bottom: 4)
            }

            let running = downloads.unfinished
            if !running.isEmpty {
                sectionLabel("正在下载", count: running.count)
                ForEach(running) { item in
                    DownloadProgressCard(item: item, manager: downloads)
                        .plainRow(top: 4, bottom: 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                downloads.delete(item.id)
                            } label: {
                                Label("删除", systemImage: AppIcon.trash.name)
                            }
                        }
                }
            }

            if !localStore.files.isEmpty {
                sectionLabel("可以离线看", count: localStore.files.count)
                ForEach(Array(localStore.files.enumerated()), id: \.element.id) { index, file in
                    Button {
                        play(file)
                    } label: {
                        LocalVideoRow(file: file, artwork: metadataStore.metadataByMediaID[LibraryMedia(local: file).id]?.posterURL ?? "")
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .reveal(index, id: file.id)
                    .plainRow(top: 7, bottom: 7)
                    .swipeActions {
                        Button(role: .destructive) {
                            localStore.delete(file)
                        } label: {
                            Label("删除", systemImage: AppIcon.trash.name)
                        }
                    }
                    .contextMenu {
                        Button("播放", systemImage: AppIcon.play.name) { play(file) }
                        Button("删除本地文件", systemImage: AppIcon.trash.name, role: .destructive) {
                            localStore.delete(file)
                        }
                    }
                }
            }

            if !downloads.items.isEmpty {
                Button {
                    showDownloads = true
                } label: {
                    LibraryActionRow(symbol: AppIcon.download.name, title: "下载管理",
                                     subtitle: "全部暂停或继续、查看下载记录、导出非视频文件")
                }
                .buttonStyle(.pressable(scale: 0.985))
                .accessibilityIdentifier("local.downloads")
                .plainRow(top: 20, bottom: 24)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(Motion.smooth, value: downloads.unfinished.map(\.id))
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").monospacedDigit()
        }
        .font(Theme.Typo.caption)
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .plainRow(top: 16, bottom: 2)
    }

    private func play(_ file: LocalMedia) {
        let sources = localStore.files.map { PlaybackSource.direct(title: $0.name, url: $0.url) }
        playing = PlaybackQueue(source: .direct(title: file.name, url: file.url), items: sources)
    }
}

private struct LocalVideoRow: View {
    let file: LocalMedia
    var artwork = ""

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(urlString: artwork, title: file.name)
                .scaledToFill().frame(width: 56, height: 78).clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)).allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                Text(file.name)
                    .font(.scaled(15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Image(systemName: AppIcon.play.name)
                .font(.scaled(12, weight: .bold))
                .foregroundStyle(Theme.onPrimary)
                .frame(width: 34, height: 34)
                .background(Theme.gold, in: Circle())
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        let size = formatSize(file.size)
        if !size.isEmpty { parts.append(size) }
        if file.modified != .distantPast { parts.append(file.modified.formatted(date: .numeric, time: .omitted)) }
        return parts.joined(separator: "  ·  ")
    }
}

private extension View {
    /// 列表行：无背景、无分隔线、页面左右边距
    func plainRow(top: CGFloat, bottom: CGFloat) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: Theme.contentInset, bottom: bottom, trailing: Theme.contentInset))
    }
}
