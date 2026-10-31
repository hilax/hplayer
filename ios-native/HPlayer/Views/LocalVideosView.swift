import SwiftUI
import UniformTypeIdentifiers

/// 导入到 App 里的本地视频：播放、删除、继续导入。这些视频同时出现在首页海报墙。
struct LocalVideosView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore

    @State private var showImporter = false
    @State private var importError = ""
    @State private var playing: PlaybackQueue?

    var body: some View {
        Group {
            if localStore.files.isEmpty {
                EmptyStateView(
                    icon: "iphone",
                    title: "还没有导入视频",
                    message: "从「文件」App 导入的视频保存在 HPlayer 里，也会出现在首页海报墙。",
                    actionTitle: "导入视频",
                    action: { showImporter = true }
                )
            } else {
                List {
                    PageIntroduction(eyebrow: "On this iPhone", title: "本机视频", subtitle: "\(localStore.files.count) 个视频")
                        .padding(.vertical, 16)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    Button { showImporter = true } label: {
                        LibraryActionRow(symbol: "folder", title: "从「文件」导入", subtitle: "导入后，可直接在本机播放。")
                            .surfaceCard()
                    }.buttonStyle(.plain).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    ForEach(localStore.files) { file in
                        Button {
                            play(file)
                        } label: {
                            LocalVideoRow(file: file, artwork: metadataStore.metadataByMediaID[LibraryMedia(local: file).id]?.posterURL ?? "")
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                        .swipeActions {
                            Button(role: .destructive) {
                                localStore.delete(file)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("播放", systemImage: "play.fill") { play(file) }
                            Button("删除本地文件", systemImage: "trash", role: .destructive) {
                                localStore.delete(file)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("local")
        .safeAreaInset(edge: .bottom) {
            Button { showImporter = true } label: { Label("导入视频", systemImage: "plus") }
                .buttonStyle(PrimaryActionStyle()).padding(Theme.contentInset).background(Theme.pageBackground)
        }
        .navigationTitle("本机视频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("导入视频")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                localStore.importFiles(urls)
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
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items)
                .environmentObject(appState)
        }
        .task { localStore.refresh() }
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
                .clipShape(RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                Text(file.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Image(systemName: "play.circle").font(.title3).foregroundStyle(Theme.accent)
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
