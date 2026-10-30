import SwiftUI

/// 某位演员的全部影片合集，从首页「演员合集」或搜索结果进入。
/// 影片列表在进入时取一份，页面停留期间不跟着后台匹配实时刷新（避免整页重算）。
struct PerformerCollectionView: View {
    let group: PerformerGroup

    @EnvironmentObject private var appState: AppState
    @State private var playing: PlaybackQueue?

    var body: some View {
        PosterGridScreen(title: group.name, items: group.items) { item, width in
            Button {
                playing = PlaybackQueue(source: item.media.source, items: group.items.map { $0.media.source })
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    PosterArtwork(urlString: item.posterURL, title: item.title, width: width,
                                  alignment: item.metadata?.isWideJacket == true ? .trailing : .center)
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(width: width, alignment: .leading)
                }
            }
            .buttonStyle(PosterButtonStyle())
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
    }
}
