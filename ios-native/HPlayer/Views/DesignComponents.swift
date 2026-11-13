import SwiftUI

/// 全应用共用的排版和控件。所有页面的标题、行、按钮、分组都从这里取，
/// 改这里就是改所有页面。
struct PageIntroduction: View {
    /// 保留参数是为了不改动调用处；视觉上不再显示英文小标题。
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一级页面（片库、网盘、我的）顶部的大标题行，右侧放图标按钮。
struct ScreenTitleBar<Trailing: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 0, content: trailing)
        }
        .padding(.horizontal, Theme.contentInset)
        .frame(height: 44)
    }
}

extension ScreenTitleBar where Trailing == EmptyView {
    init(_ title: String, subtitle: String = "") {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 栏目标题：左边是栏目名，右边是「全部 ›」之类的入口。
struct ShelfHeader<Trailing: View>: View {
    let title: String
    var identifier = ""
    var inset: CGFloat = Theme.contentInset
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
            Spacer(minLength: 12)
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
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: AppIcon.forward.name).font(.system(size: 10, weight: .bold))
        }
        .font(.caption)
        .secondaryTextStyle()
        .contentShape(Rectangle())
    }
}

/// 顶栏上的图标按钮：44pt 点击区，线框图标，按下弹性缩放。
struct BarIconButton: View {
    let icon: AppIcon
    let label: String
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon.name)
                .font(.system(size: 20, weight: Theme.iconWeight))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// 弹层右上角统一的关闭按钮：灰底小圆 + 线框 ×，点击区 44pt。
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss
    var action: (() -> Void)?

    var body: some View {
        Button {
            Haptics.tap()
            if let action { action() } else { dismiss() }
        } label: {
            Image(systemName: AppIcon.close.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel("关闭")
    }
}

struct LibraryActionRow: View {
    let symbol: String
    let title: String
    var subtitle: String = ""
    var value: String = ""
    var showsChevron = true
    var tone: IconTile.Tone = .accent
    /// 右侧数值高亮（例如「3 部更新」用强调色）
    var valueHighlighted = false

    /// 图标列宽：分隔线从这里往右对齐标题（14 + 24 + 14）
    static let dividerInset: CGFloat = 52

    var body: some View {
        HStack(spacing: 14) {
            // 图标不再垫底色方块：线框图标直接摆在行首，和标题同色
            Image(systemName: symbol)
                .font(.system(size: 19, weight: Theme.iconWeight))
                .foregroundStyle(tone == .danger ? Theme.danger : Theme.textPrimary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15)).foregroundStyle(tone == .danger ? Theme.danger : Color.primary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 13, weight: valueHighlighted ? .semibold : .regular))
                    .foregroundStyle(valueHighlighted ? Theme.accent : Theme.textTertiary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: AppIcon.forward.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            .font(.system(size: 19, weight: Theme.iconWeight))
            .foregroundStyle(tint)
            .frame(width: 24)
    }
}

/// 主按钮：主操作色胶囊（深色模式白底黑字）。每屏只放一个。按下弹性缩小。
struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var light = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(light ? Color(uiColor: UIColor(hex: 0x12151C)) : Theme.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(light ? Color(uiColor: UIColor(hex: 0xF4F6FB)) : Theme.primaryAction, in: Capsule())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.4)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
    }
}

/// 次按钮：深灰胶囊 + 正文色字。
struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Theme.surfaceRaised, in: Capsule())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
    }
}

extension View {
    func libraryFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground.ignoresSafeArea())
            .tint(Theme.accent)
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
            VStack(alignment: .leading, spacing: 20) {
                if showsTitle || !subtitle.isEmpty {
                    PageIntroduction(eyebrow: eyebrow, title: title, subtitle: subtitle, showsTitle: showsTitle)
                }
                content()
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 14)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

struct DesignGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
    }
}

struct DesignField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Group {
                if secure { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.subheadline)
            .padding(14)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        }
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
        .font(.footnote)
        .foregroundStyle(warning ? Theme.warning : Theme.textSecondary)
        .lineSpacing(3)
    }
}

/// 筛选胶囊：选中是主操作色底（深色模式白底黑字），未选中只有灰字。
/// 同一排里选中状态的底色会滑到新选中的那个上（共用 `namespace` 即可）。
struct SelectionPill: View {
    let title: String
    let selected: Bool
    var namespace: Namespace.ID?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .font(.system(size: 13, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background { background }
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.93))
        .animation(reduceMotion ? nil : Motion.snappy, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
        if selected {
            if let namespace {
                Capsule().fill(Theme.primaryAction).matchedGeometryEffect(id: "pill.selection", in: namespace)
            } else {
                Capsule().fill(Theme.primaryAction)
            }
        }
    }
}
