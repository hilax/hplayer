import SwiftUI
import UIKit

/// 点「播放」时要打开的磁力资源。封面用来做播放窗口里等待时的模糊背景。
struct MagnetPlaybackRequest: Identifiable {
    /// 播放方式：115（离线后用 115 播放）还是 BT 边下边播；nil 表示按「使用 115 解析」开关
    enum Mode { case cloud, bt }

    let id = UUID()
    let magnet: String
    var title: String = ""
    var coverURL: URL? = nil
    var mode: Mode? = nil

    var infoHash: String? { MagnetLink.parse(magnet)?.infoHash }
}

extension View {
    /// 打开磁力播放窗口。资源卡片上会先把解析 / 115 离线做完再调用；其他入口在播放器里等。
    func magnetPlayer(item: Binding<MagnetPlaybackRequest?>) -> some View {
        playerWindow(item: item) { request in
            MagnetLaunchPlayer(request: request)
        }
    }
}

/// 播放窗口里的磁力播放：
/// - 从资源卡片进来时，115 / 磁力解析已经在卡片上做完了，这里直接开播
/// - 从播放记录、继续观看、外部链接进来时，等待只用播放器自己的加载提示（没有单独盖在上面的进度页）
/// - 115 好了：就是一个普通的 115 文件，用片库同一个播放器（画质、进度、继续观看截图）
/// - 多个视频时先播最大的那个（看过的话接着上次那一集），其余的在「选集」里
/// 解析和离线的流程都在 MagnetController 里，这里只决定显示什么、什么时候开播。
struct MagnetLaunchPlayer: View {
    let request: MagnetPlaybackRequest

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissPlayerWindow) private var dismissWindow
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true
    @StateObject private var controller: MagnetController
    @State private var autoPlayed = false
    @State private var watchedBT = false

    init(request: MagnetPlaybackRequest) {
        self.request = request
        // 卡片上已经在跑（或者已经准备好）的同一种方式：直接接手，不重新解析 / 提交
        let hash = request.infoHash
        let mode = request.mode
        _controller = StateObject(wrappedValue: MagnetRelayCenter.shared.take(infoHash: hash, mode: mode) ?? MagnetController())
    }

    var body: some View {
        Group {
            if let queue = controller.cloudQueue {
                // 115 离线好了：就是一个普通的 115 文件，用片库同一个播放器
                PlayerView(source: queue.source, playlist: queue.items)
            } else {
                MagnetLaunchWatch(
                    controller: controller,
                    title: displayTitle,
                    waiting: !controller.playerVisible,
                    waitingText: waitingText,
                    waitingError: waitingError,
                    onClose: close
                )
            }
        }
        .task {
            guard !InterfacePreview.active else { return }
            controller.activate()
            let useCloud: Bool
            switch request.mode {
            case .cloud: useCloud = true
            case .bt: useCloud = false
            case nil: useCloud = cloudRelay
            }
            controller.configureCloud(client: appState.directClient(), enabled: useCloud)
            if let link = MagnetLink.parse(request.magnet) {
                controller.open(link)
            }
            autoPlayIfReady()
        }
        .onChange(of: controller.phase) { _ in autoPlayIfReady() }
        // 115 离线成功：记下来，资源卡片下次直接显示「播放」
        .onChange(of: controller.cloud == .ready) { ready in
            if ready { MagnetRelayCenter.shared.markDownloaded(controller.link?.infoHash) }
        }
        .onChange(of: controller.catalog != nil) { _ in autoPlayIfReady() }
        .onChange(of: controller.playerVisible) { visible in
            if visible { watchedBT = true; return }
            // 关掉了边下边播的播放器（换成 115 播放时 cloudQueue 会接上，不算关闭）
            if watchedBT, controller.cloudQueue == nil { close() }
        }
        .onDisappear { controller.deactivate() }
    }

    private var displayTitle: String {
        if !request.title.isEmpty { return request.title }
        return controller.catalog?.name ?? controller.link?.displayName ?? "磁力资源"
    }

    /// 还没开播时播放器中间那行加载文字
    private var waitingText: String {
        if controller.usesCloud {
            let text = controller.cloudStatusText
            return text.isEmpty ? "正在提交到 115…" : text
        }
        if controller.phase == .ready { return "马上开始播放…" }
        let peers = controller.swarm.connected
        if controller.step >= .metadata { return "正在读取文件列表 · \(peers) 个节点" }
        return peers > 0 ? "正在连接节点 · 已连上 \(peers) 个" : "正在连接节点…"
    }

    /// 还没开播就失败了：显示在播放器里，带「重试」
    private var waitingError: String {
        if controller.phase == .failed { return controller.error.isEmpty ? "没能解析这个磁力链接" : controller.error }
        if controller.phase == .ready, let catalog = controller.catalog, !catalog.allVideos.contains(where: \.isPlayable) {
            return "这个资源里没有找到能播放的视频。"
        }
        return ""
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

    private func close() {
        dismissWindow?()
    }
}

/// 边下边播的播放器（和磁力页里的同一套控件）。还没开播时也是它：只显示播放器自己的加载提示
private struct MagnetLaunchWatch: View {
    @ObservedObject var controller: MagnetController
    let title: String
    /// 还在等文件列表 / 115
    let waiting: Bool
    let waitingText: String
    let waitingError: String
    let onClose: () -> Void

    var body: some View {
        PlaybackControlsView(
            playback: controller.playback,
            title: waiting ? title : (controller.playingFile?.title ?? controller.catalog?.name ?? title),
            loading: waiting ? waitingError.isEmpty : controller.preparing,
            loadingText: waiting ? waitingText : controller.preparingText,
            error: waiting ? waitingError : controller.playError,
            items: waiting ? [] : controller.playlist.map { file in
                PlaybackListItem(id: String(file.index), title: file.title,
                                 subtitle: [file.episodeLabel ?? "", file.sizeText].filter { !$0.isEmpty }.joined(separator: " · "))
            },
            selectedID: controller.playingIndex.map { String($0) } ?? "",
            networkStatus: controller.usesCloud ? "" : controller.networkStatus,
            onSelect: { id in
                guard let index = UInt32(id), let file = controller.playlist.first(where: { $0.index == index }) else { return }
                controller.play(file)
            },
            onRetry: { waiting ? controller.retry() : controller.retryPlayback() },
            onClose: { waiting ? onClose() : controller.closePlayer() }
        )
    }
}
