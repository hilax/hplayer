import SwiftUI
import UIKit

// MARK: - 统一 HUD 提示
//
// 全应用所有一闪而过的提示都走这里，页面只说「提示什么」，
// 样式、位置、时长、震动、读屏都在这一处（配置在 Theme.HUD）。
//
// 四种 HUD：
// ① 页面轻提示：普通页面底部          HUD.show("已还原 3 项", .success)
// ② 进度 HUD：屏幕正中，挡住重复点击   .hudProgress(operation)，做完再 HUD.show 结果
// ③ 面板轻提示：弹窗、半屏面板顶部      同 ①，由 .hudHost(.sheet) 决定位置
// ④ 播放器 HUD：播放画面顶部居中，深色   PlayerLevelHUD / PlayerSeekHUD / PlayerNoticeHUD
//
// 每个「容器」挂一次 .hudHost(...)：根视图 .page，弹窗 / 面板 .sheet，播放窗口 .player。
// 同一时间只显示一条，出现在最上层（最后出现）的容器里。

/// 提示的语气：决定图标、图标颜色、震动和停留时长
enum HUDTone: Equatable {
    case neutral, success, warning, error
}

/// 提示上的按钮（例如「去播放」）
struct HUDAction {
    let title: String
    let perform: () -> Void
}

struct HUDMessage: Identifiable {
    let id = UUID()
    let text: String
    let tone: HUDTone
    let action: HUDAction?
}

/// 提示出现在哪种容器里
enum HUDPlacement {
    /// 普通页面：底部
    case page
    /// 弹窗、半屏面板：顶部（底部会被键盘挡住）
    case sheet
    /// 播放窗口：画面顶部居中，深色玻璃
    case player
}

// MARK: - 调用入口

@MainActor
enum HUD {
    /// 轻提示：几秒后自己消失
    static func show(_ text: String, _ tone: HUDTone = .neutral) {
        HUDCenter.shared.show(text, tone: tone, action: nil)
    }

    /// 带一个按钮的轻提示（停留更久）
    static func show(_ text: String, _ tone: HUDTone = .neutral, action title: String, perform: @escaping () -> Void) {
        HUDCenter.shared.show(text, tone: tone, action: HUDAction(title: title, perform: perform))
    }

    /// 收起当前提示
    static func dismiss() {
        HUDCenter.shared.dismiss()
    }
}

/// 提示中心：只保存「当前这一条」和已挂上的容器
@MainActor
final class HUDCenter: ObservableObject {
    static let shared = HUDCenter()

    @Published private(set) var current: HUDMessage?
    /// 已挂上的容器，最后一个是最上层，提示只在它里面出现
    @Published private(set) var hosts: [UUID] = []

    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, tone: HUDTone, action: HUDAction?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 同一句话重复触发：只重新计时，不再闪一次
        if let current, current.text == text, current.tone == tone, action == nil, current.action == nil {
            schedule(current)
            return
        }
        let message = HUDMessage(text: text, tone: tone, action: action)
        current = message
        Theme.HUD.haptic(for: tone)
        UIAccessibility.post(notification: .announcement, argument: text)
        schedule(message)
    }

    func dismiss(_ id: UUID? = nil) {
        guard let current, id == nil || current.id == id else { return }
        dismissTask?.cancel()
        self.current = nil
    }

    func register(_ token: UUID) {
        hosts.removeAll { $0 == token }
        hosts.append(token)
    }

    func unregister(_ token: UUID) {
        hosts.removeAll { $0 == token }
    }

    private func schedule(_ message: HUDMessage) {
        dismissTask?.cancel()
        let seconds = Theme.HUD.duration(for: message.tone, hasAction: message.action != nil)
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.current?.id == message.id else { return }
            self.current = nil
        }
    }
}

// MARK: - 容器

extension View {
    /// 挂一个提示容器：根视图 .page，弹窗 / 面板 .sheet，播放窗口 .player
    func hudHost(_ placement: HUDPlacement) -> some View {
        modifier(HUDHostModifier(placement: placement))
    }

    /// 进度 HUD：`text` 不为空时盖住这一页，挡住重复点击。做完把它设回 nil，再 HUD.show 结果。
    func hudProgress(_ text: String?) -> some View {
        modifier(HUDProgressModifier(text: text))
    }
}

private struct HUDHostModifier: ViewModifier {
    let placement: HUDPlacement
    @ObservedObject private var center = HUDCenter.shared
    @State private var token = UUID()

    private var message: HUDMessage? {
        center.hosts.last == token ? center.current : nil
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: placement == .page ? .bottom : .top) {
                if let message {
                    toast(message)
                        .id(message.id)
                }
            }
            .animation(Motion.smooth, value: message?.id)
            .onAppear { center.register(token) }
            .onDisappear { center.unregister(token) }
    }

    @ViewBuilder
    private func toast(_ message: HUDMessage) -> some View {
        switch placement {
        case .page:
            HUDToast(message: message)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.HUD.pageBottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .sheet:
            HUDToast(message: message)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.HUD.sheetTopInset)
                .transition(.move(edge: .top).combined(with: .opacity))
        case .player:
            PlayerNoticeHUD(text: message.text, tone: message.tone, action: message.action.map { action in
                HUDAction(title: action.title) {
                    HUDCenter.shared.dismiss(message.id)
                    action.perform()
                }
            })
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.HUD.playerTopInset)
            .transition(.opacity)
        }
    }
}

// MARK: - ① ③ 轻提示

/// 页面 / 面板里的轻提示：浮起的卡片，单行时是胶囊。颜色只上图标，文字统一主文字色。
struct HUDToast: View {
    let message: HUDMessage

    var body: some View {
        HStack(spacing: Theme.Space.sm + 2) {
            if let icon = Theme.HUD.icon(for: message.tone) {
                Image(appIconNamed: icon.name)
                    .font(.scaled(16, weight: .semibold))
                    .foregroundStyle(Theme.HUD.tint(for: message.tone))
                    .accessibilityHidden(true)
            }
            Text(message.text)
                .font(Theme.Typo.row.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let action = message.action {
                Button {
                    HUDCenter.shared.dismiss(message.id)
                    action.perform()
                } label: {
                    Text(action.title)
                        .font(Theme.Typo.button)
                        .foregroundStyle(Theme.onPrimary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .background(Theme.primaryAction, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hud.toast.action")
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .floatingSurface(cornerRadius: Theme.HUD.toastRadius)
        // 没有按钮时点不到，也不拦下面的手势
        .allowsHitTesting(message.action != nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.toast")
    }
}

// MARK: - ② 进度 HUD

private struct HUDProgressModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let text {
                    HUDProgressView(text: text)
                }
            }
            .animation(Motion.smooth, value: text)
    }
}

/// 操作进行中：浅色遮罩 + 正中的卡片，挡住重复点击，并告诉用户在做什么
struct HUDProgressView: View {
    let text: String

    var body: some View {
        ZStack {
            Theme.HUD.scrim.ignoresSafeArea()
            HStack(spacing: Theme.Space.md) {
                ProgressView().tint(Theme.textSecondary)
                Text(text)
                    .font(Theme.Typo.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, Theme.Space.page + 6)
            .padding(.vertical, Theme.Space.lg)
            .floatingSurface(cornerRadius: Theme.Radius.card + 2)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hud.progress")
    }
}

// MARK: - ④ 播放器 HUD（永远是深色玻璃，白字）

/// 亮度、音量：图标 + 进度条 + 百分比
struct PlayerLevelHUD: View {
    enum Kind { case brightness, volume }

    let kind: Kind
    let value: Double
    let width: CGFloat

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        HStack(spacing: width < 180 ? 8 : 12) {
            Image(appIconNamed: icon.name)
                .font(.scaled(16, weight: .semibold))
                .frame(width: 22)
            PlayerHUDBar(value: clamped)
                .frame(height: 6)
            Text("\(Int((clamped * 100).rounded()))%")
                .font(.scaled(13, weight: .bold).monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, width < 180 ? 10 : 16)
        .frame(width: width, height: 44)
        .glassCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .brightness ? "亮度" : "音量")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
        .accessibilityIdentifier("playback.levelHUD")
    }

    private var icon: AppIcon {
        switch kind {
        case .brightness:
            return clamped < 0.35 ? .brightnessLow : .brightnessHigh
        case .volume:
            if clamped <= 0.001 { return .volumeMute }
            if clamped < 0.34 { return .volumeLow }
            if clamped < 0.67 { return .volumeMedium }
            return .volumeHigh
        }
    }
}

/// 左右滑快进快退：不加底板；上面是目标时间，下面是跳了多少（琥珀色），可选一条细进度条和总时长。
/// 正片播放器和短剧共用。正片竖屏时画面很矮，只带进度条、不带总时长，免得挡住画面中间。
struct PlayerSeekHUD: View {
    let time: String
    let delta: String
    var progress: Double? = nil
    var total: String? = nil
    /// 横滑过程中手指下滑触发「取消本次跳转」时的视觉反馈
    var cancelled: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            Text(time)
                .font(.scaled(34, weight: .bold).monospacedDigit())
                .opacity(cancelled ? 0.52 : 1)
            Text(cancelled ? "松手取消跳转" : delta)
                .font(.scaled(15, weight: .bold).monospacedDigit())
                .foregroundStyle(cancelled ? Theme.warning : Theme.HUD.playerAccent)
            if let progress {
                PlayerHUDBar(value: min(max(progress, 0), 1))
                    .frame(width: 180, height: 4)
                    .opacity(cancelled ? 0.4 : 1)
                    .padding(.top, 6)
            }
            if let total {
                Text(total)
                    .font(.scaled(12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondaryOnArtwork)
                    .opacity(cancelled ? 0.55 : 1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(Theme.Opacity.heavy), radius: 8, y: 1)
        .shadow(color: .black.opacity(Theme.Opacity.strong), radius: 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playback.seekHUD")
    }
}

/// 一句话提示：暂时不能拖动、已经是最后一集了；全局提示落到播放窗口时也用它
struct PlayerNoticeHUD: View {
    let text: String
    var tone: HUDTone = .neutral
    var action: HUDAction? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(appIconNamed: (Theme.HUD.icon(for: tone) ?? .info).name)
                .font(.scaled(14, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
            if let action {
                Button(action: action.perform) {
                    Text(action.title)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 28)
                        .background(Theme.paper, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
        .glassCapsule()
        .allowsHitTesting(action != nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.noticeHUD")
    }
}

private struct PlayerHUDBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(Theme.Opacity.soft))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * value)
            }
        }
    }
}

// MARK: - 复制反馈（不弹 HUD，按钮原地变「已复制」）

/// 复制到剪贴板 + 统一的「已复制」反馈：时长、震动、动画都在这里。
/// 一个页面有多个复制按钮时用 key 区分是哪一个刚被复制。
@MainActor
final class CopyFeedback: ObservableObject {
    @Published private(set) var copiedKey: String?
    private var resetTask: Task<Void, Never>?

    func copy(_ text: String, key: String = "") {
        UIPasteboard.general.string = text
        Haptics.select()
        withAnimation(Motion.snappy) { copiedKey = key }
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Theme.HUD.copiedDuration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(Motion.snappy) { self.copiedKey = nil }
        }
    }

    func isCopied(_ key: String = "") -> Bool { copiedKey == key }

    /// 换了内容（例如播放器换了一集）时立刻还原
    func reset() {
        resetTask?.cancel()
        copiedKey = nil
    }
}

/// 番号旁边的「复制番号」小胶囊
struct CopyCodeChip: View {
    let code: String
    @StateObject private var copier = CopyFeedback()

    var body: some View {
        Button {
            copier.copy(code)
        } label: {
            HStack(spacing: 4) {
                Image(appIconNamed: copier.isCopied() ? AppIcon.check.name : AppIcon.copy.name)
                Text(copier.isCopied() ? "已复制" : "复制番号")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(copier.isCopied() ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copier.isCopied() ? "已复制番号" : "复制番号")
    }
}
