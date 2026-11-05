import SwiftUI

// 回收站、离线下载、下载管理这几个页面共用的小部件。

// MARK: - 带数量的分段切换

struct CountSegment: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

/// 页面顶部的分段切换：「进行中 2 | 已完成 14 | 失败 1」
struct CountSegmentedControl: View {
    let segments: [CountSegment]
    @Binding var selection: String
    var identifierPrefix = "library.segment"

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func segmentButton(_ segment: CountSegment) -> some View {
        let selected = segment.id == selection
        return Button {
            guard !selected else { return }
            Haptics.select()
            withAnimation(Motion.snappy) { selection = segment.id }
        } label: {
            HStack(spacing: 4) {
                Text(segment.title)
                Text(String(segment.count))
                    .font(.system(size: 11))
                    .opacity(0.8)
            }
            .font(.system(size: 14, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(selected ? Theme.surfaceHigh : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(segment.title) \(segment.count)")
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityIdentifier("\(identifierPrefix).\(segment.id)")
    }
}

// MARK: - 细进度条

/// 灰色轨道上的金色进度；暂停时变成灰色。
struct ThinProgressBar: View {
    let fraction: Double
    var paused = false

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                fill(width: fillWidth(in: proxy.size.width))
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }

    private func fillWidth(in total: CGFloat) -> CGFloat {
        guard clamped > 0 else { return 0 }
        return max(6, total * CGFloat(clamped))
    }

    @ViewBuilder
    private func fill(width: CGFloat) -> some View {
        if paused {
            Capsule().fill(Theme.textTertiary).frame(width: width)
        } else {
            Capsule()
                .fill(LinearGradient(colors: [Theme.goldDeep, Theme.gold], startPoint: .leading, endPoint: .trailing))
                .frame(width: width)
        }
    }
}

// MARK: - 提示条

/// 页面顶部的金色提示条：一个小图标加一段说明。
struct ManagementBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: AppIcon.info.name)
                .font(.system(size: 14, weight: Theme.iconWeight))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.tileTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 页面底部的按钮

/// 页面底部并排的两个胶囊按钮：次要的是深灰底，主要的是金色。高 50，比弹层里的按钮略高一点。
struct FooterButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Theme.onPrimary : Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(prominent ? Theme.primaryAction : Theme.surfaceHigh, in: Capsule())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.4)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - 文件夹路径条与行

/// 选择文件夹时的面包屑：点上级就回到那一级。
struct FolderTrailBar: View {
    let trail: [Crumb]
    let identifierPrefix: String
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(trail.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: AppIcon.forward.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    crumbButton(index: index, crumb: crumb)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 12)
    }

    private func crumbButton(index: Int, crumb: Crumb) -> some View {
        let last = index == trail.count - 1
        return Button {
            if !last {
                Haptics.tap()
                onSelect(index)
            }
        } label: {
            Text(index == 0 ? "网盘" : crumb.name)
                .font(.system(size: 13, weight: last ? .semibold : .regular))
                .foregroundStyle(last ? Theme.accent : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(maxWidth: 170, minHeight: 28)
                .background(last ? Theme.tileTint : Theme.surfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifierPrefix).crumb.\(index)")
    }
}

// MARK: - 时间文字

/// 回收站里「删除于」后面的时间：今天 10:32、昨天 22:08、10-30 19:45，跨年显示完整日期。
enum DeletedTimeText {
    static func text(_ date: Date?, now: Date = Date(), calendar: Calendar = Calendar.current) -> String {
        guard let date else { return "时间未知" }
        let clock = format(date, "HH:mm", calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 " + clock
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, sameYear ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm", calendar)
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
