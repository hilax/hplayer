import SwiftUI

/// 我的追番：在详情页点过「追番」的作品。有新一集的排在前面并带「更新」角标。
struct AnimeWatchlistView: View {
    @ObservedObject private var store = AnimeWatchlistStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var sorted: [AnimeWatchItem] {
        store.items.sorted { lhs, rhs in
            if lhs.hasUpdate != rhs.hasUpdate { return lhs.hasUpdate }
            return lhs.savedDate > rhs.savedDate
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: sizeClass == .regular ? 5 : 3)
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                EmptyStateView(icon: AppIcon.heart.name, title: "还没有追番",
                               message: "在动漫详情页点「追番」，有新一集时会在这里和首页提醒你。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(sorted) { item in
                            AnimeDetailLink(animeId: item.id) { card(item) }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        withAnimation(Motion.smooth) { store.remove(id: item.id) }
                                    } label: {
                                        Label("取消追番", systemImage: AppIcon.heart.name)
                                    }
                                }
                                .accessibilityIdentifier("watchlist.item.\(item.id)")
                        }
                    }
                    .padding(.horizontal, Theme.contentInset)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("我的追番")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("watchlist")
    }

    private func card(_ item: AnimeWatchItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                PosterArtwork(urlString: item.pic ?? "", title: item.name, width: proxy.size.width)
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if item.hasUpdate {
                    Text("更新")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.brandNight)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(6)
                }
            }
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(item.lastContinu ?? "在线动漫")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }
}
