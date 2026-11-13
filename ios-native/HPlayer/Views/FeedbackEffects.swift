import Pow
import SwiftUI

// MARK: - 关键操作的视觉反馈（Pow）
//
// 震动仍由各处原有的 Haptics 负责，这里只加「看得见」的那一下：
// 成功时按钮轻轻一跳（追番还会飘出几颗小心），失败时左右摇一下。
// 只在状态「变成」成功 / 失败的那一刻触发，恢复原状时不动；打开「减弱动态效果」时全部关闭。

extension View {
    /// 成功反馈：`succeeded` 由 false 变成 true 时触发。
    func successPop(_ succeeded: Bool, particle: AppIcon? = nil, tint: Color = Theme.accent) -> some View {
        modifier(SuccessPop(succeeded: succeeded, particle: particle, tint: tint))
    }

    /// 失败反馈：`failed` 由 false 变成 true 时触发。
    func failureShake(_ failed: Bool) -> some View {
        modifier(FailureShake(failed: failed))
    }
}

private struct SuccessPop: ViewModifier {
    let succeeded: Bool
    let particle: AppIcon?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .changeEffect(.jump(height: 6), value: succeeded, isEnabled: succeeded && !reduceMotion)
            .changeEffect(
                .spray(origin: UnitPoint(x: 0.5, y: 0.35)) { particleView },
                value: succeeded,
                isEnabled: succeeded && !reduceMotion && particle != nil
            )
    }

    @ViewBuilder private var particleView: some View {
        if let particle {
            Image(systemName: particle.name)
                .font(.scaled(11, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct FailureShake: ViewModifier {
    let failed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.changeEffect(.shake(rate: .fast), value: failed, isEnabled: failed && !reduceMotion)
    }
}
