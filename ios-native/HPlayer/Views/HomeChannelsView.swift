import SwiftUI

/// 首页标签：推荐 / 动漫 / 片库 / 短剧四个频道左右滑动切换（PagedHeaderContainer）。
/// 搜索框和频道条是盖在上面的固定头部（搜索框在上、频道条在下，PagedHeaderLayout.searchFirst）：
/// 往上滑时搜索框跟着手指收起、频道条钉在状态栏下面，频道条右侧淡入放大镜；往下滑一点搜索框就回来。
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
            PagedHeaderContainer(pages: HomeChannel.allCases, selection: $channel, layout: .searchFirst) {
                HStack(spacing: 4) {
                    HomeChannelBar(selection: $channel)
                    Spacer(minLength: 8)
                    if channel == .recommend {
                        Button { addRequest += 1 } label: {
                            Image(systemName: AppIcon.addCircle.name)
                                .font(.scaled(20, weight: Theme.iconWeight))
                                .heroForeground()
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.88))
                        .accessibilityLabel("添加")
                        .accessibilityIdentifier("home.sources")
                        .transition(.opacity)
                    }
                    // 搜索框收起后，搜索入口挪到频道条最右边
                    CollapsedSearchButton(identifier: searchIdentifier + ".collapsed", action: onSearch)
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

/// 头部搜索框收起后出现在频道条右侧的放大镜：跟着收起程度淡入，点了和点搜索框一样。
/// 一直占着位置，频道条不会因为它出现、消失而左右挪动。
private struct CollapsedSearchButton: View {
    @Environment(\.pagedHeaderCollapse) private var progress
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: AppIcon.search.name)
                .font(.scaled(19, weight: Theme.iconWeight))
                .heroForeground()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .opacity(progress)
        .scaleEffect(0.8 + 0.2 * progress)
        .allowsHitTesting(progress > 0.5)
        .accessibilityHidden(progress < 0.5)
        .accessibilityLabel("搜索")
        .accessibilityIdentifier(identifier)
    }
}
