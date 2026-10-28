import SwiftUI
import UniformTypeIdentifiers

struct HomeTab: View {
    @EnvironmentObject private var recents: RecentStore
    @StateObject private var localStore = LocalMediaStore()

    @State private var showImporter = false
    @State private var playing: PlaybackQueue?
    @State private var importError = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("本地")
                        .font(.system(size: 40, weight: .bold))
                        .padding(.top, 8)

                    if localStore.files.isEmpty {
                        emptyState
                    } else {
                        localList
                    }

                    if !recents.items.isEmpty {
                        recentSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }

                    Button {
                        if let first = localStore.files.first {
                            playLocal(first)
                        }
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .disabled(localStore.files.isEmpty)

                    Menu {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            localStore.refresh()
                        }
                        Button("清空最近播放", systemImage: "clock.arrow.circlepath", role: .destructive) {
                            recents.clear()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
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
            .fullScreenCover(item: $playing) { queue in
                PlayerView(source: queue.source, playlist: queue.items)
                    .environmentObject(recents)
            }
            .alert("导入失败", isPresented: Binding(
                get: { !importError.isEmpty },
                set: { if !$0 { importError = "" } }
            )) {
                Button("好", role: .cancel) { importError = "" }
            } message: {
                Text(importError)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)

            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(Theme.accentGradient)

            Text("还没有本地视频")
                .font(.headline)

            Text("从「文件」App 导入视频，或直接在首页粘贴网络地址播放")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            GlassCapsuleButton(
                title: "文件管理导入",
                systemImage: "folder.badge.plus",
                prominent: true
            ) {
                showImporter = true
            }
            .padding(.top, 6)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var localList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "视频")

            ForEach(localStore.files) { media in
                Button {
                    playLocal(media)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(media.name)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(formatSize(media.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 20)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        localStore.delete(media)
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近播放")

            ForEach(recents.items) { item in
                Button {
                    if let url = URL(string: item.url) {
                        let source = PlaybackSource.direct(title: item.title, url: url)
                        playing = PlaybackQueue(source: source, items: [source])
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(item.url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .glassCard(cornerRadius: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func playLocal(_ media: LocalMedia) {
        let source = PlaybackSource.direct(title: media.name, url: media.url)
        let items = localStore.files.map { PlaybackSource.direct(title: $0.name, url: $0.url) }
        playing = PlaybackQueue(source: source, items: items)
    }
}
