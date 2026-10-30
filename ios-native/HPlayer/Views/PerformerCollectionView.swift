import SwiftUI

/// A value-safe entry point for performer collections. Giving every destination
/// its actor id prevents SwiftUI from reusing the previous actor's page.
struct PerformerNavigationLink<Label: View>: View {
    let group: PerformerGroup
    let label: () -> Label

    init(group: PerformerGroup, @ViewBuilder label: @escaping () -> Label) {
        self.group = group
        self.label = label
    }

    var body: some View {
        NavigationLink {
            PerformerCollectionView(group: group)
                .id(group.id)
        } label: {
            label()
        }
        .id(group.id)
    }
}

/// 某位演员的全部影片合集，从首页「演员合集」或搜索结果进入。
/// 影片列表在进入时取一份，页面停留期间不跟着后台匹配实时刷新（避免整页重算）。
struct PerformerCollectionView: View {
    let group: PerformerGroup

    @EnvironmentObject private var appState: AppState
    @State private var playing: PlaybackQueue?

    private var items: [HomeMediaItem] { group.collectionItems }

    var body: some View {
        PosterGridScreen(title: group.name, items: items) { item, width in
            Button {
                playing = PlaybackQueue(source: item.media.source, items: items.map { $0.media.source })
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
        .id(group.id)
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
    }
}
