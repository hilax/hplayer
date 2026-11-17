import SwiftUI
import UIKit
import Network
import CoreTelephony

/// 横屏播放时系统状态栏是隐藏的：播放器在最上面自己画一行状态，位置和系统状态栏对应——
/// 时间在正中，右上是网络类型、网速和电量。
/// - 网络视频：Wi-Fi 显示扇形图标，移动网络显示 5G / 4G / 3G，后面跟当前网速；网速低于 500 KB/s 变琥珀色，提示可能会卡
/// - 本机文件：没有网速，右上只显示电量
/// - 电量 ≤ 20% 且没在充电：电量数字和图标都变红
/// 时间每分钟刷新；电量、网络类型都跟系统通知走，不轮询。iOS 不对 App 开放信号强度，所以只显示类型、不画信号格。
struct PlayerStatusRow: View {
    /// 网速（字节 / 秒）。nil 表示本机文件：不显示网络类型和网速
    let networkSpeed: Double?

    @StateObject private var battery = BatteryMonitor()
    @StateObject private var network = NetworkKindMonitor()

    /// 状态行的高度；顶栏按钮在它下面
    static let height: CGFloat = 20
    /// 低于这个速度（字节 / 秒）网速变成琥珀色
    static let slowSpeed: Double = 500 * 1024

    var body: some View {
        ZStack {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.scaled(13, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                if let networkSpeed {
                    networkItem(speed: networkSpeed)
                }
                batteryItem
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(.white.opacity(0.92))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("playback.statusRow")
    }

    @ViewBuilder
    private func networkItem(speed: Double) -> some View {
        HStack(spacing: 5) {
            switch network.kind {
            case .wifi:
                WiFiGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    .overlay(alignment: .bottom) { Circle().frame(width: 2.6, height: 2.6).offset(y: -0.2) }
                    .frame(width: 15, height: 11)
            case .cellular(let generation):
                Text(generation)
                    .font(.scaled(11, weight: .bold))
            case .other, .offline:
                EmptyView()
            }
            if speed > 0 {
                HStack(spacing: 2) {
                    DownArrowGlyph()
                        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 8, height: 10)
                    Text(Self.speedText(speed))
                        .font(.scaled(12, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(speed < Self.slowSpeed ? Theme.HUD.playerAccent : Color.white.opacity(0.82))
            }
        }
        .accessibilityIdentifier("playback.network")
    }

    @ViewBuilder
    private var batteryItem: some View {
        if let level = battery.level {
            HStack(spacing: 3) {
                Text("\(Int((level * 100).rounded()))%")
                    .font(.scaled(12, weight: .semibold))
                    .monospacedDigit()
                Image(appIconNamed: battery.icon.name)
                    .font(.scaled(13, weight: .regular))
            }
            .foregroundStyle(battery.lowPower ? Theme.danger : Color.white.opacity(0.92))
        }
    }

    static func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        }
        return String(format: "%.0f KB/s", max(bytesPerSecond / 1024, 1))
    }

    private var accessibilityText: String {
        var parts = [battery.accessibilityText]
        if let networkSpeed {
            switch network.kind {
            case .wifi: parts.append("Wi-Fi")
            case .cellular(let generation): parts.append("移动网络 \(generation)")
            case .other, .offline: break
            }
            if networkSpeed > 0 { parts.append("网速 \(Self.speedText(networkSpeed))") }
        }
        return parts.joined(separator: "，")
    }
}

/// Wi-Fi 的两道弧（下面的圆点由调用方叠上去）
private struct WiFiGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.maxY - 1)
        for radius in [rect.height * 0.92, rect.height * 0.56] {
            path.addArc(center: center, radius: radius, startAngle: .degrees(-140), endAngle: .degrees(-40), clockwise: false)
        }
        return path
    }
}

/// 网速前面的向下小箭头
private struct DownArrowGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - rect.width / 2))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.width / 2))
        return path
    }
}

/// 当前联网方式：Wi-Fi、移动网络（带 5G / 4G 这类代数），其他（有线、模拟器）或没网。
/// 用 NWPathMonitor 判断走哪条网，移动网络的代数来自 CoreTelephony；都不需要权限。
@MainActor
private final class NetworkKindMonitor: ObservableObject {
    enum Kind: Equatable {
        case wifi
        case cellular(String)
        case other
        case offline
    }

    @Published private(set) var kind: Kind = .other
    private let monitor = NWPathMonitor()
    private let telephony = CTTelephonyNetworkInfo()
    private var radioObserver: NSObjectProtocol?
    private var lastPath: NWPath?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.lastPath = path
                self?.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.hplayer.player.network", qos: .utility))
        radioObserver = NotificationCenter.default.addObserver(forName: .CTServiceRadioAccessTechnologyDidChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        monitor.cancel()
        if let radioObserver { NotificationCenter.default.removeObserver(radioObserver) }
    }

    private func refresh() {
        guard let path = lastPath else { return }
        let next: Kind
        if path.status != .satisfied {
            next = .offline
        } else if path.usesInterfaceType(.wifi) {
            next = .wifi
        } else if path.usesInterfaceType(.cellular) {
            next = .cellular(generation)
        } else {
            next = .other
        }
        if next != kind { kind = next }
    }

    /// 正在用来上网的那张卡的制式，换成大家熟悉的「5G / 4G / 3G / 2G」
    private var generation: String {
        let technologies = telephony.serviceCurrentRadioAccessTechnology ?? [:]
        let current = telephony.dataServiceIdentifier.flatMap { technologies[$0] } ?? technologies.values.first
        switch current ?? "" {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
            return "5G"
        case CTRadioAccessTechnologyLTE:
            return "4G"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return "3G"
        case CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyCDMA1x:
            return "2G"
        default:
            return "蜂窝"
        }
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
