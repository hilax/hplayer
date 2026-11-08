import SwiftUI

/// 动漫详情入口：统一用 NavigationLink(value:) 把路由压进外层 NavigationStack。
///
/// 之前用 `@State + navigationDestination(isPresented:)`，绑定在视图刷新时容易被重置；
/// 嵌套在 TabView / ScrollView 里时就会出现「点了没反应」。值类型路由由 NavigationStack
/// 自己管理，和 HPlayer 其余页面（CloudRoute、PerformerRoute）的导航方式一致。
struct AnimeDetailLink<Label: View>: View {
    let animeId: Int
    @ViewBuilder var label: () -> Label

    var body: some View {
        NavigationLink(value: AnimeDetailRoute(animeId: animeId)) {
            label()
        }
        .buttonStyle(PosterButtonStyle())
    }
}
