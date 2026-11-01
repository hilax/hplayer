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

/// 首页 / 片库 / 网盘 / 我的。悬浮的液态玻璃胶囊，用滑动的琥珀高光标示选中的标签。
/// 手指可以左右拖到别的标签，松手后切换过去。
struct AppTabBar: View {
    @Binding var selection: HomeSection
    @State private var dragX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tabs = HomeSection.tabs
    private let barHeight: CGFloat = 60

    private func index(at x: CGFloat, width: CGFloat) -> Int {
        let item = width / CGFloat(tabs.count)
        return min(max(Int(x / max(item, 1)), 0), tabs.count - 1)
    }

    private func choose(_ section: HomeSection) {
        guard selection != section else { return }
        Haptics.select()
        withAnimation(reduceMotion ? nil : Motion.snappy) { selection = section }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let itemWidth = width / CGFloat(tabs.count)
            let selected = tabs.firstIndex(of: selection) ?? 0
            let highlight = dragX.map { index(at: $0, width: width) } ?? selected
            let pillX = dragX.map { min(max($0 - itemWidth / 2, 0), width - itemWidth) } ?? CGFloat(selected) * itemWidth

            ZStack(alignment: .leading) {
                TabSelectionHighlight()
                    .frame(width: itemWidth, height: geo.size.height)
                    .offset(x: pillX)
                    .animation(reduceMotion || dragX != nil ? nil : Motion.snappy, value: pillX)

                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element) { position, section in
                        TabBarButton(section: section, selected: position == highlight) { choose(section) }
                    }
                }
            }
            .onChange(of: highlight) { _ in
                if dragX != nil { Haptics.select() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in dragX = min(max(value.location.x, 0), width) }
                    .onEnded { value in
                        let target = tabs[index(at: value.location.x, width: width)]
                        dragX = nil
                        choose(target)
                    }
            )
        }
        .frame(height: barHeight)
        .padding(4)
        .liquidGlass(in: Capsule(), interactive: true)
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

/// 选中标签的琥珀高光，与外壳共用一层玻璃，避免嵌套折射让材质发灰。
private struct TabSelectionHighlight: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(Theme.accent.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [Theme.goldLight.opacity(0.32), Theme.accent.opacity(0.06), Theme.goldLight.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            }
            .padding(2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 液态玻璃：iOS 26 用系统的 glassEffect（折射、高光、触摸时流动）；
    /// 更低版本退回毛玻璃 + 渐变描边 + 柔和投影，看起来接近。
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.stroke(
                        LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.08), Color.white.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8
                    )
                )
                .shadow(color: Color.black.opacity(0.16), radius: 14, y: 6)
        }
    }
}

private struct TabBarButton: View {
    let section: HomeSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: selected ? section.icon.activeName : section.icon.name)
                    .font(.system(size: 21, weight: selected ? .semibold : .regular))
                    .bounceSymbol(on: selected)
                    .frame(height: 24)
                Text(section.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.94))
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(section.identifier)
    }
}
