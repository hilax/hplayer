import SwiftUI
import Combine

// MARK: - 顶部固定头 + 左右滑动分页

/// 首页四个频道（推荐 / 动漫 / 片库 / 短剧）、磁力四个分类（最新 / 专题 / 女优 / 最热）共用的骨架：
/// - 内容是左右滑动的分页（系统分页 TabView）。页里的横滑货架、轮播优先接手指，从空白处滑才翻页；
/// - 顶部是盖在分页上面的两行：第一行分类条，第二行搜索框。往上滑时第一行跟着内容上移并淡出，
///   搜索框滑到屏幕顶端后固定住，下面的内容继续往上滚；固定后头部铺上页面底色；
/// - 每一页自己的滚动位置各记各的，换页时头部按那一页的位置显示。
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

    /// 各页的滚动位置；只有头部订阅，页面本身不随滚动重算
    @State private var scroll = PageScrollState()

    init(pages: [Page], selection: Binding<Page>, overlay: AnyView? = nil,
         @ViewBuilder firstRow: @escaping () -> FirstRow,
         @ViewBuilder secondRow: @escaping () -> SecondRow,
         @ViewBuilder content: @escaping (Page) -> Content) {
        self.pages = pages
        _selection = selection
        self.overlay = overlay
        self.firstRow = firstRow
        self.secondRow = secondRow
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let insets = ChannelPageInsets(safeTop: safeTop, top: safeTop + PagedHeader<FirstRow, SecondRow>.height)
            ZStack(alignment: .top) {
                TabView(selection: $selection) {
                    ForEach(pages, id: \.self) { page in
                        content(page)
                            .environment(\.channelPageInsets, insets)
                            .environment(\.pageScrollReporter, PageScrollReporter(state: scroll, key: AnyHashable(page)))
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // 只往上铺到状态栏后面；底部留给系统标签栏的安全区，最后一行内容不会被标签栏挡住
                .ignoresSafeArea(edges: .top)
                .opacity(overlay == nil ? 1 : 0)
                .allowsHitTesting(overlay == nil)

                if let overlay {
                    overlay
                        .environment(\.channelPageInsets, insets)
                        .environment(\.pageScrollReporter, PageScrollReporter(state: scroll, key: AnyHashable("overlay")))
                        .background(Theme.pageBackground.ignoresSafeArea())
                }

                PagedHeader(state: scroll, key: overlay == nil ? AnyHashable(selection) : AnyHashable("overlay"),
                            safeTop: safeTop, firstRow: firstRow, secondRow: secondRow)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// 头部：分类条 + 搜索框。滚动 0～54pt 时整体上移、第一行淡出；之后搜索框固定在顶端。
struct PagedHeader<FirstRow: View, SecondRow: View>: View {
    @ObservedObject var state: PageScrollState
    let key: AnyHashable
    let safeTop: CGFloat
    let firstRow: () -> FirstRow
    let secondRow: () -> SecondRow

    static var rowHeight: CGFloat { 44 }
    static var spacing: CGFloat { 10 }
    static var searchHeight: CGFloat { 38 }
    /// 头部（不含状态栏）总高：第一行 + 间距 + 搜索框 + 下边距
    static var height: CGFloat { rowHeight + spacing + searchHeight + 10 }
    /// 收起的距离：第一行和它下面的间距
    static var collapseDistance: CGFloat { rowHeight + spacing }

    var body: some View {
        let offset = max(0, state.offsets[key] ?? 0)
        let collapse = min(offset, Self.collapseDistance)
        let progress = collapse / Self.collapseDistance
        ZStack(alignment: .top) {
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
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// 各页的滚动距离（向上滚为正）
final class PageScrollState: ObservableObject {
    @Published var offsets: [AnyHashable: CGFloat] = [:]
}

struct PageScrollReporter {
    let state: PageScrollState
    let key: AnyHashable

    func report(_ offset: CGFloat) {
        // 收起只看前 60pt，再往下的变化不发布，滚长列表时头部不跟着每帧重算
        let clamped = min(max(offset, -1), PagedHeaderLimits.trackLimit)
        let old = state.offsets[key] ?? 0
        guard abs(old - clamped) > 0.5 else { return }
        state.offsets[key] = clamped
    }
}

enum PagedHeaderLimits {
    static let trackLimit: CGFloat = 60
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
}

extension View {
    /// 放在分页里那个纵向 ScrollView 的内容上：把滚动距离报给顶部头部。
    /// ScrollView 要忽略顶部安全区（内容从屏幕最顶上开始），这里按内容顶边在屏幕上的位置算。
    func tracksPageScroll() -> some View { modifier(PageScrollTracker()) }
}

private struct PageScrollTracker: ViewModifier {
    @Environment(\.pageScrollReporter) private var reporter

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                GeometryReader { proxy in
                    Color.clear.preference(key: PageScrollOffsetKey.self, value: proxy.frame(in: .global).minY)
                }
                .frame(height: 0)
            }
            .onPreferenceChange(PageScrollOffsetKey.self) { minY in
                reporter?.report(-minY)
            }
    }
}

private struct PageScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
