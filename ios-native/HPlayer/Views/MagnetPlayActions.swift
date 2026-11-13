import SwiftUI
import UIKit

/// 磁力资源卡片（详情页的资源列表、磁力页的链接面板）底部的一排操作：
/// - 登录了 115：「115 播放」+「磁力播放」+ 复制。两种方式都能选，不再只按设置里的开关走一种
/// - 115 里已经下载好过的资源：主按钮直接是「播放」
/// - 点了「115 播放」：进度画在卡片上（提交 → 下载中 xx% → 准备播放），准备好后页面自动打开播放器，不遮住画面等
/// - 没登录 115：只有「磁力播放」+ 复制
/// 打开播放器由所在页面负责（onPlay），这样列表的格子被回收时播放窗口也不受影响。
struct MagnetPlayActions: View {
    let magnet: String
    let title: String
    /// 无障碍标识前缀：详情页是 magnet，链接面板是 magnet.link
    var identifierPrefix = "magnet"
    /// 打开播放窗口（BT 边下边播；或者 115 已经准备好）
    let onPlay: (MagnetPlaybackRequest.Mode) -> Void

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var relay = MagnetRelayCenter.shared
    @State private var copied = false

    private var hash: String? { MagnetLink.parse(magnet)?.infoHash }
    private var status: MagnetRelayCenter.Status? { relay.status(hash) }

    var body: some View {
        Group {
            if let status, status != .ready {
                progress(status)
                    .transition(.opacity)
            } else {
                buttons
                    .transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: status)
    }

    // MARK: 按钮

    private var buttons: some View {
        HStack(spacing: 8) {
            if appState.isAuthenticated {
                Button(action: playCloud) {
                    HStack(spacing: 6) {
                        Image(systemName: AppIcon.play.name)
                            .font(.scaled(12))
                        Text(relay.isDownloaded(hash) ? "播放" : "115 播放")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(MagnetActionStyle(prominent: true))
                .accessibilityHint(relay.isDownloaded(hash) ? "115 里已经有了，直接用 115 播放" : "交给 115 离线下载，好了以后用 115 播放")
                .accessibilityIdentifier("\(identifierPrefix).play")

                Button { onPlay(.bt) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: AppIcon.magnet.name)
                            .font(.scaled(13))
                        Text("磁力播放")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(MagnetActionStyle(prominent: false))
                .accessibilityHint("不经过 115，手机直接边下边播")
                .accessibilityIdentifier("\(identifierPrefix).bt")
            } else {
                Button { onPlay(.bt) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: AppIcon.play.name)
                            .font(.scaled(12))
                        Text("磁力播放")
                    }
                }
                .buttonStyle(MagnetActionStyle(prominent: true))
                .accessibilityIdentifier("\(identifierPrefix).play")
            }

            Button(action: copy) {
                Image(systemName: copied ? AppIcon.check.name : AppIcon.copy.name)
                    .font(.scaled(14))
                    .foregroundStyle(copied ? Theme.accent : Color.primary)
            }
            .buttonStyle(MagnetActionStyle(prominent: false))
            .frame(width: 52)
            .successPop(copied)
            .accessibilityLabel(copied ? "已复制" : "复制磁力链接")
            .accessibilityIdentifier("\(identifierPrefix).copy")
        }
    }

    // MARK: 115 进度

    @ViewBuilder
    private func progress(_ status: MagnetRelayCenter.Status) -> some View {
        if case .failed(let reason) = status {
            VStack(alignment: .leading, spacing: 8) {
                Text(reason)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("重试") {
                        relay.cancel(hash)
                        playCloud()
                    }
                    .buttonStyle(MagnetActionStyle(prominent: true))
                    .accessibilityIdentifier("\(identifierPrefix).retry")
                    Button("改用磁力播放") {
                        relay.cancel(hash)
                        onPlay(.bt)
                    }
                    .buttonStyle(MagnetActionStyle(prominent: false))
                    Button { relay.cancel(hash) } label: {
                        Image(systemName: AppIcon.close.name)
                            .font(.scaled(13, weight: .semibold))
                    }
                    .buttonStyle(MagnetActionStyle(prominent: false))
                    .frame(width: 52)
                    .accessibilityLabel("关闭")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if case .downloading = status {
                        EmptyView()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(label(status))
                        .font(Theme.Typo.meta.weight(.medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("取消") { relay.cancel(hash) }
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minHeight: 36)
                        .accessibilityIdentifier("\(identifierPrefix).cancel")
                }
                ThinProgressBar(fraction: fraction(status))
                Text("准备好后会自动开始播放；离开这一页也会在后台继续，好了会提醒你。")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifierPrefix).progress")
        }
    }

    private func label(_ status: MagnetRelayCenter.Status) -> String {
        switch status {
        case .submitting: return "正在提交到 115…"
        case .downloading(let percent): return percent > 0 ? "115 下载中 \(Int(percent))%" : "115 已接收，等待开始下载"
        case .preparing: return "正在准备播放…"
        case .ready: return "115 已准备好"
        case .failed(let reason): return reason
        }
    }

    private func fraction(_ status: MagnetRelayCenter.Status) -> Double {
        switch status {
        case .submitting: return 0.03
        case .downloading(let percent): return max(0.03, percent / 100)
        case .preparing, .ready: return 1
        case .failed: return 0
        }
    }

    // MARK: 操作

    private func playCloud() {
        Haptics.tap()
        relay.startCloud(magnet: magnet, title: title, client: appState.directClient())
    }

    private func copy() {
        UIPasteboard.general.string = magnet
        Haptics.success()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

extension View {
    /// 页面上的磁力资源：开着的时候关心它们的 115 进度，准备好了就打开播放器
    func magnetCloudReady(hashes: [String], open: @escaping (String) -> Void) -> some View {
        modifier(MagnetCloudReadyModifier(hashes: hashes, open: open))
    }
}

private struct MagnetCloudReadyModifier: ViewModifier {
    let hashes: [String]
    let open: (String) -> Void
    @ObservedObject private var relay = MagnetRelayCenter.shared
    @State private var watched: [String] = []
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                visible = true
                rewatch()
                deliver(relay.readyToOpen)
            }
            .onDisappear {
                visible = false
                relay.unwatch(watched)
                watched = []
            }
            .onChange(of: hashes) { _ in if visible { rewatch() } }
            .onChange(of: relay.readyToOpen) { hash in deliver(hash) }
    }

    private func rewatch() {
        let next = hashes.map { $0.lowercased() }
        relay.unwatch(watched)
        relay.watch(next)
        watched = next
    }

    private func deliver(_ hash: String?) {
        guard visible, let hash, watched.contains(hash) else { return }
        relay.consumeReady()
        open(hash)
    }
}
