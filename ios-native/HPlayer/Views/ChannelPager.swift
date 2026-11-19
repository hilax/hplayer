import SwiftUI
import Combine

// MARK: - 顶部固定头 + 左右滑动分页

/// 首页四个频道（推荐 / 动漫 / 片库 / 短剧）、磁力四个分类（最新 / 专题 / 女优 / 最热）共用的骨架：
/// - 内容是左右滑动的分页（iOS 17+ 横向分页 ScrollView，iOS 16 退回系统分页 TabView）。页里的横滑货架、轮播优先接手指，从空白处滑才翻页；
/// - 顶部是盖在分页上面的两行：第一行分类条，第二行搜索框。往上滑时第一行跟着内容上移并淡出，
///   搜索框滑到屏幕顶端后固定住，下面的内容继续往上滚；固定后头部铺上页面底色；
/// - 每一页自己的滚动位置各记各的，换页时头部按那一页的位置显示。
///
/// 每一页要做两件事：内容最上面留出 `channelPageInsets.top` 的空白（头部盖在这里），
/// 给滚动内容加 `.tracksPageScroll()` 把滚动位置报上来。
enum PagedHeaderCollapseStyle {
    /// 向上滑时收起第一行，把第二行固定在状态栏下方（如磁力页）
    case hideFirstRow
    /// 向上滑时第一行始终固定在状态栏下方，第二行向上收起并淡出（如首页频道页）
    case pinFirstRow
}

struct PagedHeaderContainer<Page: Hashable, FirstRow: View, SecondRow: View, Content: View>: View {
    let pages: [Page]
    @Binding var selection: Page
    let collapseStyle: PagedHeaderCollapseStyle
    let firstRow: (CGFloat) -> FirstRow
    let secondRow: () -> SecondRow
    let content: (Page) -> Content
    /// 盖在分页上面、头部下面的内容（例如磁力页搜索结果）；有它时不显示分页
    var overlay: AnyView?

    /// 各页的滚动位置；只有头部订阅，页面本身不随滚动重算
    @State private var scroll = PageScrollState()
    /// 哪些页顶部有轮播氛围层（页里的 AmbientHeroSection 报上来）
    @State private var heroPages: Set<Page> = []

    init(pages: [Page], selection: Binding<Page>, overlay: AnyView? = nil,
         collapseStyle: PagedHeaderCollapseStyle = .hideFirstRow,
         @ViewBuilder firstRow: @escaping (CGFloat) -> FirstRow,
         @ViewBuilder secondRow: @escaping () -> SecondRow,
         @ViewBuilder content: @escaping (Page) -> Content) {
        self.pages = pages
        _selection = selection
        self.overlay = overlay
        self.collapseStyle = collapseStyle
        self.firstRow = firstRow
        self.secondRow = secondRow
        self.content = content
    }

    init(pages: [Page], selection: Binding<Page>, overlay: AnyView? = nil,
         collapseStyle: PagedHeaderCollapseStyle = .hideFirstRow,
         @ViewBuilder firstRow: @escaping () -> FirstRow,
         @ViewBuilder secondRow: @escaping () -> SecondRow,
         @ViewBuilder content: @escaping (Page) -> Content) {
        self.init(pages: pages, selection: selection, overlay: overlay, collapseStyle: collapseStyle,
                  firstRow: { _ in firstRow() }, secondRow: secondRow, content: content)
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
                            collapseStyle: collapseStyle, firstRow: firstRow, secondRow: secondRow)
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
                    .background(PagerBounceDisabler())
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
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
                    pageView(page, insets: insets)
                        .background(PagerBounceDisabler())
                        .tag(page)
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
        .environment(\.isChannelPageActive, page == selection)
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

/// 头部：支持「隐藏第一行固定第二行」或「固定第一行收起第二行」两种模式。
struct PagedHeader<FirstRow: View, SecondRow: View>: View {
    @ObservedObject var state: PageScrollState
    let key: AnyHashable
    let safeTop: CGFloat
    /// 当前页顶部有轮播氛围层：没收起时频道条白字、搜索框磨砂
    var onArtwork = false
    var collapseStyle: PagedHeaderCollapseStyle = .hideFirstRow
    let firstRow: (CGFloat) -> FirstRow
    let secondRow: () -> SecondRow

    static var rowHeight: CGFloat { 44 }
    static var spacing: CGFloat { 10 }
    static var searchHeight: CGFloat { 38 }
    /// 头部（不含状态栏）总高：第一行 + 间距 + 搜索框 + 下边距
    static var height: CGFloat { rowHeight + spacing + searchHeight + 10 }
    /// 固定第一行模式收起后的底栏高度（不含状态栏）：第一行 + 底部留白
    static var pinnedRowHeight: CGFloat { rowHeight + 6 }
    private var collapseDistance: CGFloat {
        switch collapseStyle {
        case .hideFirstRow: return Self.rowHeight + Self.spacing
        case .pinFirstRow: return Self.height - Self.pinnedRowHeight
        }
    }

    var body: some View {
        let distance = collapseDistance
        let offset = max(0, state.offsets[key] ?? 0)
        let collapse = min(offset, distance)
        let progress = distance > 0 ? collapse / distance : 0
        ZStack(alignment: .top) {
            // 收起后头部铺上页面底色，下面滚上来的内容不会透出来
            Theme.pageBackground
                .frame(height: safeTop + Self.height - collapse)
                .opacity(progress)
                .overlay(alignment: .bottom) {
                    Theme.hairline.frame(height: 0.5).opacity(progress >= 1 ? 1 : 0)
                }
                .allowsHitTesting(false)

            Group {
                switch collapseStyle {
                case .hideFirstRow:
                    VStack(spacing: Self.spacing) {
                        firstRow(progress)
                            .frame(height: Self.rowHeight)
                            .opacity(1 - progress)
                            .allowsHitTesting(progress < 0.5)
                        secondRow()
                            .frame(height: Self.searchHeight)
                    }
                    .offset(y: -collapse)

                case .pinFirstRow:
                    ZStack(alignment: .top) {
                        Color.clear
                            .frame(height: Self.spacing + Self.searchHeight + 4)
                            .overlay(alignment: .top) {
                                if progress < 0.95 {
                                    secondRow()
                                        .frame(height: Self.searchHeight)
                                        .padding(.top, Self.spacing)
                                        .offset(y: -collapse)
                                        .opacity(max(0.0, 1.0 - Double(progress) * 1.35))
                                }
                            }
                            .clipped()
                            .padding(.top, Self.rowHeight)
                            .allowsHitTesting(progress < 0.45)
                            .accessibilityHidden(progress >= 0.45)

                        firstRow(progress)
                            .frame(height: Self.rowHeight)
                    }
                }
            }
            .padding(.top, safeTop)
            .environment(\.onHeroArtwork, onArtwork && progress < 0.6)
            .animation(.easeInOut(duration: 0.2), value: onArtwork && progress < 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // 头部两行是固定高度（44 + 38），字号最多放到 xxxLarge（约 1.35 倍），再大会撑破
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
        guard (clamped <= 0 && old > 0) || abs(old - clamped) > 0.5 else { return }
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

private struct IsChannelPageActiveKey: EnvironmentKey {
    static let defaultValue = true
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

    /// 当前频道页正处于选中状态；切走后的常驻页面据此暂停后台轮播动画，避免多个离屏频道同时占用主线程和 GPU。
    var isChannelPageActive: Bool {
        get { self[IsChannelPageActiveKey.self] }
        set { self[IsChannelPageActiveKey.self] = newValue }
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

/// 关闭横向分页容器两端（首页/末页）的回弹越界，防止向右或向左拖出空白底色，同时保留 SwiftUI 自身分页 delegate。
private struct PagerBounceDisabler: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.onMovedToHierarchy = { [weak coordinator = context.coordinator] probe in
            coordinator?.attach(from: probe)
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.attach(from: uiView)
    }

    final class ProbeView: UIView {
        var onMovedToHierarchy: ((ProbeView) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onMovedToHierarchy?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMovedToHierarchy?(self)
        }
    }

    final class Coordinator {
        private weak var observedScrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var isEnforcing = false

        func attach(from probe: UIView) {
            guard let scrollView = nearestScrollView(from: probe) else { return }
            if observedScrollView !== scrollView {
                observations.removeAll()
                observedScrollView = scrollView
                observe(scrollView)
            }
            enforceNoHorizontalBounce()
        }

        private func nearestScrollView(from view: UIView) -> UIScrollView? {
            var cursor = view.superview
            while let current = cursor {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                cursor = current.superview
            }
            return nil
        }

        private func observe(_ scrollView: UIScrollView) {
            observations.append(scrollView.observe(\.bounces, options: [.new]) { [weak self] _, _ in
                self?.enforceNoHorizontalBounce()
            })
            observations.append(scrollView.observe(\.alwaysBounceHorizontal, options: [.new]) { [weak self] _, _ in
                self?.enforceNoHorizontalBounce()
            })
            if #available(iOS 17.4, *) {
                observations.append(scrollView.observe(\.bouncesHorizontally, options: [.new]) { [weak self] _, _ in
                    self?.enforceNoHorizontalBounce()
                })
            }
        }

        private func enforceNoHorizontalBounce() {
            guard !isEnforcing, let scrollView = observedScrollView else { return }
            isEnforcing = true
            defer { isEnforcing = false }
            if scrollView.bounces {
                scrollView.bounces = false
            }
            if scrollView.alwaysBounceHorizontal {
                scrollView.alwaysBounceHorizontal = false
            }
            if #available(iOS 17.4, *), scrollView.bouncesHorizontally {
                scrollView.bouncesHorizontally = false
            }
        }
    }
}
