import SwiftUI

/// 首页标签：推荐 / 动漫 / 片库 / 短剧四个频道左右滑动切换（PagedHeaderContainer）。
/// 频道条和搜索框是盖在上面的固定头部：往上滑时频道条淡出，搜索框固定在顶端。
/// 详情页走 HomeView 的公共导航栈，盖住频道区和底部胶囊栏。
struct HomeChannelsView: View {
    @Binding var channel: HomeChannel
    @Binding var catalogPreset: CatalogPreset?
    var onSearch: () -> Void
    var onBrowseLibrary: () -> Void

    /// 头部按钮转给对应频道：推荐的「添加」、片库的「筛选」
    @State private var addRequest = 0
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
            PagedHeaderContainer(pages: HomeChannel.allCases, selection: $channel) {
                HStack(spacing: 4) {
                    HomeChannelBar(selection: $channel)
                    Spacer(minLength: 8)
                    if channel == .recommend {
                        Button { addRequest += 1 } label: {
                            Image(systemName: AppIcon.addCircle.name)
                                .font(.system(size: 20, weight: Theme.iconWeight))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.88))
                        .accessibilityLabel("添加")
                        .accessibilityIdentifier("home.sources")
                        .transition(.opacity)
                    }
                }
                .padding(.leading, Theme.contentInset)
                .padding(.trailing, 6)
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
                    }, channel: $channel, addRequest: addRequest)
                case .anime:
                    AnimeCatalogView()
                case .library:
                    CatalogTab(onSearch: onSearch, preset: $catalogPreset, filterRequest: filterRequest)
                case .drama:
                    DramaTab()
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
        }
    }

    /// 保持各频道原来的标识，UI 测试按它找搜索入口
    private var searchIdentifier: String {
        switch channel {
        case .recommend: return "home.search"
        case .anime: return "anime.search"
        case .library: return "catalog.search"
        case .drama: return "drama.search"
        }
    }

    /// 「筛选」：推荐去片库频道，片库滚到筛选区；动漫、短剧不放
    private var filterAction: (() -> Void)? {
        switch channel {
        case .recommend: return { withAnimation(Motion.smooth) { channel = .library } }
        case .library: return { filterRequest += 1 }
        case .anime, .drama: return nil
        }
    }
}
