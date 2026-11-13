import SwiftUI
import UIKit

/// 点「播放」时要打开的磁力资源。封面用来做播放窗口里等待时的模糊背景。
struct MagnetPlaybackRequest: Identifiable {
    let id = UUID()
    let magnet: String
    var title: String = ""
    var coverURL: URL? = nil

    var infoHash: String? { MagnetLink.parse(magnet)?.infoHash }
}

extension View {
    /// 播放器优先：点了播放立刻打开播放窗口，解析 / 115 离线的进度直接显示在窗口里，准备好就开播。
    func magnetPlayer(item: Binding<MagnetPlaybackRequest?>) -> some View {
        playerWindow(item: item) { request in
            MagnetLaunchPlayer(request: request)
        }
    }
}

/// 播放窗口里的磁力播放：
/// - 选了「使用 115 解析」：提交到 115 → 115 下载中 → 准备播放，完成后和片库里的 115 文件一样播放（画质、进度、继续观看截图）
/// - 没选：软件自带的 BT 解析，连上节点、读到文件列表后边下边播
/// - 多个视频时先播最大的那个（看过的话接着上次那一集），其余的在「选集」里
/// 解析和离线的流程都在 MagnetController 里，这里只决定显示什么、什么时候开播。
struct MagnetLaunchPlayer: View {
    let request: MagnetPlaybackRequest

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissPlayerWindow) private var dismissWindow
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true
    @StateObject private var controller: MagnetController
    /// 交给后台后窗口关闭时不要停掉控制器
    @State private var parked = false
    @State private var autoPlayed = false
    @State private var watchedBT = false

    init(request: MagnetPlaybackRequest) {
        self.request = request
        // 「后台继续」过的资源：接手那份控制器，不重新提交离线任务
        let hash = request.infoHash
        _controller = StateObject(wrappedValue: MagnetRelayCenter.shared.take(infoHash: hash) ?? MagnetController())
    }

    var body: some View {
        Group {
            if let queue = controller.cloudQueue {
                // 115 离线好了：就是一个普通的 115 文件，用片库同一个播放器
                PlayerView(source: queue.source, playlist: queue.items)
            } else if controller.playerVisible {
                MagnetLaunchWatch(controller: controller)
            } else {
                MagnetLaunchStage(
                    controller: controller,
                    title: displayTitle,
                    coverURL: request.coverURL,
                    canPark: canPark,
                    onCancel: close,
                    onPark: park
                )
            }
        }
        .task {
            guard !InterfacePreview.active else { return }
            controller.activate()
            controller.configureCloud(client: appState.directClient(), enabled: cloudRelay)
            if let link = MagnetLink.parse(request.magnet) {
                controller.open(link)
            }
            autoPlayIfReady()
        }
        .onChange(of: controller.phase) { _ in autoPlayIfReady() }
        .onChange(of: controller.catalog != nil) { _ in autoPlayIfReady() }
        .onChange(of: controller.playerVisible) { visible in
            if visible { watchedBT = true; return }
            // 关掉了边下边播的播放器（换成 115 播放时 cloudQueue 会接上，不算关闭）
            if watchedBT, controller.cloudQueue == nil { close() }
        }
        .onDisappear {
            if !parked { controller.deactivate() }
        }
    }

    private var displayTitle: String {
        if !request.title.isEmpty { return request.title }
        return controller.catalog?.name ?? controller.link?.displayName ?? "磁力资源"
    }

    /// 只有 115 离线还在云端跑的时候，关掉窗口也不耽误
    private var canPark: Bool {
        guard controller.usesCloud else { return false }
        switch controller.cloud {
        case .submitting, .downloading: return true
        case .off, .ready, .failed: return false
        }
    }

    /// 文件列表到了还没开播：接着上次看的那一集，否则挑最大的视频
    private func autoPlayIfReady() {
        guard !autoPlayed, controller.phase == .ready, let catalog = controller.catalog,
              !controller.playerVisible, controller.cloudQueue == nil else { return }
        let candidates = (catalog.main.isEmpty ? catalog.allVideos : catalog.main).filter(\.isPlayable)
        guard let pick = controller.lastPlayed ?? candidates.max(by: { $0.size < $1.size }) else { return }
        autoPlayed = true
        controller.play(pick)
    }

    private func park() {
        parked = true
        MagnetRelayCenter.shared.park(controller, title: displayTitle)
        close()
    }

    private func close() {
        dismissWindow?()
    }
}

/// 边下边播的播放器（和磁力页里的同一套控件）
private struct MagnetLaunchWatch: View {
    @ObservedObject var controller: MagnetController

    var body: some View {
        PlaybackControlsView(
            playback: controller.playback,
            title: controller.playingFile?.title ?? controller.catalog?.name ?? "磁力在线播放",
            loading: controller.preparing,
            loadingText: controller.preparingText,
            error: controller.playError,
            items: controller.playlist.map { file in
                PlaybackListItem(id: String(file.index), title: file.title,
                                 subtitle: [file.episodeLabel ?? "", file.sizeText].filter { !$0.isEmpty }.joined(separator: " · "))
            },
            selectedID: controller.playingIndex.map { String($0) } ?? "",
            networkStatus: controller.networkStatus,
            onSelect: { id in
                guard let index = UInt32(id), let file = controller.playlist.first(where: { $0.index == index }) else { return }
                controller.play(file)
            },
            onRetry: { controller.retryPlayback() },
            onClose: { controller.closePlayer() }
        )
    }
}

// MARK: - 等待画面

/// 播放窗口里开播前的一屏：封面模糊做底，中间是片名和几步进度，下面是「后台继续」和「取消」。
private struct MagnetLaunchStage: View {
    @ObservedObject var controller: MagnetController
    let title: String
    let coverURL: URL?
    let canPark: Bool
    let onCancel: () -> Void
    let onPark: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Step: Identifiable {
        let id: Int
        let title: String
    }

    private var steps: [Step] {
        controller.usesCloud
            ? [Step(id: 0, title: "提交到 115"), Step(id: 1, title: "115 下载中"), Step(id: 2, title: "准备播放")]
            : [Step(id: 0, title: "连接节点"), Step(id: 1, title: "读取文件列表"), Step(id: 2, title: "缓冲开头")]
    }

    /// 当前进行到第几步
    private var current: Int {
        if controller.usesCloud {
            switch controller.cloud {
            case .off, .submitting: return 0
            case .downloading(let percent): return percent >= 100 ? 2 : 1
            case .ready, .failed: return 2
            }
        }
        if controller.phase == .ready { return 2 }
        return controller.step >= .metadata ? 1 : 0
    }

    private var cloudPercent: Double? {
        if case .downloading(let percent) = controller.cloud, percent > 0, percent < 100 { return percent }
        return nil
    }

    private var failed: Bool { controller.phase == .failed }

    private var frame: UIImage? {
        guard let hash = controller.link?.infoHash else { return nil }
        return PlaybackFrameStore.shared.image(for: PlaybackFrameStore.key(forMagnet: hash))
    }

    private var detail: String {
        if failed { return controller.error }
        if controller.usesCloud {
            let text = controller.cloudStatusText
            return text.isEmpty ? "正在提交到 115…" : text
        }
        if controller.phase == .ready { return "马上开始播放" }
        let swarm = controller.swarm
        var parts: [String] = []
        if swarm.connected > 0 { parts.append("已连接 \(swarm.connected) 个节点") } else { parts.append("正在寻找节点") }
        if controller.elapsed > 0 { parts.append("\(controller.elapsed) 秒") }
        return parts.joined(separator: " · ")
    }

    /// 文件列表到了，却没有能播的视频
    private var nothingToPlay: Bool {
        guard controller.phase == .ready, let catalog = controller.catalog else { return false }
        return !catalog.allVideos.contains(where: \.isPlayable)
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: Theme.Space.xl) {
                Spacer(minLength: Theme.Space.lg)
                VStack(spacing: Theme.Space.sm) {
                    Text(controller.usesCloud ? "115 云下载播放" : "磁力边下边播")
                        .font(Theme.Typo.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(title)
                        .font(.display(20))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if failed || nothingToPlay {
                    failure
                } else {
                    progress
                }
                Spacer(minLength: Theme.Space.lg)
                actions
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, Theme.Space.lg)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("magnet.launch")
    }

    private var backdrop: some View {
        ZStack {
            Color.black
            // 有封面用封面，没有（比如从播放记录进来）就用上次停下时的画面
            Color.clear
                .overlay {
                    if let coverURL {
                        MagnetArtwork(url: MagnetCover.highResURL(for: coverURL) ?? coverURL, maxPixel: 480, placeholder: AppIcon.magnet.name)
                    } else if let frame {
                        Image(uiImage: frame).resizable().scaledToFill()
                    }
                }
                .blur(radius: 36)
                .opacity(0.55)
                .clipped()
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var progress: some View {
        VStack(spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(steps) { step in
                    stepView(step)
                    if step.id < steps.count - 1 {
                        Rectangle()
                            .fill(step.id < current ? Theme.accent : Color.white.opacity(0.18))
                            .frame(height: 1)
                            .frame(maxWidth: 28)
                    }
                }
            }
            if let percent = cloudPercent {
                VStack(spacing: Theme.Space.xs) {
                    ProgressView(value: percent, total: 100)
                        .tint(Theme.accent)
                        .frame(maxWidth: 260)
                }
            }
            Text(detail)
                .font(Theme.Typo.meta.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .animation(nil, value: detail)
        }
    }

    private func stepView(_ step: Step) -> some View {
        let done = step.id < current
        let active = step.id == current
        return HStack(spacing: 6) {
            ZStack {
                if done {
                    Image(systemName: AppIcon.check.name)
                        .font(.scaled(10, weight: .bold))
                        .foregroundStyle(Theme.onAccentFill)
                        .frame(width: 18, height: 18)
                        .background(Theme.accent, in: Circle())
                } else if active {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                        .frame(width: 18, height: 18)
                }
            }
            Text(step.title)
                .font(Theme.Typo.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : Color.white.opacity(done ? 0.7 : 0.4))
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "已完成" : active ? "进行中" : "等待")
    }

    private var failure: some View {
        VStack(spacing: Theme.Space.md) {
            Text(nothingToPlay ? "这个资源里没有找到能播放的视频。" : detail)
                .font(Theme.Typo.meta)
                .foregroundStyle(Color.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if failed {
                Button("重试") { controller.retry() }
                    .buttonStyle(PrimaryActionStyle(light: true))
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("magnet.launch.retry")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.md) {
            if canPark {
                Button(action: onPark) {
                    Label("后台继续", systemImage: AppIcon.cloudDownload.name)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionStyle(light: true))
                .accessibilityIdentifier("magnet.launch.background")
            }
            Button(action: onCancel) {
                Text(failed || nothingToPlay ? "关闭" : "取消")
                    .frame(maxWidth: canPark ? .infinity : 160)
            }
            .buttonStyle(ActionButtonStyle(kind: .secondary))
            .accessibilityIdentifier("magnet.launch.cancel")
        }
        .frame(maxWidth: 420)
    }
}
