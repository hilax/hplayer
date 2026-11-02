import SwiftUI

/// 应用的一级页面。前四个是底部标签（系统原生 TabView，iOS 26 上是悬浮的 Liquid Glass 标签栏）；
/// `search` 是从各页搜索入口进入的全屏搜索，不在标签栏上。
enum HomeSection: Hashable, CaseIterable {
    case home, library, cloud, mine, search

    static let tabs: [HomeSection] = [.home, .library, .cloud, .mine]

    var title: String {
        switch self {
        case .home: return "首页"
        case .library: return "片库"
        case .cloud: return "网盘"
        case .mine: return "我的"
        case .search: return "搜索"
        }
    }

    var icon: AppIcon {
        switch self {
        case .home: return .home
        case .library: return .library
        case .cloud: return .cloud
        case .mine: return .mine
        case .search: return .search
        }
    }

    var identifier: String {
        switch self {
        case .home: return "tab.home"
        case .library: return "tab.library"
        case .cloud: return "tab.cloud"
        case .mine: return "tab.mine"
        case .search: return "tab.search"
        }
    }
}

// MARK: - 标签栏显隐

extension View {
    /// 这个页面显示期间收起系统标签栏；返回一级页面时系统自动升起来（带系统动画）。
    func hidesTabBar() -> some View {
        toolbar(.hidden, for: .tabBar)
    }
}
