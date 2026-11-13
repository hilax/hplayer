import SwiftUI

/// 2.0 一级 Tab「磁力」：磁力聚合（搜索与分类浏览）作为根页面，右上角进入「粘贴链接播放」。
/// 第 6 阶段会换成智能输入框 + 统一解析面板（115 秒播 / 本机边下边播 / 离线到 115）。
struct MagnetTab: View {
    var body: some View {
        MagnetSearchView(isTabRoot: true)
            .designScreen("magnet-tab")
    }
}
