import SwiftUI

struct PerformerRoute: Hashable {
    let id: String
    let name: String
}

/// Value-based navigation keeps every lazy-list row tied to its own actor id.
/// Destination-closure links can be recycled across cells in horizontal lazy
/// stacks and open the previous actor's page.
struct PerformerNavigationLink<Label: View>: View {
    let route: PerformerRoute
    let label: () -> Label

    init(group: PerformerGroup, @ViewBuilder label: @escaping () -> Label) {
        route = PerformerRoute(id: group.id, name: group.name)
        self.label = label
    }

    var body: some View {
        NavigationLink(value: route) {
            label()
        }
        .id(route.id)
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
            .accessibilityIdentifier("performer.work.\(item.metadata?.imdbID ?? item.id)")
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .id(group.id)
        .fullScreenCover(item: $playing) { queue in
            PlayerView(source: queue.source, playlist: queue.items).environmentObject(appState)
        }
    }
}
