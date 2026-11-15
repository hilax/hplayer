import SwiftUI
import Combine

// MARK: - 顶部固定头 + 左右滑动分页

/// 首页四个频道（推荐 / 动漫 / 片库 / 短剧）、磁力四个分类（最新 / 专题 / 女优 / 最热）共用的骨架：
/// - 内容是左右滑动的分页（iOS 17+ 横向分页 ScrollView，iOS 16 退回系统分页 TabView）。页里的横滑货架、轮播优先接手指，从空白处滑才翻页；
/// - 顶部是盖在分页上面的两行：第一行分类条，第二行搜索框。往上滑时第一行跟着内容上移并淡出，
///   搜索框滑到屏幕顶端后固定住，下面的内容继续往上滚；固定后头部铺上页面底色；
/// - 每一页自己的滚动位置各记各的，换页时头部按那一页的位置显示。
///
/// 首页用 `.searchFirst` 布局（见 PagedHeaderLayout）：搜索框在上、频道条在下，往上滑搜索框收起、
/// 频道条钉在顶端，往下滑一点搜索框就回来。磁力页仍是默认布局。
///
/// 每一页要做两件事：内容最上面留出 `channelPageInsets.top` 的空白（头部盖在这里），
/// 给滚动内容加 `.tracksPageScroll()` 把滚动位置报上来。
struct PagedHeaderContainer<Page: Hashable, FirstRow: View, SecondRow: View, Content: View>: View {
    let pages: [Page]
    @Binding var selection: Page
    let firstRow: () -> FirstRow
    let secondRow: () -> SecondRow
    let content: (Page) -> Content
    /// 盖在分页上面、头部下面的内容（例如磁力页搜索结果）；有它时不显示分页
    var overlay: AnyView?
    var layout: PagedHeaderLayout = .categoriesFirst

    /// 各页的滚动位置；只有头部订阅，页面本身不随滚动重算
    @State private var scroll = PageScrollState()
    /// 哪些页顶部有轮播氛围层（页里的 AmbientHeroSection 报上来）
    @State private var heroPages: Set<Page> = []

    init(pages: [Page], selection: Binding<Page>, overlay: AnyView? = nil,
         layout: PagedHeaderLayout = .categoriesFirst,
         @ViewBuilder firstRow: @escaping () -> FirstRow,
         @ViewBuilder secondRow: @escaping () -> SecondRow,
         @ViewBuilder content: @escaping (Page) -> Content) {
        self.pages = pages
        _selection = selection
        self.overlay = overlay
        self.layout = layout
        self.firstRow = firstRow
        self.secondRow = secondRow
        self.content = content
    }

    /// iOS 17+ 用横向分页 ScrollView 记当前页（和 selection 双向同步）
    @State private var position: Page?
    /// 去过的页和当前页左右两页才建内容；建过的一直留着（滚动位置、已加载的数据不丢）
    @State private var visited: Set<Page> = []

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let insets = ChannelPageInsets(safeTop: safeTop, top: safeTop + PagedHeader<FirstRow, SecondRow>.height)
            ZStack(alignment: .top) {
                pager(insets: insets, width: proxy.size.width)
                    .opacity(overlay == nil ? 1 : 0)
                    .allowsHitTesting(overlay == nil)
                    .accessibilityHidden(overlay != nil)

                if let overlay {
                    overlay
                        .environment(\.channelPageInsets, insets)
                        .environment(\.pageScrollReporter, PageScrollReporter(state: scroll, key: AnyHashable(Self.overlayKey)))
                        .background(Theme.pageBackground.ignoresSafeArea())
                }

                PagedHeader(state: scroll, key: overlay == nil ? AnyHashable(selection) : AnyHashable(Self.overlayKey),
                            safeTop: safeTop, onArtwork: overlay == nil && heroPages.contains(selection),
                            layout: layout, firstRow: firstRow, secondRow: secondRow)
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear { markVisited(selection) }
        .onChange(of: selection) { value in markVisited(value) }
    }

    private static var overlayKey: String { "paged.overlay" }

    @ViewBuilder
    private func pager(insets: ChannelPageInsets, width: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            // 纯 SwiftUI 的横向分页：安全区、滚动位置都按普通 ScrollView 走（系统分页 TabView 里页面的
            // 顶部安全区和滚动回报都不可靠，内容会往下错位、头部收不起来）。
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(pages, id: \.self) { page in
                            pageView(page, insets: insets)
                                .containerRelativeFrame(.horizontal)
                                .id(page)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollPosition(id: $position)
                .ignoresSafeArea(edges: .top)
                .onAppear { position = selection }
                .onChange(of: selection) { value in
                    guard position != value else { return }
                    withAnimation(Motion.smooth) { position = value }
                }
                .onChange(of: position) { value in
                    if let value, value != selection { selection = value }
                }
                // 播放器横屏时主窗口被藏起来、跟着场景转成横的再转回来，宽度变了以后
                // 横向滚动停在两页中间（露出半个旁边的频道）。宽度一变、主窗口重新露出来，都对齐回当前页。
                .onChange(of: width) { _ in realign(reader) }
                .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeVisibleNotification)) { _ in
                    realign(reader)
                }
            }
        } else {
            TabView(selection: $selection) {
                ForEach(pages, id: \.self) { page in
                    pageView(page, insets: insets).tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder
    private func pageView(_ page: Page, insets: ChannelPageInsets) -> some View {
        Group {
            if visited.contains(page) || isNeighbour(page) {
                content(page)
            } else {
                Theme.pageBackground
            }
        }
        .environment(\.channelPageInsets, insets)
        .environment(\.pageScrollReporter, PageScrollReporter(state: scroll, key: AnyHashable(page)))
        .onPreferenceChange(AmbientHeroPresenceKey.self) { hasHero in
            if hasHero { heroPages.insert(page) } else { heroPages.remove(page) }
        }
    }

    /// 不带动画地把横向分页对齐到当前页；等这一轮布局结束再对齐，宽度才是新的
    private func realign(_ reader: ScrollViewProxy) {
        let target = selection
        for delay in [0.0, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    reader.scrollTo(target, anchor: .leading)
                    position = target
                }
            }
        }
    }

    private func isNeighbour(_ page: Page) -> Bool {
        guard let a = pages.firstIndex(of: page), let b = pages.firstIndex(of: selection) else { return false }
        return abs(a - b) <= 1
    }

    private func markVisited(_ page: Page) {
        guard !visited.contains(page) else { return }
        visited.insert(page)
    }
}

/// 头部两行怎么排、怎么收
enum PagedHeaderLayout {
    /// 分类条在上、搜索框在下：滚动 0～54pt 时整体上移、分类条淡出；之后搜索框固定在顶端（磁力页）
    case categoriesFirst
    /// 搜索框在上、分类条在下（首页，和 B 站首页一样）：往上滑搜索框跟着手指收起、分类条钉在状态栏下面；
    /// 往下滑一点（不用回到顶部）搜索框就跟着手指回来；停在半路时吸附到全收或全开
    case searchFirst
}

/// 头部：分类条 + 搜索框，按 PagedHeaderLayout 排列和收起。
struct PagedHeader<FirstRow: View, SecondRow: View>: View {
    @ObservedObject var state: PageScrollState
    let key: AnyHashable
    let safeTop: CGFloat
    /// 当前页顶部有轮播氛围层：没收起时频道条白字、搜索框磨砂
    var onArtwork = false
    var layout: PagedHeaderLayout = .categoriesFirst
    let firstRow: () -> FirstRow
    let secondRow: () -> SecondRow

    static var rowHeight: CGFloat { 44 }
    static var spacing: CGFloat { 10 }
    static var searchHeight: CGFloat { 38 }
    /// 头部（不含状态栏）总高：第一行 + 间距 + 搜索框 + 下边距
    static var height: CGFloat { rowHeight + spacing + searchHeight + 10 }
    /// 收起的距离：第一行和它下面的间距
    static var collapseDistance: CGFloat { rowHeight + spacing }
    /// searchFirst 布局里搜索框上面留的空（总高和默认布局一样，内容的上边距不用变）
    static var searchTopPadding: CGFloat { PagedHeaderLimits.quickReturnDistance - searchHeight - spacing }

    var body: some View {
        switch layout {
        case .categoriesFirst: categoriesFirstBody
        case .searchFirst: searchFirstBody
        }
    }

    /// 搜索框在上：收起量按滚动方向累加（PageScrollState.collapses），不是按离顶部多远
    private var searchFirstBody: some View {
        let distance = PagedHeaderLimits.quickReturnDistance
        let offset = max(0, state.offsets[key] ?? 0)
        // 底色按内容滚上来多少铺：搜索框中途回来时下面已经有内容，底色要在
        let scrolled = min(offset / distance, 1)
        let collapse = min(max(state.collapses[key] ?? 0, 0), distance)
        let progress = collapse / distance
        return ZStack(alignment: .top) {
            Theme.pageBackground
                .frame(height: safeTop + Self.height - collapse)
                .opacity(scrolled)
                .overlay(alignment: .bottom) {
                    Theme.hairline.frame(height: 0.5).opacity(scrolled >= 1 ? 1 : 0)
                }
                .allowsHitTesting(false)

            VStack(spacing: Self.spacing) {
                secondRow()
                    .frame(height: Self.searchHeight)
                    // 比位移淡得快一点：收到一半时已经看不见，不会压在状态栏的字上
                    .opacity(1 - min(progress * 1.6, 1))
                    .scaleEffect(1 - progress * 0.06, anchor: .bottom)
                    .allowsHitTesting(progress < 0.5)
                    .accessibilityHidden(progress >= 1)
                firstRow()
                    .frame(height: Self.rowHeight)
            }
            .padding(.top, safeTop + Self.searchTopPadding)
            .offset(y: -collapse)
            .environment(\.pagedHeaderCollapse, progress)
            .environment(\.onHeroArtwork, onArtwork && scrolled < 0.6)
            .animation(.easeInOut(duration: 0.2), value: onArtwork && scrolled < 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var categoriesFirstBody: some View {
        let offset = max(0, state.offsets[key] ?? 0)
        let collapse = min(offset, Self.collapseDistance)
        let progress = collapse / Self.collapseDistance
        return ZStack(alignment: .top) {
            // 收起后头部铺上页面底色，下面滚上来的内容不会从搜索框后面透出来
            Theme.pageBackground
                .frame(height: safeTop + Self.height - collapse)
                .opacity(progress)
                .overlay(alignment: .bottom) {
                    Theme.hairline.frame(height: 0.5).opacity(progress >= 1 ? 1 : 0)
                }
                .allowsHitTesting(false)

            VStack(spacing: Self.spacing) {
                firstRow()
                    .frame(height: Self.rowHeight)
                    .opacity(1 - progress)
                    .allowsHitTesting(progress < 0.5)
                secondRow()
                    .frame(height: Self.searchHeight)
            }
            .padding(.top, safeTop)
            .offset(y: -collapse)
            .environment(\.onHeroArtwork, onArtwork && progress < 0.6)
            .animation(.easeInOut(duration: 0.2), value: onArtwork && progress < 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// 各页的滚动距离（向上滚为正）
final class PageScrollState: ObservableObject {
    @Published var offsets: [AnyHashable: CGFloat] = [:]
    /// searchFirst 布局：各页搜索框收起了多少（0～quickReturnDistance）。按滚动方向累加：
    /// 往上滑加、往下滑减，所以不用回到顶部、往下滑一点就展开。只有变化时才发布，
    /// 一直往同一个方向滚长列表时（已经全收或全开）头部不跟着每帧重算
    @Published var collapses: [AnyHashable: CGFloat] = [:]
    /// 上一次报上来的完整滚动距离（不发布）
    private var lastOffsets: [AnyHashable: CGFloat] = [:]
    private var snapTask: Task<Void, Never>?

    func trackQuickReturn(key: AnyHashable, offset: CGFloat) {
        let distance = PagedHeaderLimits.quickReturnDistance
        let last = lastOffsets[key] ?? offset
        lastOffsets[key] = offset
        let old = collapses[key] ?? 0
        var value: CGFloat
        if offset <= 0 {
            value = 0  // 在顶部或下拉回弹：全开
        } else {
            // 跟着这一帧的位移走，但收起量不超过已经滚上去的距离（靠近顶部时不会提前收）
            value = min(max(old + (offset - last), 0), distance, offset)
        }
        if value != old, abs(value - old) > 0.5 || value == 0 || value == distance {
            collapses[key] = value
        }
        // 停在半路：一会儿没再滚就吸附到全收或全开
        snapTask?.cancel()
        guard value > 0, value < distance else { return }
        snapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, !Task.isCancelled, let current = self.collapses[key],
                  current > 0, current < distance else { return }
            let scrolled = self.lastOffsets[key] ?? 0
            let target: CGFloat = current > distance / 2 && scrolled >= distance ? distance : 0
            withAnimation(.easeOut(duration: 0.2)) { self.collapses[key] = target }
        }
    }
}

struct PageScrollReporter {
    let state: PageScrollState
    let key: AnyHashable

    func report(_ offset: CGFloat) {
        state.trackQuickReturn(key: key, offset: offset)
        // 收起只看前 60pt，再往下的变化不发布，滚长列表时头部不跟着每帧重算
        let clamped = min(max(offset, -1), PagedHeaderLimits.trackLimit)
        let old = state.offsets[key] ?? 0
        guard abs(old - clamped) > 0.5 else { return }
        state.offsets[key] = clamped
    }
}

enum PagedHeaderLimits {
    static let trackLimit: CGFloat = 60
    /// searchFirst 布局里搜索框收起的距离：搜索框上方留白 + 搜索框 + 下面的间距（分类条刚好顶到状态栏下）
    static let quickReturnDistance: CGFloat = 52
}

/// searchFirst 布局里搜索框收起了多少（0 全开 ～ 1 全收）。分类条那一行用它淡入收起后的放大镜
private struct PagedHeaderCollapseKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// 分页内容的上边距：safeTop 是状态栏高度，top 是内容要从哪里开始（头部下沿）
struct ChannelPageInsets: Equatable {
    var safeTop: CGFloat = 0
    var top: CGFloat = 0
}

private struct ChannelPageInsetsKey: EnvironmentKey {
    static let defaultValue = ChannelPageInsets()
}

private struct PageScrollReporterKey: EnvironmentKey {
    static let defaultValue: PageScrollReporter? = nil
}

extension EnvironmentValues {
    var channelPageInsets: ChannelPageInsets {
        get { self[ChannelPageInsetsKey.self] }
        set { self[ChannelPageInsetsKey.self] = newValue }
    }

    var pageScrollReporter: PageScrollReporter? {
        get { self[PageScrollReporterKey.self] }
        set { self[PageScrollReporterKey.self] = newValue }
    }

    var pagedHeaderCollapse: CGFloat {
        get { self[PagedHeaderCollapseKey.self] }
        set { self[PagedHeaderCollapseKey.self] = newValue }
    }
}

extension View {
    /// 放在分页里那个纵向 ScrollView 上：iOS 18+ 直接读滚动距离报给顶部头部；
    /// 更早的系统给 ScrollView 起一个坐标系，由内容上的 `.tracksPageScroll()` 量。
    @ViewBuilder
    func pageScrollContainer() -> some View {
        if #available(iOS 18.0, *) {
            modifier(PageScrollGeometryTracker())
        } else {
            coordinateSpace(name: PageScrollSpace.name)
        }
    }

    /// 放在分页里那个纵向 ScrollView 的内容上（iOS 17 及更早用；iOS 18+ 由 `pageScrollContainer()` 负责）。
    func tracksPageScroll() -> some View { modifier(PageScrollTracker()) }
}

enum PageScrollSpace {
    static let name = "paged.scroll"
}

@available(iOS 18.0, *)
private struct PageScrollGeometryTracker: ViewModifier {
    @Environment(\.pageScrollReporter) private var reporter

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            reporter?.report(offset)
        }
    }
}

private struct PageScrollTracker: ViewModifier {
    @Environment(\.pageScrollReporter) private var reporter

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content
                .background(alignment: .top) {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PageScrollOffsetKey.self,
                                               value: proxy.frame(in: .named(PageScrollSpace.name)).minY)
                    }
                    .frame(height: 0)
                }
                .onPreferenceChange(PageScrollOffsetKey.self) { minY in
                    reporter?.report(-minY)
                }
        }
    }
}

private struct PageScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
