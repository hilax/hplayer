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
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }
}

struct PrimaryActionStyle: ButtonStyle {
    var light = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(light ? Color(uiColor: UIColor(hex: 0x12151C)) : .white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(light ? Color(uiColor: UIColor(hex: 0xF4F6FB)) : Theme.primaryAction,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

extension View {
    func libraryFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground.ignoresSafeArea())
            .tint(Theme.accent)
    }
}
