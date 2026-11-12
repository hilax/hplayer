import SwiftUI

// MARK: - iOS 17 起的滚动动效
//
// 横滑货架：松手后按卡片吸附（停在一整张卡片上，不会停在半张），边缘的卡片略微缩小变淡，滑进来时舒展开。
// 网格：从屏幕底部滑进来的卡片轻轻浮起。轮播：翻页时封面比卡片慢一点，有景深感（见 AnimeHeroBanner）。
// iOS 16 上全部保持原样；打开「减弱动态效果」时只保留吸附（吸附只是停的位置，不算动画）。
//
// 横滑货架的用法（两处必须成对使用）：
//   ScrollView(.horizontal) { LazyHStack { … }.shelfContent() … }.shelfScrolling()
// iOS 17 上左右留白由 contentMargins 提供，吸附才会对齐到留白处；iOS 16 上仍是 padding。

extension View {
    /// 货架里装卡片的那一层（LazyHStack），必须直接跟在它后面。
    @ViewBuilder func shelfContent() -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetLayout()
        } else {
            self.padding(.horizontal, Theme.contentInset)
        }
    }

    /// 货架的横向 ScrollView。
    @ViewBuilder func shelfScrolling() -> some View {
        if #available(iOS 17.0, *) {
            self.contentMargins(.horizontal, Theme.contentInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }

    /// 货架里的一张卡片：滑到边缘时略微缩小变淡。
    func shelfCard() -> some View { modifier(ShelfCardEffect()) }

    /// 网格里的一张卡片：从底部滑进来时轻轻浮起。
    func gridCardEntrance() -> some View { modifier(GridCardEntrance()) }
}

private struct ShelfCardEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            if reduceMotion {
                content
            } else {
                content.scrollTransition(.interactive, axis: .horizontal) { view, phase in
                    view
                        .scaleEffect(1 - 0.06 * min(abs(phase.value), 1), anchor: .bottom)
                        .opacity(1 - 0.35 * min(abs(phase.value), 1))
                }
            }
        } else {
            content
        }
    }
}

private struct GridCardEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            if reduceMotion {
                content
            } else {
                // 只处理从下面进来的（phase.value > 0）；往上滑出去的保持原样，不在顶栏下面变淡
                content.scrollTransition(.interactive, axis: .vertical) { view, phase in
                    view
                        .scaleEffect(1 - 0.05 * max(min(phase.value, 1), 0), anchor: .top)
                        .opacity(1 - 0.45 * max(min(phase.value, 1), 0))
                        .offset(x: 0, y: 14 * max(min(phase.value, 1), 0))
                }
            }
        } else {
            content
        }
    }
}
