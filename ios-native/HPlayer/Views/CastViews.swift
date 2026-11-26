import SwiftUI
import UIKit

/// 投屏设备选择面板：整合局域网 DLNA 设备列表（自动搜索 + 历史设备 + 手动输入 IP）与系统 AirPlay 入口。
struct CastDevicePickerView: View {
    @ObservedObject var castManager: CastManager
    @ObservedObject var discovery: DLNADiscovery
    let isLandscape: Bool
    let mediaTitle: String
    let isMKVOrUnsupportedAirPlay: Bool
    let onSelectDLNA: (CastDevice) -> Void
    let onPrepareAirPlay: () async -> Bool
    let onClose: () -> Void

    @State private var showManualForm = false
    @State private var manualInput = ""
    @State private var manualConnecting = false
    @State private var manualError = ""
    @State private var airplayBusy = false
    @State private var triggerAirPlayPicker: (() -> Void)?
    @FocusState private var manualFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    manualFocused = false
                    onClose()
                }
                .accessibilityHidden(true)

            card
                .frame(maxWidth: isLandscape ? 430 : 360)
                .frame(maxHeight: isLandscape ? 320 : 520)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cast.picker")
        .onAppear {
            discovery.startScan()
        }
        .onDisappear {
            discovery.stopScan()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if discovery.devices.isEmpty && !discovery.isScanning {
                discovery.startScan()
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(Theme.Opacity.faint))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !castManager.errorMessage.isEmpty {
                        errorBanner(castManager.errorMessage)
                    }

                    switch discovery.scanDiagnosis {
                    case .noWiFi:
                        hintBanner("当前未检测到 Wi-Fi 连接，请确认手机与电视/机顶盒连接至同一 Wi-Fi。")
                    case .localNetworkDenied:
                        errorBanner("未获得「本地网络」权限，请前往系统「设置 → 隐私与安全性 → 本地网络」开启 HPlayer 开关，返回后将自动重新搜索。")
                    case .multicastRestrictedNoDevices where discovery.devices.isEmpty:
                        hintBanner("已自动使用局域网单播扫描但暂未发现设备，请确认机顶盒已开启投屏接收、关闭拦截局域网的 VPN，或点击「手动添加」输入机顶盒 IP。")
                    case .multicastRestrictedNoDevices, .none:
                        EmptyView()
                    }

                    dlnaSection

                    if showManualForm {
                        manualAddForm
                    }

                    airplaySection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(Color.white)
        .background {
            CastGlassSurface(cornerRadius: Theme.Radius.sheet)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("投屏到设备")
                    .font(.scaled(17, weight: .bold))
                if !mediaTitle.isEmpty {
                    Text(mediaTitle)
                        .font(.scaled(12))
                        .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                discovery.startScan()
            } label: {
                Group {
                    if discovery.isScanning {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(icon: .refresh)
                            .font(.scaled(15, weight: .semibold))
                    }
                }
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(Theme.Opacity.faint), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新设备")
            .accessibilityIdentifier("cast.refresh")

            Button {
                manualFocused = false
                onClose()
            } label: {
                Image(icon: .close)
                    .font(.scaled(14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(Theme.Opacity.faint), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭投屏面板")
            .accessibilityIdentifier("cast.close")
        }
    }

    private var dlnaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(discovery.localWiFiIP.map { "DLNA 电视与盒子 · \($0)" } ?? "DLNA 电视与盒子")
                    .font(.scaled(12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation(Motion.snappy) {
                        showManualForm.toggle()
                        manualError = ""
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(icon: .add)
                            .font(.scaled(11, weight: .semibold))
                        Text(showManualForm ? "收起手动添加" : "手动添加")
                            .font(.scaled(12, weight: .medium))
                    }
                    .foregroundStyle(Theme.gold)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cast.manualToggle")
            }

            if discovery.devices.isEmpty {
                HStack(spacing: 10) {
                    if discovery.isScanning {
                        ProgressView()
                            .tint(Theme.gold)
                            .scaleEffect(0.85)
                        Text("正在搜索同一 Wi-Fi 下的设备…")
                            .font(.scaled(13))
                            .foregroundStyle(Color.white.opacity(Theme.Opacity.heavy))
                    } else {
                        Image(icon: .tv)
                            .font(.scaled(16))
                            .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                        Text("暂未发现 DLNA 设备，可刷新或点击右上角「手动添加」")
                            .font(.scaled(13))
                            .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(Theme.Opacity.hint), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(discovery.devices) { device in
                        dlnaRow(device)
                    }
                }
            }
        }
    }

    private func dlnaRow(_ device: CastDevice) -> some View {
        let isActive = castManager.activeDeviceID == device.id
        return HStack(spacing: 10) {
            Button {
                manualFocused = false
                onSelectDLNA(device)
            } label: {
                HStack(spacing: 12) {
                    Image(icon: .tv)
                        .font(.scaled(18, weight: .medium))
                        .foregroundStyle(isActive ? Theme.gold : Color.white)
                        .frame(width: 34, height: 34)
                        .background(
                            (isActive ? Theme.gold.opacity(Theme.Opacity.faint) : Color.white.opacity(Theme.Opacity.hint)),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.scaled(14, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Text(device.subtitleText)
                            .font(.scaled(11))
                            .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isActive {
                        Text("投屏中")
                            .font(.scaled(11, weight: .bold))
                            .foregroundStyle(Theme.onPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.gold, in: Capsule())
                    } else if castManager.isConnecting {
                        ProgressView()
                            .tint(Theme.gold)
                            .scaleEffect(0.8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(castManager.isConnecting)
            .accessibilityIdentifier("cast.device.\(device.id)")

            if discovery.isSaved(id: device.id) && !isActive {
                Button {
                    discovery.removeSavedDevice(id: device.id)
                } label: {
                    Image(icon: .trash)
                        .font(.scaled(13))
                        .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除保存的设备")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isActive ? Theme.gold.opacity(0.14) : Color.white.opacity(Theme.Opacity.hint),
            in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.55), lineWidth: 1)
            }
        }
    }

    private var manualAddForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入电视 IP（如 192.168.1.20）或描述链接", text: $manualInput)
                    .font(.scaled(13))
                    .foregroundStyle(Color.white)
                    .tint(Theme.gold)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($manualFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                    .accessibilityIdentifier("cast.manualInput")

                Button {
                    connectManual()
                } label: {
                    Group {
                        if manualConnecting {
                            ProgressView()
                                .tint(Theme.onPrimary)
                                .scaleEffect(0.75)
                        } else {
                            Text("连接")
                                .font(.scaled(13, weight: .bold))
                        }
                    }
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(manualConnecting)
                .accessibilityIdentifier("cast.manualConnect")
            }

            if !manualError.isEmpty {
                Text(manualError)
                    .font(.scaled(12))
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(10)
        .background(Color.white.opacity(Theme.Opacity.hint), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private var airplaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AirPlay 隔空播放")
                .font(.scaled(12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))

            Button {
                manualFocused = false
                Task { @MainActor in
                    airplayBusy = true
                    let ready = await onPrepareAirPlay()
                    airplayBusy = false
                    if ready {
                        triggerAirPlayPicker?()
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(icon: .airplay)
                        .font(.scaled(18, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(Theme.Opacity.hint), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("隔空播放（Apple TV / 支持 AirPlay 的电视）")
                            .font(.scaled(14, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Text(isMKVOrUnsupportedAirPlay
                             ? "当前为 MKV 等非原生格式：115 视频将尝试自动切至转码画质，本地/磁力建议用上方 DLNA"
                             : "使用 iOS 原生隔空播放选择器连接设备")
                            .font(.scaled(11))
                            .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 6)

                    if airplayBusy {
                        ProgressView()
                            .tint(Theme.gold)
                            .scaleEffect(0.8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(Theme.Opacity.hint), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(airplayBusy)
            .accessibilityIdentifier("cast.airplay")
            .background {
                AirPlayRoutePickerTrigger { action in
                    triggerAirPlayPicker = action
                }
                .frame(width: 1, height: 1)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(icon: .alert)
                .font(.scaled(13, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.scaled(12))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.danger.opacity(0.22), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private func hintBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(icon: .info)
                .font(.scaled(13, weight: .semibold))
                .foregroundStyle(Theme.gold)
            Text(message)
                .font(.scaled(12))
                .foregroundStyle(Color.white.opacity(Theme.Opacity.heavy))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private func connectManual() {
        manualFocused = false
        manualConnecting = true
        manualError = ""
        let raw = manualInput
        Task { @MainActor in
            defer { manualConnecting = false }
            do {
                let device = try await discovery.addManualDevice(input: raw)
                manualInput = ""
                withAnimation(Motion.snappy) { showManualForm = false }
                onSelectDLNA(device)
            } catch {
                manualError = error.localizedDescription
            }
        }
    }
}

/// 投屏遥控界面：盖在本地播放器画面区域上方，同时适配竖屏 16:9 小窗和横屏全屏。
struct CastRemoteOverlayView: View {
    @ObservedObject var castManager: CastManager
    let landscape: Bool
    let insets: EdgeInsets
    let title: String
    let items: [PlaybackListItem]
    let selectedID: String
    let qualities: [PlaybackChoice]
    let selectedQuality: String
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSelectEpisode: (String) -> Void
    let onOpenQuality: () -> Void
    let onSelectQuality: (String) -> Void
    let onSwitchDevice: () -> Void
    let onRetry: () -> Void
    let onExitCasting: () -> Void
    let onToggleOrientation: () -> Void
    let onClosePlayer: () -> Void

    private enum InlineSubpanel {
        case episodes, qualities
    }

    @State private var dragging = false
    @State private var scrubberHaptics = SeekHapticTracker()
    @State private var dragTime: Double = 0
    @State private var subpanel: InlineSubpanel?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.08), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )

            if landscape {
                landscapeLayout
            } else {
                portraitLayout
            }

            if let subpanel {
                subpanelOverlay(subpanel)
                    .zIndex(5)
            }
        }
        .foregroundStyle(Color.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cast.remote")
    }

    // MARK: - 横屏遥控布局

    private var landscapeLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CastCircleButton(icon: .close, label: "关闭播放", action: onClosePlayer)
                    .accessibilityIdentifier("playback.close")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("投屏至 \(castManager.activeDeviceName)")
                        .font(.caption)
                        .foregroundStyle(Theme.gold)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 10) {
                    CastCircleButton(icon: .cast, label: "切换投屏设备", highlighted: true, action: onSwitchDevice)
                        .accessibilityIdentifier("playback.cast")
                }
            }
            .padding(.horizontal, max(insets.leading, 28))
            .padding(.top, max(insets.top, 14))

            Spacer(minLength: 10)

            centerCard(compact: false)

            Spacer(minLength: 10)

            VStack(spacing: 8) {
                scrubberRow

                ZStack {
                    HStack(spacing: 0) {
                        if !qualities.isEmpty {
                            Button {
                                onOpenQuality()
                                withAnimation(Motion.snappy) { subpanel = .qualities }
                            } label: {
                                Text(selectedQuality.isEmpty ? "画质" : selectedQuality)
                                    .font(.scaled(13, weight: .semibold))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .background(Color.white.opacity(Theme.Opacity.faint), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        if items.count > 1 {
                            Button {
                                withAnimation(Motion.snappy) { subpanel = .episodes }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(icon: .playlist)
                                        .font(.scaled(14, weight: .semibold))
                                    Text("选集")
                                        .font(.scaled(13, weight: .semibold))
                                }
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(Color.white.opacity(Theme.Opacity.faint), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Button(action: onToggleOrientation) {
                            Image(icon: .exitFullscreen)
                                .font(.scaled(17, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("playback.orientation")
                    }

                    transportRow(compact: false)
                }
            }
            .padding(.horizontal, max(insets.leading, 28))
            .padding(.bottom, max(insets.bottom, 16))
        }
    }

    // MARK: - 竖屏小窗遥控布局

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CastCircleButton(icon: .expand, label: "关闭播放", action: onClosePlayer)
                    .accessibilityIdentifier("playback.close")

                Text(castManager.activeDeviceName)
                    .font(.scaled(12, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.gold.opacity(0.16), in: Capsule())

                Spacer(minLength: 4)

                CastCircleButton(icon: .cast, label: "切换投屏设备", highlighted: true, action: onSwitchDevice)
                    .accessibilityIdentifier("playback.cast")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer(minLength: 4)

            centerCard(compact: true)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                transportRow(compact: true)
                scrubberRow
                Button(action: onToggleOrientation) {
                    Image(icon: .fullscreen)
                        .font(.scaled(16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playback.orientation")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 中央状态与操作卡

    private func centerCard(compact: Bool) -> some View {
        let isAirPlay: Bool = {
            if case .airplay = castManager.mode { return true }
            return false
        }()
        return VStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 10) {
                Image(icon: isAirPlay ? .airplay : .tv)
                    .font(.scaled(compact ? 18 : 24, weight: .medium))
                    .foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(castManager.activeDeviceName)
                        .font(.scaled(compact ? 14 : 16, weight: .bold))
                        .lineLimit(1)
                    Text(castManager.errorMessage.isEmpty ? castManager.statusText : castManager.errorMessage)
                        .font(.scaled(compact ? 11 : 13))
                        .foregroundStyle(castManager.errorMessage.isEmpty ? Color.white.opacity(Theme.Opacity.heavy) : Theme.danger)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                if !castManager.errorMessage.isEmpty {
                    pillButton("重试", accent: true, action: onRetry)
                }
                pillButton("换设备", accent: false, action: onSwitchDevice)
                    .accessibilityIdentifier("cast.switchDevice")
                pillButton("退出投屏", accent: false, action: onExitCasting)
                    .accessibilityIdentifier("cast.exit")

                if castManager.canAdjustVolume, let vol = castManager.volume {
                    HStack(spacing: 6) {
                        Button { castManager.adjustVolume(delta: -5) } label: {
                            Image(icon: .volumeLow)
                                .font(.scaled(12, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(Theme.Opacity.faint), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("减小电视音量")

                        Text("\(vol)%")
                            .font(.scaled(11, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 30)

                        Button { castManager.adjustVolume(delta: 5) } label: {
                            Image(icon: .volumeHigh)
                                .font(.scaled(12, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(Theme.Opacity.faint), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("增大电视音量")
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, compact ? 14 : 22)
        .padding(.vertical, compact ? 10 : 16)
        .background(Color.white.opacity(Theme.Opacity.hint), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(Theme.Opacity.faint), lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
    }

    private func pillButton(_ label: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.scaled(12, weight: .semibold))
                .foregroundStyle(accent ? Theme.onPrimary : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(accent ? Theme.gold : Color.white.opacity(Theme.Opacity.faint), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 播控与进度条

    private func transportRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 16) {
            if !compact {
                Button(action: onPrevious) {
                    Image(icon: .previous)
                        .font(.scaled(16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(Theme.Opacity.hint), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!hasPrevious)
                .opacity(hasPrevious ? 1 : 0.35)
            }

            Button {
                castManager.togglePlayPause()
            } label: {
                Image(icon: castManager.isPlaying ? .pause : .play)
                    .font(.scaled(compact ? 16 : 22, weight: .semibold))
                    .frame(width: compact ? 36 : 48, height: compact ? 36 : 48)
                    .background(Color.white.opacity(Theme.Opacity.faint), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(castManager.isPlaying ? "暂停投屏" : "继续投屏")
            .accessibilityIdentifier("cast.playPause")

            if !compact {
                Button(action: onNext) {
                    Image(icon: .next)
                        .font(.scaled(16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(Theme.Opacity.hint), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!hasNext)
                .opacity(hasNext ? 1 : 0.35)
            }
        }
    }

    private var scrubberRow: some View {
        let total = max(castManager.duration, 0)
        let shown = dragging ? dragTime : min(castManager.currentTime, total > 0 ? total : castManager.currentTime)
        let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0

        return HStack(spacing: 8) {
            Text(formatClock(shown))
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let fillWidth = width * fraction
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.24))
                        .frame(height: dragging ? 7 : 4)
                    Capsule()
                        .fill(Theme.gold)
                        .frame(width: max(0, fillWidth), height: dragging ? 7 : 4)
                    Circle()
                        .fill(Color.white)
                        .frame(width: dragging ? 16 : 12, height: dragging ? 16 : 12)
                        .offset(x: min(max(0, fillWidth - (dragging ? 8 : 6)), max(0, width - (dragging ? 16 : 12))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard total > 0 else { return }
                            let ratio = min(max(value.location.x / width, 0), 1)
                            let nextTime = ratio * total
                            if !dragging {
                                dragging = true
                                PlayerHaptics.prepareForSeek()
                                PlayerHaptics.fire(scrubberHaptics.begin(at: castManager.currentTime, duration: total))
                            }
                            dragTime = nextTime
                            PlayerHaptics.fire(scrubberHaptics.update(target: nextTime, duration: total))
                        }
                        .onEnded { value in
                            guard total > 0 else { return }
                            let ratio = min(max(value.location.x / width, 0), 1)
                            let target = ratio * total
                            dragging = false
                            PlayerHaptics.fire(scrubberHaptics.end(finalTarget: target))
                            castManager.seek(to: target)
                        }
                )
            }
            .frame(height: 28)

            Text(total > 0 ? formatClock(total) : "00:00")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(Theme.Opacity.strong))
                .lineLimit(1)
        }
    }

    // MARK: - 横屏投屏期间的选集/画质浮层

    private func subpanelOverlay(_ kind: InlineSubpanel) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.snappy) { subpanel = nil }
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(kind == .episodes ? "选择剧集" : "切换画质")
                        .font(.scaled(15, weight: .bold))
                    Spacer()
                    Button {
                        withAnimation(Motion.snappy) { subpanel = nil }
                    } label: {
                        Image(icon: .close)
                            .font(.scaled(13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(Theme.Opacity.faint), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(spacing: 6) {
                        if kind == .episodes {
                            ForEach(items) { item in
                                let active = item.id == selectedID
                                Button {
                                    subpanel = nil
                                    onSelectEpisode(item.id)
                                } label: {
                                    HStack {
                                        Text(item.title)
                                            .font(.scaled(13, weight: active ? .bold : .medium))
                                            .foregroundStyle(active ? Theme.gold : Color.white)
                                            .lineLimit(1)
                                        Spacer()
                                        if active {
                                            Image(icon: .check)
                                                .font(.scaled(12, weight: .bold))
                                                .foregroundStyle(Theme.gold)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color.white.opacity(active ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            ForEach(qualities) { choice in
                                let active = choice.title == selectedQuality
                                Button {
                                    subpanel = nil
                                    onSelectQuality(choice.id)
                                } label: {
                                    HStack {
                                        Text(choice.title)
                                            .font(.scaled(13, weight: active ? .bold : .medium))
                                            .foregroundStyle(active ? Theme.gold : Color.white)
                                        Spacer()
                                        if active {
                                            Image(icon: .check)
                                                .font(.scaled(12, weight: .bold))
                                                .foregroundStyle(Theme.gold)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color.white.opacity(active ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(16)
            .frame(maxWidth: 320, maxHeight: 280)
            .background { CastGlassSurface(cornerRadius: Theme.Radius.sheet) }
        }
    }

    private func formatClock(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let seconds = Int(value)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CastCircleButton: View {
    let icon: AppIcon
    let label: String
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon: icon)
                .font(.scaled(15, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.gold : Color.white)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(highlighted ? 0.2 : Theme.Opacity.faint), in: Circle())
                .overlay {
                    if highlighted {
                        Circle().strokeBorder(Theme.gold.opacity(0.6), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct CastGlassSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            Color.black.opacity(0.45)
                .glassEffect(.regular, in: shape)
                .overlay {
                    shape.strokeBorder(Color.white.opacity(Theme.Opacity.faint), lineWidth: 0.5)
                }
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.65))
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(Theme.Opacity.faint), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
        }
    }
}
