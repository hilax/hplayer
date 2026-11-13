import SwiftUI
import UIKit

/// 全应用统一的动效参数和小工具。
///
/// 原则：
/// 1. 只用弹簧，不用线性：点按、切换、展开、出现都是同一族弹簧，只是快慢不同。
/// 2. 动效只做一次，不做无限循环——循环动画会让自动化测试一直等不到界面空闲，也费电。
/// 3. 「减少动态效果」打开时，所有位移和缩放都变成瞬间完成，只保留颜色变化。
enum Motion {
    /// 点按、开关、选中：快而干脆
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.78)
    /// 面板展开、内容切换、卡片出现：柔和
    static let smooth = Animation.spring(response: 0.48, dampingFraction: 0.86)
    /// 强调：弹一下，用在主按钮和选中标记上
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.62)
    /// 淡入淡出
    static let fade = Animation.easeInOut(duration: 0.28)
    /// 封面取色背景：精选翻过一半后，整页底色用 0.3 秒过渡到新封面的颜色（参考视频里的节奏）。
    /// 颜色变化不属于位移和缩放，「减少动态效果」下也保留。
    static let artworkFade = Animation.easeInOut(duration: 0.3)
    static let quick = Animation.easeOut(duration: 0.16)

    /// 一排卡片依次出现：越靠后越晚，最多延后 `limit` 个台阶，后面的一起出现。
    static func stagger(_ index: Int, step: Double = 0.05, limit: Int = 8) -> Animation {
        smooth.delay(Double(min(max(index, 0), limit)) * step)
    }

    /// 在「减少动态效果」下返回 nil，其余情况返回传入的动画。
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - 触感

@MainActor
enum Haptics {
    /// 点按：标签切换、卡片确认
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// 选择变化：筛选条、分段、勾选
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    /// 完成：登录成功、解析完成
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// 失败或被拒绝
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - 按压反馈

/// 全应用的按钮按压手感：按下略微缩小并变淡，松手弹回；不可用时整体退成 45% 且不响应。
/// 海报、行、图标按钮都用它，所以手感一致。缩放只改绘制、不改布局，周围的内容不会跟着动。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(!reduceMotion && configuration.isPressed ? scale : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat) -> PressableStyle { PressableStyle(scale: scale) }
}

// MARK: - 依次出现

/// 记录哪些卡片已经浮现过，以及一组卡片（一个货架、一张网格）是什么时候开始浮现的。
///
/// 横向货架、网格和列表都是懒加载的：卡片滑出屏幕后会被销毁，滑回来时重新创建，视图里的 `@State` 也跟着丢掉。
/// 如果「是否已浮现」只存在 `@State` 里，快速滑动时每张重新出现的卡片都会先变透明，再等一个台阶的延迟才淡入，
/// 看起来就是格子消失又冒出来。所以这个记录放在视图外面：
/// - 浮现过的卡片，重建时第一帧就是完全显示；
/// - 只有一组卡片刚出现的头半秒（也就是第一屏）才播放依次浮现，之后滑进来的新卡片直接显示；
/// - 这一组里第一张从没出现过的卡片重新出现（换了筛选、换了搜索词），算新的一屏，重新计时。
final class RevealLedger: @unchecked Sendable {
    static let shared = RevealLedger()
    /// 一组卡片开始浮现后，多长时间内出现的新卡片还会播放浮现动画。
    static let window: TimeInterval = 0.5

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let lock = NSLock()
    private var revealed = Set<String>()
    private var opened: [String: TimeInterval] = [:]

    init() {}

    /// 这张卡片创建时是否应该先藏起来等浮现。只读，不改变记录，所以可以放心在视图 init 里调用。
    func startsHidden(id: String, scope: String, index: Int, now: TimeInterval = RevealLedger.now()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if revealed.contains(Self.key(scope, id)) { return false }
        if index == 0 { return true }
        guard let start = opened[scope] else { return true }
        return now - start < Self.window
    }

    /// 卡片出现在屏幕上时记一笔。
    func markRevealed(id: String, scope: String, index: Int, now: TimeInterval = RevealLedger.now()) {
        lock.lock()
        defer { lock.unlock() }
        guard revealed.insert(Self.key(scope, id)).inserted else { return }
        if index == 0 || opened[scope] == nil { opened[scope] = now }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        revealed.removeAll()
        opened.removeAll()
    }

    private static func key(_ scope: String, _ id: String) -> String { scope + "|" + id }
}

/// 第一次出现时从下方淡入。`index` 越大出现得越晚；
/// 超过前几个台阶的卡片（一般已经在屏幕外）直接显示，滑回来时不会重复播放。
/// 带 `id` 的卡片（懒加载容器里的）由 `RevealLedger` 记住是否浮现过，被回收重建后不会再变透明。
private struct RevealOnAppear: ViewModifier {
    let index: Int
    let ledgerKey: (id: String, scope: String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool

    init(index: Int, id: String?, scope: String) {
        self.index = index
        ledgerKey = id.map { (id: $0, scope: scope) }
        let hidden = id.map { RevealLedger.shared.startsHidden(id: $0, scope: scope, index: index) } ?? true
        _shown = State(initialValue: !hidden)
    }

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion || index > 5
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.97)
            .onAppear {
                if let ledgerKey {
                    RevealLedger.shared.markRevealed(id: ledgerKey.id, scope: ledgerKey.scope, index: index)
                }
                guard !shown else { return }
                if reduceMotion || index > 5 {
                    shown = true
                } else {
                    withAnimation(Motion.stagger(index)) { shown = true }
                }
            }
    }
}

extension View {
    /// 固定的几块内容（不在懒加载容器里）依次浮现。
    func reveal(_ index: Int = 0) -> some View {
        modifier(RevealOnAppear(index: index, id: nil, scope: ""))
    }

    /// 货架、网格、列表里的卡片依次浮现。这些容器会回收滑出屏幕的卡片，
    /// 所以必须带上卡片自己的 `id`，让已经浮现过的卡片重建后直接显示，而不是又淡入一遍。
    /// `file` 和 `line` 取调用处的位置，区分不同的货架和网格，不用手写。
    func reveal<ID: Hashable>(_ index: Int, id: ID, file: String = #fileID, line: Int = #line) -> some View {
        modifier(RevealOnAppear(index: index, id: "\(id)", scope: "\(file):\(line)"))
    }

    /// 值变化时让 SF Symbol 弹一下（iOS 17 起；低版本无动画）。
    @ViewBuilder
    func bounceSymbol<T: Equatable>(on value: T) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    /// 图标换款时（播放⇄暂停）用变形过渡（iOS 17 起；低版本直接替换）。
    @ViewBuilder
    func morphSymbol() -> some View {
        if #available(iOS 17.0, *) {
            self.contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// 数字变化时逐位滚动（iOS 16 起）。
    func rollingNumber() -> some View {
        self.contentTransition(.numericText())
    }
}

// MARK: - 环形进度

/// 圆环进度：从 0 转到目标值，中间放任意内容。媒体库管理的扫描进度用它。
struct ProgressRing<Center: View>: View {
    let value: Double
    var lineWidth: CGFloat = 4
    @ViewBuilder var center: () -> Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : Motion.smooth, value: value)
            center()
        }
    }
}

// MARK: - 勾选标记

/// 勾选圆圈：选中时主操作色（墨 / 纸）实心 + 反色勾弹出，取消时缩回成一圈细线。
struct CheckBadge: View {
    let selected: Bool
    var size: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.ruleStrong, lineWidth: 1.5)
                .opacity(selected ? 0 : 1)
            Circle()
                .fill(Theme.gold)
                .scaleEffect(selected ? 1 : 0.4)
                .opacity(selected ? 1 : 0)
            Image(systemName: AppIcon.check.name)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(Theme.onPrimary)
                .scaleEffect(selected ? 1 : 0.3)
                .opacity(selected ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : Motion.bouncy, value: selected)
        .accessibilityHidden(true)
    }
}
