import SwiftUI
import UIKit

/// 横屏播放时系统状态栏是隐藏的：在顶栏右边放一个小的「当前时间 + 电量」，看片时也知道几点、还剩多少电。
/// 时间每分钟刷新；电量跟系统的电量 / 充电状态通知走，不轮询。
struct PlayerStatusClock: View {
    @StateObject private var battery = BatteryMonitor()

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .monospacedDigit()
            }
            if let level = battery.level {
                HStack(spacing: 3) {
                    Text("\(Int((level * 100).rounded()))%")
                        .monospacedDigit()
                    Image(systemName: battery.icon.name)
                        .font(.scaled(13, weight: .regular))
                        .foregroundStyle(battery.lowPower ? Theme.danger : Color.white)
                }
            }
        }
        .font(.scaled(13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(battery.accessibilityText)
        .accessibilityIdentifier("playback.statusClock")
    }
}

@MainActor
private final class BatteryMonitor: ObservableObject {
    /// 0...1；模拟器等拿不到电量时为 nil，只显示时间
    @Published private(set) var level: Double?
    @Published private(set) var charging = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        refresh()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func refresh() {
        let device = UIDevice.current
        level = device.batteryLevel < 0 ? nil : Double(device.batteryLevel)
        charging = device.batteryState == .charging || device.batteryState == .full
    }

    var lowPower: Bool { !charging && (level ?? 1) <= 0.2 }

    var icon: AppIcon {
        if charging { return .batteryCharging }
        switch level ?? 1 {
        case ..<0.13: return .battery0
        case ..<0.38: return .battery25
        case ..<0.63: return .battery50
        case ..<0.88: return .battery75
        default: return .battery100
        }
    }

    var accessibilityText: String {
        let time = Date().formatted(date: .omitted, time: .shortened)
        guard let level else { return "现在 \(time)" }
        return "现在 \(time)，电量 \(Int((level * 100).rounded()))%\(charging ? "，正在充电" : "")"
    }
}
