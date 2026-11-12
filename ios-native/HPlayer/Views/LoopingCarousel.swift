import SwiftUI

/// 顶部轮播（首页「推荐」、动漫频道共用），照参考视频的翻页方式：
///
/// - **卡片不动、图片不动**：下一张图从卡片右侧正中以一道弧形边「揭」出来，弧线往左扫过整张卡片。
///   两张图都钉在原地，变的只是露出多少。
/// - **文字和按钮原地换**：揭到一半时，片名、信息和按钮直接换成下一张的，不滑动、不淡入（和参考视频一样一帧换掉）。
/// - 手动左右拖：弧线跟着手指走，松手吸到最近的一张；每 4 秒自动翻一张；首尾相接。
///
/// 自动翻页只在用户「看得见、没在碰」的时候走：打开「减弱动态效果」、手指在轮播上、轮播滑出屏幕、
/// 切到别的页面、App 进后台时都暂停；手动翻过一页，计时从头开始。
///
/// 分三层：
/// 1. 画面层（`background`）：当前图 + 正在揭出来的那张（弧形遮罩），不接触摸；
/// 2. 手势层：一排透明的整页（`hitArea`，点它就是点这一张：进详情 / 播放）。iOS 18 起放在按页吸附的横向滚动视图里，
///    由滚动位置算出「揭到哪儿」；更早的系统用分页 TabView，翻完一页再补放揭开动画；
/// 3. 文字层（`foreground`）：只画一张，揭过一半时原地换成下一张。
struct LoopingCarousel<Item: Identifiable, Background: View, Foreground: View, HitArea: View>: View {
    let items: [Item]
    /// 自动翻页间隔（秒）
    var interval: TimeInterval = 4
    /// 指示器的辅助功能名称，例如「精选推荐」
    var label: String
    /// 指示器的辅助功能标识（UI 测试读它的 value 判断翻到了第几张）
    var positionIdentifier: String
    /// 文字换成了第几张（0 起）：页面氛围色跟着它变
    var onSelect: (Int) -> Void = { _ in }
    @ViewBuilder let background: (Item) -> Background
    @ViewBuilder let foreground: (Item) -> Foreground
    @ViewBuilder let hitArea: (Item) -> HitArea

    /// 停稳的那一张（0 起）
    @State private var current = 0
    /// 正在揭开：from 在下面，to 从右侧正中揭出来，progress 0…1
    @State private var reveal: Reveal?
    /// 文字层画的是哪一张
    @State private var captionIndex = 0
    /// 手势层停在第几页（含首尾复制页）
    @State private var page: Int?
    @State private var dragging = false
    @State private var appeared = false
    @State private var onScreen = true
    /// 自动翻页（或点指示点）的揭开动画进行中
    @State private var turning = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 揭开动画时长；文字在一半时换
    private static var turnDuration: TimeInterval { 0.9 }

    init(items: [Item], interval: TimeInterval = 4, label: String, positionIdentifier: String,
         onSelect: @escaping (Int) -> Void = { _ in },
         @ViewBuilder background: @escaping (Item) -> Background,
         @ViewBuilder foreground: @escaping (Item) -> Foreground,
         @ViewBuilder hitArea: @escaping (Item) -> HitArea) {
        self.items = items
        self.interval = interval
        self.label = label
        self.positionIdentifier = positionIdentifier
        self.onSelect = onSelect
        self.background = background
        self.foreground = foreground
        self.hitArea = hitArea
        _page = State(initialValue: HeroLoop.page(forReal: 0, count: items.count))
    }

    private var count: Int { items.count }

    private var canAutoplay: Bool {
        count > 1 && CarouselAutoplay.enabled && !reduceMotion && !dragging && !turning
            && appeared && onScreen && scenePhase == .active
    }

    var body: some View {
        ZStack {
            artwork
            driver
            captionLayer
        }
        .overlay(alignment: .bottomTrailing) {
            if count > 1 {
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
            onSelect(captionIndex)
        }
        .onDisappear { appeared = false }
        .onChange(of: items.map(\.id)) { _ in reset() }
        .onChange(of: captionIndex) { index in onSelect(index) }
        .task(id: AutoplayKey(page: current, running: canAutoplay)) {
            guard canAutoplay else { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, canAutoplay else { return }
            turn(to: (current + 1) % count, forward: true)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 画面层

    private var artwork: some View {
        let base = reveal?.from ?? current
        return ZStack {
            if items.indices.contains(base) {
                background(items[base])
                    .id("base-\(base)")
            }
            if let reveal, items.indices.contains(reveal.to) {
                background(items[reveal.to])
                    .id("reveal-\(reveal.to)")
                    .mask { ArcReveal(progress: reveal.progress) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 文字层

    private var captionLayer: some View {
        ZStack {
            if items.indices.contains(captionIndex) {
                foreground(items[captionIndex])
                    .id(captionIndex)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// 原地换文字：不带任何动画（参考视频里就是一帧换掉）
    private func showCaption(_ index: Int) {
        guard index != captionIndex else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { captionIndex = index }
    }

    // MARK: 手势层

    @ViewBuilder private var driver: some View {
        let pages = HeroLoop.pages(items)
        if #available(iOS 18.0, *) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                            hitArea(item)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .contentShape(Rectangle())
                                .accessibilityHidden(index != (page ?? -1))
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $page)
                .onScrollGeometryChange(for: DriverSample.self) { geometry in
                    DriverSample(offset: geometry.contentOffset.x, width: geometry.containerSize.width)
                } action: { _, sample in
                    follow(sample)
                }
                .onScrollPhaseChange { _, phase in
                    let touching = phase == .interacting || phase == .tracking || phase == .decelerating
                    if touching != dragging { dragging = touching }
                    if phase == .idle { settle(proxy: proxy) }
                }
                .onAppear { proxy.scrollTo(page ?? 0, anchor: .leading) }
            }
        } else {
            TabView(selection: Binding(get: { page ?? 0 }, set: { newValue in
                let oldReal = HeroLoop.real(page ?? 0, count: count)
                page = newValue
                legacyPageChanged(from: oldReal, toPage: newValue)
            })) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    hitArea(item)
                        .contentShape(Rectangle())
                        .accessibilityHidden(index != (page ?? -1))
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    /// 手指拖动（和松手后的减速）时：滚动位置换算成「哪两张、揭到哪儿」，画面和文字跟着走。
    /// 程序跳页（换回真页、自动翻页前对齐）不在拖动中，忽略，画面不会跳。
    private func follow(_ sample: DriverSample) {
        guard dragging, !turning, sample.width > 1, count > 1 else { return }
        let position = max(0, sample.offset / sample.width)
        let lower = floor(position)
        let fraction = position - lower
        let from = HeroLoop.real(Int(lower), count: count)
        let to = HeroLoop.real(Int(lower) + 1, count: count)
        if fraction < 0.001 {
            if reveal != nil { reveal = nil }
            if current != from { current = from }
        } else {
            if current != from { current = from }
            reveal = Reveal(from: from, to: to, progress: fraction)
        }
        showCaption(fraction < 0.5 ? from : to)
    }

    /// 停稳：停在两页中间就吸到最近的整页；复制页换回真页；画面收成一张。
    @available(iOS 18.0, *)
    private func settle(proxy: ScrollViewProxy) {
        guard !turning, let target = page else { return }
        if let reveal, reveal.progress > 0.002, reveal.progress < 0.998 {
            let nearest = reveal.progress >= 0.5 ? reveal.to : reveal.from
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(pageIndex(showing: nearest, near: target), anchor: .leading)
            }
            return
        }
        let real = HeroLoop.real(target, count: count)
        current = real
        reveal = nil
        showCaption(real)
        if let wrapped = HeroLoop.wrapTarget(target, count: count) { jumpDriver(to: wrapped) }
    }

    /// 离 near 最近、显示第 real 张的页码（含首尾复制页）
    private func pageIndex(showing real: Int, near: Int) -> Int {
        let candidates = [HeroLoop.page(forReal: real, count: count), 0, count + 1]
            .filter { HeroLoop.real($0, count: count) == real }
        return candidates.min { abs($0 - near) < abs($1 - near) } ?? HeroLoop.page(forReal: real, count: count)
    }

    /// iOS 16 / 17：TabView 翻完一页才告诉我们，补放一次揭开动画；复制页过一会儿换回真页。
    private func legacyPageChanged(from oldReal: Int, toPage newPage: Int) {
        let newReal = HeroLoop.real(newPage, count: count)
        if let wrapped = HeroLoop.wrapTarget(newPage, count: count) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                if page == newPage { jumpDriver(to: wrapped) }
            }
        }
        guard newReal != oldReal, !turning else { return }
        let forward = (oldReal + 1) % count == newReal
        animateReveal(from: oldReal, to: newReal, forward: forward, moveDriver: false)
    }

    // MARK: 翻页

    /// 自动翻页、点指示点：画面揭开、文字在中途换；手势层先无动画对齐到目标页。
    private func turn(to target: Int, forward: Bool) {
        guard count > 1, target != current, !turning else { return }
        animateReveal(from: current, to: target, forward: forward, moveDriver: true)
    }

    private func animateReveal(from: Int, to: Int, forward: Bool, moveDriver: Bool) {
        if moveDriver { jumpDriver(to: HeroLoop.page(forReal: to, count: count)) }
        var instant = Transaction()
        instant.disablesAnimations = true
        if reduceMotion {
            withTransaction(instant) {
                current = to
                reveal = nil
            }
            showCaption(to)
            return
        }
        turning = true
        // 遮罩只从右往左揭：往后翻是「新图揭出来」，往回翻是「当前图往右收回去，露出前一张」
        let start = forward ? Reveal(from: from, to: to, progress: 0) : Reveal(from: to, to: from, progress: 1)
        withTransaction(instant) { reveal = start }
        withAnimation(.easeInOut(duration: Self.turnDuration)) {
            reveal?.progress = forward ? 1 : 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.turnDuration * 0.5 * 1_000_000_000))
            showCaption(to)
            try? await Task.sleep(nanoseconds: UInt64(Self.turnDuration * 0.55 * 1_000_000_000))
            withTransaction(instant) {
                current = to
                reveal = nil
            }
            turning = false
        }
    }

    /// 手势层无动画换页（画面不受影响）
    private func jumpDriver(to target: Int) {
        guard page != target else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { page = target }
    }

    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            current = 0
            reveal = nil
            captionIndex = 0
            page = HeroLoop.page(forReal: 0, count: count)
        }
        turning = false
        onSelect(0)
    }

    private static func isOnScreen(_ frame: CGRect) -> Bool {
        let height = UIScreen.main.bounds.height
        // 露出不到 60pt（基本被状态栏、搜索栏挡住）就算看不见
        return frame.maxY > 60 && frame.minY < height - 60
    }

    // MARK: 指示器

    /// 右下角的小圆点：当前页拉长成胶囊，跟着文字换。轻点圆点跳到那一张；旁白可以上下滑动切换。
    private var indicator: some View {
        let selection = captionIndex
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? Color.white : Color.white.opacity(0.45))
                    .frame(width: index == selection ? 14 : 4, height: 4)
                    .frame(width: index == selection ? 22 : 12, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { turn(to: index, forward: index > current) }
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 0.5)
        .animation(reduceMotion ? nil : Motion.snappy, value: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("第 \(selection + 1) 张，共 \(count) 张")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: turn(to: (current + 1) % count, forward: true)
            case .decrement: turn(to: (current + count - 1) % count, forward: false)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(positionIdentifier)
    }
}

/// 正在揭开的两张：from 在下，to 从右侧正中以弧形揭出来。
private struct Reveal: Equatable {
    var from: Int
    var to: Int
    var progress: CGFloat
}

private struct DriverSample: Equatable {
    var offset: CGFloat
    var width: CGFloat
}

/// 揭开用的遮罩：圆心在卡片右边外侧、上下正中，半径随进度从「刚碰到右边正中」长到「盖住左边两个角」。
/// 露出来的边是一道向左鼓的弧：先从右边中间冒出来，再往左扫过整张卡片，和参考视频一样。
struct ArcReveal: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.maxX + rect.width * 0.3, y: rect.midY)
        let start = rect.width * 0.3
        let end = hypot(center.x - rect.minX, center.y - rect.minY) + 2
        let radius = start + (end - start) * min(max(progress, 0), 1)
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
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
