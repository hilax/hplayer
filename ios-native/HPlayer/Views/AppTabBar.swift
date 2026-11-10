import SwiftUI

/// 应用的一级页面。前四个是底部标签（系统原生 TabView，iOS 26 上是悬浮的 Liquid Glass 标签栏）：
/// 首页 / 磁力 / 网盘 / 我的（2.0：片库并入首页频道，磁力升为一级 Tab）。
/// `search` 是从各页搜索入口进入的全屏搜索，不在标签栏上。
enum HomeSection: Hashable, CaseIterable {
    case home, magnet, cloud, mine, search

    static let tabs: [HomeSection] = [.home, .magnet, .cloud, .mine]

    var title: String {
        switch self {
        case .home: return "首页"
        case .magnet: return "磁力"
        case .cloud: return "网盘"
        case .mine: return "我的"
        case .search: return "搜索"
        }
    }

    var icon: AppIcon {
        switch self {
        case .home: return .home
        case .magnet: return .magnet
        case .cloud: return .cloud
        case .mine: return .mine
        case .search: return .search
        }
    }

    var identifier: String {
        switch self {
        case .home: return "tab.home"
        case .magnet: return "tab.magnet"
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

// MARK: - 首页频道

/// 首页顶部的频道：推荐（混合精选与货架）、片库（115 + 本地，四行筛选海报墙）、动漫（在线番剧）。
enum HomeChannel: String, Hashable, CaseIterable, Identifiable {
    case recommend, library, anime, drama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommend: return "推荐"
        case .library: return "片库"
        case .anime: return "动漫"
        case .drama: return "短剧"
        }
    }
}

/// 频道条：选中项加粗 + 下方 18×3 的光轨，在频道之间滑动。
struct HomeChannelBar: View {
    @Binding var selection: HomeChannel
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 18) {
            ForEach(HomeChannel.allCases) { channel in
                let selected = channel == selection
                Button {
                    guard !selected else { return }
                    Haptics.select()
                    withAnimation(reduceMotion ? nil : Motion.snappy) { selection = channel }
                } label: {
                    Text(channel.title)
                        .font(.system(size: selected ? 18 : 16, weight: selected ? .heavy : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(height: 40)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule()
                                    .fill(Theme.prismGradient)
                                    .frame(width: 18, height: 3)
                                    .matchedGeometryEffect(id: "home.channel.underline", in: underline)
                                    .offset(y: -1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("home.channel.\(channel.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.channels")
    }
}
