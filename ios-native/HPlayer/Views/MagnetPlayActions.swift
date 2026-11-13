import SwiftUI
import UIKit

/// 磁力资源卡片（详情页的资源列表、磁力页的链接面板）底部的一排操作：
/// - 登录了 115：「115 播放」+「磁力播放」+ 复制。两种方式都能选，不再只按设置里的开关走一种
/// - 115 里已经下载好过的资源：主按钮直接是「播放」
/// - 点了「115 播放」：进度画在卡片上（提交 → 下载中 xx% → 准备播放），准备好后页面自动打开播放器，不遮住画面等
/// - 点了「磁力播放」：同样在卡片上显示（连接节点 → 读取文件列表），文件列表到了就打开播放器
/// - 115 里已经有了的资源：「播放」直接打开播放器
/// - 没登录 115：只有「磁力播放」+ 复制
/// 打开播放器由所在页面负责（onPlay），这样列表的格子被回收时播放窗口也不受影响。
struct MagnetPlayActions: View {
    let magnet: String
    let title: String
    /// 无障碍标识前缀：详情页是 magnet，链接面板是 magnet.link
    var identifierPrefix = "magnet"
    /// 打开播放窗口（卡片上已经准备好的那份，或者 115 里已经下载好的资源）
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
                Button(action: playPrimary) {
                    HStack(spacing: 6) {
                        Image(systemName: AppIcon.play.name)
                            .font(.scaled(12))
                        Text(primaryTitle)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(MagnetActionStyle(prominent: true))
                .accessibilityHint(relay.isDownloaded(hash) ? "115 里已经有了，直接用 115 播放" : "交给 115 离线下载，好了以后用 115 播放")
                .accessibilityIdentifier("\(identifierPrefix).play")

                Button(action: playBT) {
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
                Button(action: playBT) {
                    HStack(spacing: 6) {
                        Image(systemName: AppIcon.play.name)
                            .font(.scaled(12))
                        Text(relay.readyMode(hash) == .bt ? "播放" : "磁力播放")
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
                        let mode = failedMode
                        relay.cancel(hash)
                        if mode == .bt { playBT() } else { playCloud() }
                    }
                    .buttonStyle(MagnetActionStyle(prominent: true))
                    .accessibilityIdentifier("\(identifierPrefix).retry")
                    if appState.isAuthenticated {
                        Button(failedMode == .bt ? "改用 115 播放" : "改用磁力播放") {
                            let mode = failedMode
                            relay.cancel(hash)
                            if mode == .bt { playCloud() } else { playBT() }
                        }
                        .buttonStyle(MagnetActionStyle(prominent: false))
                    }
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
                Text(isBT(status) ? "文件列表到了会自动开始播放，开头缓冲在播放器里进行。" : "准备好后会自动开始播放；离开这一页也会在后台继续，好了会提醒你。")
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
        case .connecting(let peers): return peers > 0 ? "磁力解析：已连上 \(peers) 个节点" : "磁力解析：正在找节点…"
        case .reading: return "磁力解析：正在读取文件列表…"
        case .submitting: return "正在提交到 115…"
        case .downloading(let percent): return percent > 0 ? "115 下载中 \(Int(percent))%" : "115 已接收，等待开始下载"
        case .preparing: return "正在准备播放…"
        case .ready: return "115 已准备好"
        case .failed(let reason): return reason
        }
    }

    private func fraction(_ status: MagnetRelayCenter.Status) -> Double {
        switch status {
        case .connecting(let peers): return peers > 0 ? 0.33 : 0.08
        case .reading: return 0.66
        case .submitting: return 0.03
        case .downloading(let percent): return max(0.03, percent / 100)
        case .preparing, .ready: return 1
        case .failed: return 0
        }
    }

    // MARK: 操作

    private var primaryTitle: String {
        if relay.readyMode(hash) != nil || relay.isDownloaded(hash) { return "播放" }
        return "115 播放"
    }

    /// 卡片上那份已经准备好：直接打开；115 里已经有了：直接用 115 打开（播放器里很快就能开播）；否则交给 115
    private func playPrimary() {
        if let mode = relay.readyMode(hash) {
            onPlay(mode)
        } else if relay.isDownloaded(hash) {
            Haptics.tap()
            onPlay(.cloud)
        } else {
            playCloud()
        }
    }

    private func playBT() {
        if relay.readyMode(hash) == .bt {
            onPlay(.bt)
            return
        }
        Haptics.tap()
        relay.startBT(magnet: magnet, title: title)
    }

    private var failedMode: MagnetPlaybackRequest.Mode { relay.failedMode(hash) ?? .cloud }

    private func isBT(_ status: MagnetRelayCenter.Status) -> Bool {
        switch status {
        case .connecting, .reading: return true
        default: return false
        }
    }

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
    func magnetCloudReady(hashes: [String], open: @escaping (String, MagnetPlaybackRequest.Mode) -> Void) -> some View {
        modifier(MagnetCloudReadyModifier(hashes: hashes, open: open))
    }
}

/// 页面在导航栈里的这段时间都算「开着」：播放窗口打开时主窗口会被隐藏，
/// SwiftUI 会发 onDisappear，所以不能靠出现 / 消失来判断；页面真正被移除时这个对象才释放。
@MainActor
private final class MagnetWatchToken: ObservableObject {
    private(set) var hashes: [String] = []

    func update(_ next: [String]) {
        let normalized = next.map { $0.lowercased() }
        guard normalized != hashes else { return }
        MagnetRelayCenter.shared.unwatch(hashes)
        MagnetRelayCenter.shared.watch(normalized)
        hashes = normalized
    }

    deinit {
        let old = hashes
        Task { @MainActor in MagnetRelayCenter.shared.unwatch(old) }
    }
}

private struct MagnetCloudReadyModifier: ViewModifier {
    let hashes: [String]
    let open: (String, MagnetPlaybackRequest.Mode) -> Void
    @ObservedObject private var relay = MagnetRelayCenter.shared
    @StateObject private var token = MagnetWatchToken()

    func body(content: Content) -> some View {
        content
            .onAppear {
                token.update(hashes)
                deliver(relay.readyToOpen)
            }
            .onChange(of: hashes) { next in token.update(next) }
            .onChange(of: relay.readyToOpen) { item in deliver(item) }
    }

    private func deliver(_ item: MagnetRelayCenter.ReadyItem?) {
        guard let item, token.hashes.contains(item.hash) else { return }
        relay.consumeReady()
        open(item.hash, item.mode)
    }
}
