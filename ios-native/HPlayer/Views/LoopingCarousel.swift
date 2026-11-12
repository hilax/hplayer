import SwiftUI

/// 顶部轮播（首页「推荐」、动漫频道共用）：首尾相接，可以手动左右滑，也会每隔几秒自动翻到下一张。
///
/// 自动翻页只在用户「看得见、没在碰」的时候走：
/// - 打开「减弱动态效果」时不自动翻；
/// - 手指正按着 / 正在拖轮播时暂停（iOS 18 起按滚动阶段判断）；
/// - 轮播滑出屏幕、切到别的标签或推进下一页、App 进后台时暂停；
/// - 手动翻过一页，计时从头开始。
///
/// 循环：首尾各多放一张复制页（见 HeroLoop），停在复制页上就无动画换回真的那页，看起来一直往前翻。
/// 每一页由调用方画，`isCurrent` 告诉它是不是当前页；非当前页对辅助功能隐藏，同一个按钮不会出现两次。
struct LoopingCarousel<Item: Identifiable, Page: View>: View {
    let items: [Item]
    /// 自动翻页间隔（秒）
    var interval: TimeInterval = 4
    /// 指示器的辅助功能名称，例如「精选推荐」
    var label: String
    /// 指示器的辅助功能标识（UI 测试读它的 value 判断翻到了第几张）
    var positionIdentifier: String
    /// 翻到了第几张（不含复制页，0 起）
    var onSelect: (Int) -> Void = { _ in }
    @ViewBuilder let page: (Item, Bool) -> Page

    /// 当前停在第几页（含复制页）。iOS 18 的滚动视图直接绑定它，旧系统的 TabView 用它做选中项。
    @State private var position: Int?
    @State private var appeared = false
    @State private var onScreen = true
    /// 手指在轮播上（iOS 18 起由滚动阶段得出）
    @State private var interacting = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(items: [Item], interval: TimeInterval = 4, label: String, positionIdentifier: String,
         onSelect: @escaping (Int) -> Void = { _ in },
         @ViewBuilder page: @escaping (Item, Bool) -> Page) {
        self.items = items
        self.interval = interval
        self.label = label
        self.positionIdentifier = positionIdentifier
        self.onSelect = onSelect
        self.page = page
        _position = State(initialValue: HeroLoop.page(forReal: 0, count: items.count))
    }

    private var pages: [Item] { HeroLoop.pages(items) }
    private var current: Int { position ?? HeroLoop.page(forReal: 0, count: items.count) }
    private var selection: Int { HeroLoop.real(current, count: items.count) }

    private var canAutoplay: Bool {
        items.count > 1 && CarouselAutoplay.enabled && !reduceMotion && !interacting
            && appeared && onScreen && scenePhase == .active
    }

    var body: some View {
        pager
            .overlay(alignment: .bottomTrailing) {
                if items.count > 1 {
                    indicator
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: CarouselOnScreenKey.self, value: Self.isOnScreen(proxy.frame(in: .global)))
                }
            }
            .onPreferenceChange(CarouselOnScreenKey.self) { visible in
                if onScreen != visible { onScreen = visible }
            }
            .onAppear {
                appeared = true
                onSelect(selection)
            }
            .onDisappear { appeared = false }
            .onChange(of: items.map(\.id)) { _ in
                // 换了一批：回到第一张
                jump(to: HeroLoop.page(forReal: 0, count: items.count))
                onSelect(0)
            }
            .onChange(of: current) { value in
                onSelect(HeroLoop.real(value, count: items.count))
                wrapAfterTransition(from: value)
            }
            .task(id: AutoplayKey(page: current, running: canAutoplay)) {
                guard canAutoplay else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, canAutoplay else { return }
                advance()
            }
            .accessibilityElement(children: .contain)
    }

    // MARK: 翻页容器

    @ViewBuilder private var pager: some View {
        if #available(iOS 18.0, *) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                            pageView(item, index: index)
                                .containerRelativeFrame(.horizontal)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $position)
                .onScrollPhaseChange { _, phase in
                    let busy = phase != .idle
                    if interacting != busy { interacting = busy }
                    if !busy { wrapIfNeeded() }
                }
                // 第一次出现时停在第一张真页上（它前面是最后一张的复制页）
                .onAppear { proxy.scrollTo(current, anchor: .leading) }
            }
        } else {
            TabView(selection: Binding(get: { current }, set: { position = $0 })) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    pageView(item, index: index).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func pageView(_ item: Item, index: Int) -> some View {
        let isCurrent = index == current
        return page(item, isCurrent)
            .accessibilityHidden(!isCurrent)
    }

    // MARK: 翻页与循环

    private func advance() {
        guard items.count > 1 else { return }
        // 还停在复制页上（换回真页没赶上）：先换回去，下一轮再翻
        if HeroLoop.wrapTarget(current, count: items.count) != nil {
            wrapIfNeeded()
            return
        }
        withAnimation(.easeInOut(duration: 0.55)) { position = current + 1 }
    }

    private func select(_ index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
            position = HeroLoop.page(forReal: index, count: items.count)
        }
    }

    /// 无动画换页：复制页换回真页、换了一批时用。两页画面一样，看不出跳了一下。
    private func jump(to page: Int) {
        guard position != page else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position = page }
    }

    private func wrapIfNeeded() {
        if let target = HeroLoop.wrapTarget(current, count: items.count) { jump(to: target) }
    }

    /// 翻到复制页后等翻页动画走完再换回真页。旧系统的 TabView 拿不到滚动阶段，全靠这里；
    /// iOS 18 停稳时滚动阶段会先换一次，这里是兜底（手指还在上面就不动，等它停稳再换）。
    private func wrapAfterTransition(from page: Int) {
        guard HeroLoop.wrapTarget(page, count: items.count) != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard current == page, !interacting else { return }
            wrapIfNeeded()
        }
    }

    private static func isOnScreen(_ frame: CGRect) -> Bool {
        let height = UIScreen.main.bounds.height
        // 露出不到 60pt（基本被状态栏、搜索栏挡住）就算看不见
        return frame.maxY > 60 && frame.minY < height - 60
    }

    // MARK: 指示器

    /// 右下角的小圆点：当前页拉长成胶囊。轻点圆点跳到那一张；旁白可以上下滑动切换。
    private var indicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<items.count, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? Color.white : Color.white.opacity(0.45))
                    .frame(width: index == selection ? 14 : 4, height: 4)
                    .frame(width: index == selection ? 22 : 12, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { select(index) }
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 0.5)
        .animation(reduceMotion ? nil : Motion.snappy, value: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("第 \(selection + 1) 张，共 \(items.count) 张")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select((selection + 1) % items.count)
            case .decrement: select((selection + items.count - 1) % items.count)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(positionIdentifier)
    }
}

private struct AutoplayKey: Hashable {
    let page: Int
    let running: Bool
}

private struct CarouselOnScreenKey: PreferenceKey {
    static var defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

/// 自动翻页的总开关。界面截图和首页 UI 测试默认关掉（画面要稳定、按钮不能在点之前被翻走），
/// 测试自动翻页时用 HPLAYER_CAROUSEL_AUTOPLAY=1 打开。
enum CarouselAutoplay {
    static let enabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["HPLAYER_CAROUSEL_AUTOPLAY"] == "1" { return true }
        if InterfacePreview.active || environment["HPLAYER_HOME_TEST"] == "1" { return false }
        return true
    }()
}

/// 循环页码：把最后一张复制到最前、第一张复制到最后。只有一张时不循环。
enum HeroLoop {
    static func pages<Item>(_ items: [Item]) -> [Item] {
        guard items.count > 1, let first = items.first, let last = items.last else { return items }
        return [last] + items + [first]
    }

    /// 页码 → 第几张（0 起）
    static func real(_ page: Int, count: Int) -> Int {
        guard count > 1 else { return min(max(page, 0), max(count - 1, 0)) }
        return ((page - 1) % count + count) % count
    }

    /// 第几张 → 页码
    static func page(forReal index: Int, count: Int) -> Int {
        count > 1 ? index + 1 : index
    }

    /// 停在复制页上时要换回的真页页码；不在复制页上返回 nil。
    static func wrapTarget(_ page: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        if page == 0 { return count }
        if page == count + 1 { return 1 }
        return nil
    }
}

extension View {
    /// 翻页时封面比卡片慢半拍：卡片滑走一整页，封面只挪一小段，像隔着一层玻璃。
    /// 只在 iOS 18 的翻页滚动视图里生效；减弱动态效果时关闭。
    func carouselParallax() -> some View { modifier(CarouselParallax()) }
}

private struct CarouselParallax: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            if reduceMotion {
                content
            } else {
                content.scrollTransition(.interactive, axis: .horizontal) { view, phase in
                    view
                        .scaleEffect(1.12)
                        .offset(x: -phase.value * 56, y: 0)
                }
            }
        } else {
            content
        }
    }
}
