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

/// 全应用的按钮按压手感：按下略微缩小并压暗，松手弹回。
/// 海报、行、胶囊按钮都用它，所以手感一致。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(!reduceMotion && configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat) -> PressableStyle { PressableStyle(scale: scale) }
}

// MARK: - 依次出现

/// 第一次出现时从下方 14pt 淡入。`index` 越大出现得越晚；
/// 超过前几个台阶的卡片（一般已经在屏幕外）直接显示，滑回来时不会重复播放。
private struct RevealOnAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion || index > 14
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                if reduceMotion || index > 14 {
                    shown = true
                } else {
                    withAnimation(Motion.stagger(index)) { shown = true }
                }
            }
    }
}

extension View {
    /// 列表、货架、网格里的卡片依次浮现。
    func reveal(_ index: Int = 0) -> some View {
        modifier(RevealOnAppear(index: index))
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
    var lineWidth: CGFloat = 7
    @ViewBuilder var center: () -> Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : Motion.smooth, value: value)
            center()
        }
    }
}

// MARK: - 勾选标记

/// 勾选圆圈：选中时金色实心 + 白勾弹出，取消时缩回。
struct CheckBadge: View {
    let selected: Bool
    var size: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.textTertiary, lineWidth: 1.5)
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
