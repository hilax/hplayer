import SwiftUI

/// 首页标签：推荐 / 动漫 / 片库 / 短剧 / Jable / MissAV 频道左右滑动切换（PagedHeaderContainer）。
/// 第一行频道栏始终固定在顶端；往上滑时第二行大搜索栏向上收起，右上角渐显紧凑搜索键。
/// 详情页走 HomeView 的公共导航栈，盖住频道区和底部胶囊栏。
struct HomeChannelsView: View {
    @Binding var channel: HomeChannel
    @Binding var catalogPreset: CatalogPreset?
    var onSearch: () -> Void
    var onBrowseLibrary: () -> Void

    /// 头部按钮转给对应频道：片库的「筛选」
    @State private var filterRequest = 0

    init(channel: Binding<HomeChannel>, catalogPreset: Binding<CatalogPreset?>,
         onSearch: @escaping () -> Void, onBrowseLibrary: @escaping () -> Void) {
        _channel = channel
        _catalogPreset = catalogPreset
        self.onSearch = onSearch
        self.onBrowseLibrary = onBrowseLibrary
    }

    var body: some View {
        Group {
            PagedHeaderContainer(pages: HomeChannel.allCases, selection: $channel, collapseStyle: .pinFirstRow) { collapseProgress in
                let compactProgress = min(max((collapseProgress - 0.35) / 0.45, 0), 1)
                let compactActive = compactProgress > 0.35
                ZStack(alignment: .trailing) {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                    HomeChannelBar(selection: $channel)
                        .padding(.leading, Theme.contentInset)
                        .padding(.trailing, Theme.contentInset + compactProgress * 34)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if compactProgress > 0.02 {
                        Button(action: onSearch) {
                            Image(appIconNamed: AppIcon.search.name)
                                .font(.scaled(19, weight: Theme.iconWeight))
                                .heroForeground()
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.88))
                        .scaleEffect(0.84 + 0.16 * compactProgress)
                        .opacity(compactProgress)
                        .allowsHitTesting(compactActive)
                        .accessibilityLabel("搜索")
                        .accessibilityIdentifier("\(searchIdentifier).compact")
                        .accessibilityHidden(!compactActive)
                        .padding(.trailing, 6)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home.heroBar")
            } secondRow: {
                ChannelSearchField(placeholder: searchPlaceholder, identifier: searchIdentifier, onSearch: onSearch,
                                   onFilter: filterAction, filterIdentifier: channel == .library ? "catalog.filter" : "home.filter")
                    .padding(.horizontal, Theme.contentInset)
            } content: { page in
                switch page {
                case .recommend:
                    HomeTab(onBrowseLibrary: onBrowseLibrary, onSearch: onSearch, onOpenCatalog: { kind, sort in
                        catalogPreset = CatalogPreset(kind: kind, sort: sort)
                        withAnimation(Motion.smooth) { channel = .library }
                    }, channel: $channel)
                case .anime:
                    AnimeCatalogView()
                case .library:
                    CatalogTab(onSearch: onSearch, preset: $catalogPreset, filterRequest: filterRequest)
                case .drama:
                    DramaTab()
                case .jable:
                    JableTab()
                case .missav:
                    MissAVTab()
                }
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: 头部随频道变化的部分

    private var searchPlaceholder: String {
        switch channel {
        case .recommend: return "搜索片库、动漫、网盘"
        case .anime: return "搜索动漫"
        case .library: return "搜索片库"
        case .drama: return "搜索片库、动漫、网盘"
        case .jable: return "搜索片库、动漫、网盘"
        case .missav: return "搜索片库、动漫、网盘"
        }
    }

    /// 保持各频道原来的标识，UI 测试按它找搜索入口
    private var searchIdentifier: String {
        switch channel {
        case .recommend: return "home.search"
        case .anime: return "anime.search"
        case .library: return "catalog.search"
        case .drama: return "drama.search"
        case .jable: return "jable.search"
        case .missav: return "missav.search"
        }
    }

    /// 「筛选」：推荐去片库频道，片库滚到筛选区；动漫、短剧不放
    private var filterAction: (() -> Void)? {
        switch channel {
        case .recommend: return { withAnimation(Motion.smooth) { channel = .library } }
        case .library: return { filterRequest += 1 }
        case .anime, .drama, .jable, .missav: return nil
        }
    }
}
