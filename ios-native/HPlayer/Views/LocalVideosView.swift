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
                    icon: AppIcon.device.name,
                    title: "还没有导入视频",
                    message: "从「文件」App 导入的视频保存在 HPlayer 里，也会出现在首页海报墙。",
                    actionTitle: "导入视频",
                    action: { showImporter = true }
                )
            } else {
                List {
                    PageIntroduction(eyebrow: "On this iPhone", title: "本机视频", subtitle: "\(localStore.files.count) 个视频", showsTitle: false)
                        .padding(.vertical, 16)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(Array(localStore.files.enumerated()), id: \.element.id) { index, file in
                        Button {
                            play(file)
                        } label: {
                            LocalVideoRow(file: file, artwork: metadataStore.metadataByMediaID[LibraryMedia(local: file).id]?.posterURL ?? "")
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                        .reveal(index)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .designScreen("local")
        // 导入入口只留一个：没有视频时用空状态里的按钮，有视频后用底部这一个
        .safeAreaInset(edge: .bottom) {
            if !localStore.files.isEmpty {
                VStack(spacing: 10) {
                    if localStore.isImporting { ProgressView("正在导入视频…").font(.caption) }
                    Button { showImporter = true } label: { Label("导入视频", systemImage: AppIcon.add.name) }
                        .buttonStyle(PrimaryActionStyle()).disabled(localStore.isImporting)
                }.padding(Theme.contentInset).background(Theme.pageBackground)
            }
        }
        .navigationTitle("本机视频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)).allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                Text(file.name)
                    .font(.system(size: 15, weight: .semibold))
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
                .font(.system(size: 12, weight: .bold))
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
