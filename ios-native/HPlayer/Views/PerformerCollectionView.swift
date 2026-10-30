import SwiftUI

/// 某位演员的全部影片合集，从首页「演员合集」进入。
struct PerformerCollectionView: View {
    let name: String

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mediaLibrary: MediaLibraryStore
    @EnvironmentObject private var localStore: LocalMediaStore
    @EnvironmentObject private var metadataStore: MediaMetadataStore
    @State private var playing: PlaybackQueue?

    var body: some View {
        let snapshot = HomeLibrary.snapshot(local: localStore, cloud: mediaLibrary, metadata: metadataStore, appState: appState)
        let items = snapshot.performers.first { $0.name == name }?.items ?? []
        Group {
            if items.isEmpty {
                EmptyStateView(icon: "person.2", title: "这个合集已经没有影片",
                               message: "可能影片被移除，或重新匹配成了别的作品。")
            } else {
                PosterGridScreen(title: name, items: items) { item, width in
                    Button {
                        playing = PlaybackQueue(source: item.media.source, items: items.map { $0.media.source })
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            PosterArtwork(urlString: item.posterURL, title: item.title, width: width, alignment: .trailing)
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(width: width, alignment: .leading)
                        }
                    }
                    .buttonStyle(PosterButtonStyle())
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
    }
}
