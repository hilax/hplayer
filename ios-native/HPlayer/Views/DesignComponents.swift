import SwiftUI

/// 全应用共用的排版和控件。所有页面的标题、行、按钮、分组、输入框、角标都从这里取，
/// 改这里就是改所有页面。数值一律来自 `Theme`（颜色、`Theme.Space`、`Theme.Radius`、`Theme.Typo`），
/// 规范全文见仓库根目录 `.interface-design/system.md`。
///
/// 交互状态（所有控件同一套，克制、不改尺寸）：
/// - 默认：灰阶 + 白 / 墨主操作，最多一处琥珀
/// - 按下：压一层同色 12% 的薄层，缩到 0.98（减少动态效果时只变明度）
/// - 悬停（iPad 指针）：系统高亮
/// - 焦点：输入框边线变 1pt 琥珀；按钮用系统焦点环
/// - 不可用：底色退成最浅的一层，文字退成 `textMuted`，不响应点按

// MARK: - 标题

struct PageIntroduction: View {
    /// 保留参数是为了不改动调用处；视觉上不再显示英文小标题。
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if showsTitle {
                Text(title)
                    .font(Theme.Typo.pageTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(Theme.Typo.meta).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一级页面（网盘、我的）顶部的大标题行：34pt 粗体大标题，右侧放图标按钮。
struct ScreenTitleBar<Trailing: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                Text(title)
                    .font(Theme.Typo.pageTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            HStack(spacing: 0, content: trailing)
        }
        .padding(.horizontal, Theme.contentInset)
        .frame(minHeight: 48)
    }
}

extension ScreenTitleBar where Trailing == EmptyView {
    init(_ title: String, subtitle: String = "") {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 大标题滚出屏幕后，顶部出现的紧凑标题栏：和系统导航栏「大标题收起成行内标题」一样的手感。
/// 系统材质底 + 一条细线，居中 17pt 半粗标题，右侧放图标按钮。没出现时不占点按、不进无障碍树。
struct CompactTitleBar<Trailing: View>: View {
    let title: String
    let visible: Bool
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text(title)
                .font(Theme.Typo.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 96)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if visible { trailing() }
            }
            .padding(.trailing, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.bar, ignoresSafeAreaEdges: .top)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: Theme.Stroke.hairline)
        }
        .offset(y: visible || reduceMotion ? 0 : -6)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .animation(reduceMotion ? nil : Motion.quick, value: visible)
    }
}

extension CompactTitleBar where Trailing == EmptyView {
    init(title: String, visible: Bool) {
        self.init(title: title, visible: visible) { EmptyView() }
    }
}

/// 记录一块内容（通常是页面大标题）是否已经往上滚出去了：滚过它自身高度的九成，或者被列表回收时算「滚走了」。
/// 不依赖坐标空间和 preference，所以在 List 和 ScrollView 里都能用。
private struct ScrolledAwayTracker: ViewModifier {
    @Binding var away: Bool
    @State private var restingMaxY: CGFloat?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    let maxY = proxy.frame(in: .global).maxY
                    Color.clear
                        .onAppear {
                            if restingMaxY == nil { restingMaxY = maxY }
                            update(maxY, height: proxy.size.height)
                        }
                        .onChange(of: maxY) { update($0, height: proxy.size.height) }
                }
            }
            .onDisappear { if !away { away = true } }
    }

    private func update(_ maxY: CGFloat, height: CGFloat) {
        guard let resting = restingMaxY else { return }
        let next = maxY < resting - height * 0.9
        if next != away { away = next }
    }
}

extension View {
    /// 见 `ScrolledAwayTracker`。配合 `CompactTitleBar` 用。
    func scrolledAway(_ away: Binding<Bool>) -> some View {
        modifier(ScrolledAwayTracker(away: away))
    }
}

/// 栏目标题：左边是 17pt 半粗栏目名，右边是「全部 ›」之类的入口。
struct ShelfHeader<Trailing: View>: View {
    let title: String
    var identifier = ""
    var inset: CGFloat = Theme.contentInset
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(title)
                .font(Theme.Typo.section)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
            Spacer(minLength: Theme.Space.md)
            trailing()
        }
        .padding(.horizontal, inset)
    }
}

extension ShelfHeader where Trailing == EmptyView {
    init(_ title: String, identifier: String = "") {
        self.init(title: title, identifier: identifier) { EmptyView() }
    }
}

/// 栏目标题右侧的文字入口："全部 ›"
struct ShelfLinkLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(text)
            Image(systemName: AppIcon.forward.name).font(.caption2.weight(.semibold))
        }
        .font(Theme.Typo.meta)
        .secondaryTextStyle()
        .contentShape(Rectangle())
    }
}

// MARK: - 图标按钮

/// 顶栏上的图标按钮：44pt 点击区，线框图标。
struct BarIconButton: View {
    let icon: AppIcon
    let label: String
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon.name)
                .font(.scaled(20, weight: Theme.iconWeight))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// 弹层右上角统一的关闭按钮：抬高一层的小圆 + 细边 + 线框 ×，点击区 44pt。
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss
    var action: (() -> Void)?

    var body: some View {
        Button {
            Haptics.tap()
            if let action { action() } else { dismiss() }
        } label: {
            Image(systemName: AppIcon.close.name)
                .font(.scaled(12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
                .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline) }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel("关闭")
    }
}

// MARK: - 列表行

struct LibraryActionRow: View {
    let symbol: String
    let title: String
    var subtitle: String = ""
    var value: String = ""
    var showsChevron = true
    var tone: IconTile.Tone = .accent
    /// 右侧数值高亮（例如「3 部更新」用强调色）
    var valueHighlighted = false
    @Environment(\.isEnabled) private var isEnabled

    /// 图标列宽：分隔线从这里往右对齐标题（16 + 24 + 14）
    static let dividerInset: CGFloat = Theme.Space.lg + 24 + 14

    private var titleColor: Color {
        guard isEnabled else { return Theme.textMuted }
        return tone == .danger ? Theme.danger : Theme.textPrimary
    }

    var body: some View {
        HStack(spacing: 14) {
            // 图标不垫底色：线框图标直接摆在行首，和标题同色
            Image(systemName: symbol)
                .font(.scaled(19, weight: Theme.iconWeight))
                .foregroundStyle(titleColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.Typo.row).foregroundStyle(titleColor)
                if !subtitle.isEmpty {
                    Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if !value.isEmpty {
                Text(value)
                    .font(Theme.Typo.meta.weight(valueHighlighted ? .medium : .regular).monospacedDigit())
                    .foregroundStyle(valueHighlighted && isEnabled ? Theme.accent : Theme.textTertiary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: AppIcon.forward.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// 列表行首的图标：线框图标直接摆着，不垫底色。和 LibraryActionRow 的图标同一个规格。
struct RowIcon: View {
    let icon: AppIcon
    var tint: Color = Theme.textPrimary

    var body: some View {
        Image(systemName: icon.name)
            .font(.scaled(19, weight: Theme.iconWeight))
            .foregroundStyle(tint)
            .frame(width: 24)
    }
}

/// 列表行之间的分隔线：0.5pt 的线色，从标题处开始。
struct RowDivider: View {
    var leading: CGFloat = LibraryActionRow.dividerInset

    var body: some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(height: Theme.Stroke.hairline)
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

// MARK: - 按钮

/// 所有文字按钮共用的外观：主按钮、危险按钮是胶囊，次按钮是 10pt 圆角矩形；按下压一层薄色、缩到 0.98。
/// 外观画在 `ActionButtonBody` 这个视图里，这样「不可用」「减少动态效果」这些环境值才能读到；
/// 其他按钮样式（主 / 次 / 底部 / 危险）都直接返回它，不要手动调用别的 ButtonStyle 的 makeBody。
struct ActionButtonStyle: ButtonStyle {
    enum Kind {
        /// 主按钮：白底墨字（浅色模式墨底白字）的胶囊。每屏只放一个。
        case primary
        /// 压在封面 / 播放画面上的主按钮：始终白底墨字
        case primaryOnArtwork
        /// 次按钮：卡片底 + 1pt 线的圆角矩形
        case secondary
        /// 危险操作：红底白字的胶囊
        case destructive
    }

    var kind: Kind
    var minHeight: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, kind: kind, minHeight: minHeight)
    }
}

struct ActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ActionButtonStyle.Kind
    let minHeight: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if kind == .secondary {
            decorated(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        } else {
            decorated(Capsule())
        }
    }

    private func decorated<S: InsettableShape>(_ shape: S) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(kind == .secondary ? Theme.Typo.row.weight(.medium) : Theme.Typo.button)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.lg)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(background, in: shape)
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: Theme.Stroke.rule)
                }
            }
            // 按下：同色 12% 的薄层，不改尺寸
            .overlay { shape.fill(foreground.opacity(pressed && isEnabled ? 0.12 : 0)) }
            .contentShape(shape)
            .hoverEffect(.highlight)
            .scaleEffect(!reduceMotion && pressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : Motion.quick, value: pressed)
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.textMuted }
        switch kind {
        case .primary: return Theme.onPrimary
        case .primaryOnArtwork: return Theme.ink
        case .secondary: return Theme.textPrimary
        case .destructive: return .white
        }
    }

    private var background: Color {
        guard isEnabled else { return kind == .secondary ? Color.clear : Theme.tileTint }
        switch kind {
        case .primary: return Theme.primaryAction
        case .primaryOnArtwork: return Theme.paper
        case .secondary: return Theme.surface
        case .destructive: return Theme.dangerFill
        }
    }

    private var border: Color? {
        switch kind {
        case .secondary: return isEnabled ? Theme.rule : Theme.hairline
        default: return isEnabled ? nil : Theme.hairline
        }
    }
}

/// 主按钮：白底墨字（浅色模式墨底白字）的胶囊。每屏只放一个。
struct PrimaryActionStyle: ButtonStyle {
    /// 压在深色画面上时用 true：始终白底墨字
    var light = false

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, kind: light ? .primaryOnArtwork : .primary, minHeight: 48)
    }
}

/// 次按钮：卡片底 + 1pt 线 + 正文色字，10pt 圆角矩形。
struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, kind: .secondary, minHeight: 46)
    }
}

// MARK: - 页面与分组

extension View {
    func libraryFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground.ignoresSafeArea())
            .tint(Theme.accent)
    }

    /// 封面统一的边缘：底下垫一层中性色（图片还没出来、或图片本身带透明边时不露黑），按圆角裁切，
    /// 再描一圈很淡的内描边，把浅色封面和页面底色分开。货架、网格里的所有封面都用这一套。
    func coverEdge(cornerRadius: CGFloat = Theme.Radius.poster) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Theme.surfaceRaised)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline) }
    }

    func designScreen(_ identifier: String) -> some View {
        // Contain the page's children so its identifier cannot replace controls' identifiers.
        self.accessibilityElement(children: .contain).accessibilityIdentifier("screen.\(identifier)")
    }
}

struct DesignPage<Content: View>: View {
    let eyebrow: String
    let title: String
    var subtitle = ""
    var showsTitle = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if showsTitle || !subtitle.isEmpty {
                    PageIntroduction(eyebrow: eyebrow, title: title, subtitle: subtitle, showsTitle: showsTitle)
                }
                content()
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.section + Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// 一组列表行：卡片底 + 细边，不用投影。行之间用 `RowDivider`。
struct DesignGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
    }
}

// MARK: - 输入框

/// 表单输入框：上方小标签，下方是比周围略深的输入区；获得焦点时边线变成 1pt 琥珀。
struct DesignField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label)
                .font(Theme.Typo.meta.weight(.medium))
                .foregroundStyle(focused ? Theme.accent : Theme.textSecondary)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(Theme.Typo.body)
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textMuted)
            .tint(Theme.accent)
            .padding(.horizontal, Theme.Space.md + 2)
            .frame(minHeight: 48)
            .fieldChrome(focused: focused, enabled: isEnabled)
        }
        .animation(Motion.quick, value: focused)
    }
}

struct DesignNotice: View {
    var symbol = AppIcon.info.name
    let text: String
    var warning = false
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: symbol) }
        .font(Theme.Typo.meta)
        .foregroundStyle(warning ? Theme.warning : Theme.textSecondary)
        .lineSpacing(3)
    }
}

// MARK: - 筛选块

/// 筛选胶囊：选中是白底墨字（浅色模式墨底白字）的胶囊，未选中只有灰字。
/// 同一排里选中的底会滑到新选中的那个上（共用 `namespace` 即可）。看上去 32pt 高，点按区域上下各扩 6pt 到 44pt。
struct SelectionPill: View {
    let title: String
    let selected: Bool
    var namespace: Namespace.ID?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    init(title: String, selected: Bool, namespace: Namespace.ID? = nil, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.namespace = namespace
        self.action = action
    }

    var body: some View {
        Button {
            if !selected { Haptics.select() }
            action()
        } label: {
            Text(title)
                .font(Theme.Typo.meta.weight(selected ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, Theme.Space.md)
                .frame(minHeight: 32)
                .background { background }
                .contentShape(VerticalHitArea(extra: 6))
                .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.96))
        .animation(reduceMotion ? nil : Motion.snappy, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.textMuted }
        return selected ? Theme.onPrimary : Theme.textSecondary
    }

    @ViewBuilder private var background: some View {
        let shape = Capsule()
        if selected {
            if let namespace {
                shape.fill(Theme.primaryAction).matchedGeometryEffect(id: "pill.selection", in: namespace)
            } else {
                shape.fill(Theme.primaryAction)
            }
        }
    }
}

/// 把点按区域只往上下扩：一排紧挨着的筛选胶囊左右不会互相抢点按。
struct VerticalHitArea: Shape {
    var extra: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -extra))
    }
}

// MARK: - 角标

/// 小标签：「更新」「完结」「12 集」「8.6」。最小 11pt，4pt 圆角，横向 5pt、高 18pt。
struct TagBadge: View {
    enum Style {
        /// 压在封面上：近黑半透明底 + 白字（任何画面上都清楚）
        case onArtwork
        /// 琥珀实心：只用于「更新」这类需要被注意到的状态
        case accent
        /// 页面上的中性标签：极淡底 + 次要文字
        case neutral
        /// 只描边：「高清」「中字」这类说明性标签
        case outline
    }

    let text: String
    var style: Style = .onArtwork
    var foreground: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
        Text(text)
            .font(Theme.Typo.badge.monospacedDigit())
            .foregroundStyle(foreground ?? defaultForeground)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minHeight: 18)
            .background(fill, in: shape)
            .overlay {
                if style == .outline {
                    shape.strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hairline)
                }
            }
    }

    private var defaultForeground: Color {
        switch style {
        case .onArtwork: return Theme.paper
        case .accent: return Theme.onAccentFill
        case .neutral, .outline: return Theme.textSecondary
        }
    }

    private var fill: Color {
        switch style {
        case .onArtwork: return Theme.badgeScrim
        case .accent: return Theme.accentFill
        case .neutral: return Theme.tileTint
        case .outline: return .clear
        }
    }
}
