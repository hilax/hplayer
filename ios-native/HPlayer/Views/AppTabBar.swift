import SwiftUI

/// 应用的一级页面。前四个是底部标签；`search` 是从各页搜索入口进入的全屏搜索，不在标签栏上。
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

/// 进入详情、演员合集这类二级页面时收起标签栏，回到一级页面再升起来。
/// 每个二级页面用自己的 id 登记，登记表为空时才显示标签栏，
/// 所以 onAppear / onDisappear 调用顺序错乱也不会让标签栏卡在隐藏状态。
@MainActor
final class TabBarVisibility: ObservableObject {
    @Published private(set) var hiders: Set<UUID> = []

    var isHidden: Bool { !hiders.isEmpty }
    func hide(_ id: UUID) { hiders.insert(id) }
    func show(_ id: UUID) { hiders.remove(id) }
}

private struct TabBarVisibilityKey: EnvironmentKey {
    static let defaultValue: TabBarVisibility? = nil
}

extension EnvironmentValues {
    var tabBarVisibility: TabBarVisibility? {
        get { self[TabBarVisibilityKey.self] }
        set { self[TabBarVisibilityKey.self] = newValue }
    }
}

private struct HidesTabBar: ViewModifier {
    @Environment(\.tabBarVisibility) private var visibility
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { visibility?.hide(id) }
            .onDisappear { visibility?.show(id) }
    }
}

extension View {
    /// 这个页面显示期间收起底部标签栏。
    func hidesTabBar() -> some View {
        modifier(HidesTabBar())
    }
}

// MARK: - 标签栏

/// 放在页面底部的容器：登记表有二级页面、或正在搜索时整条收起。
struct TabBarHost: View {
    @Binding var selection: HomeSection
    @ObservedObject var visibility: TabBarVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Bool { selection != .search && !visibility.isHidden }

    var body: some View {
        Group {
            if shown {
                AppTabBar(selection: $selection)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.smooth, value: shown)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

/// 首页 / 片库 / 网盘 / 我的。选中的标签：图标换成实心款并弹一下，
/// 金色底座在标签之间滑动，文字变金色。
struct AppTabBar: View {
    @Binding var selection: HomeSection
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeSection.tabs, id: \.self) { section in
                TabBarButton(section: section, selected: selection == section, namespace: indicator) {
                    guard selection != section else { return }
                    Haptics.select()
                    withAnimation(reduceMotion ? nil : Motion.snappy) { selection = section }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .background(alignment: .bottom) {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                Theme.pageBackground.opacity(0.78)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct TabBarButton: View {
    let section: HomeSection
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    if selected {
                        Capsule()
                            .fill(Theme.tileTint)
                            .frame(width: 54, height: 30)
                            .matchedGeometryEffect(id: "tab.indicator", in: namespace)
                    }
                    Image(systemName: selected ? section.icon.activeName : section.icon.name)
                        .font(.system(size: 19, weight: selected ? .semibold : .regular))
                        .bounceSymbol(on: selected)
                }
                .frame(height: 30)
                Text(section.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(section.identifier)
    }
}
