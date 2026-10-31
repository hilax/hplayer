import SwiftUI

/// Shared typography and controls from the reviewed iOS prototype.
struct PageIntroduction: View {
    let eyebrow: String
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.6)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LibraryActionRow: View {
    let symbol: String
    let title: String
    var subtitle: String = ""
    var value: String = ""
    var showsChevron = true

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !value.isEmpty { Text(value).font(.caption).foregroundStyle(.secondary) }
            if showsChevron { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(16)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var light = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(light ? Color(uiColor: UIColor(hex: 0x12151C)) : .white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(light ? Color(uiColor: UIColor(hex: 0xF4F6FB)) : Theme.primaryAction,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageIntroduction(eyebrow: eyebrow, title: title, subtitle: subtitle)
                content()
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 18)
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
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if secure { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.subheadline)
            .padding(15)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 13))
        }
    }
}

struct DesignNotice: View {
    var symbol = "info.circle"
    let text: String
    var warning = false
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: { Image(systemName: symbol) }
        .font(.footnote)
        .foregroundStyle(warning ? Theme.warning : Color.secondary)
        .lineSpacing(3)
    }
}

struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

struct SelectionPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? (scheme == .dark ? Color.black : .white) : .secondary)
                .padding(.horizontal, 16).frame(minHeight: 36)
                .background(selected ? Color.primary : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
