import Combine
import Foundation

/// 磁力播放的进度中心：开播前的等待都画在资源卡片上，不遮住播放器。
/// - 资源卡片上点「115 播放」：在这里起一份 MagnetController（只走 115 离线），卡片显示 提交 → 下载中 xx% → 准备播放
/// - 点「磁力播放」：同样起一份（只走软件自带的 BT 解析），卡片显示 连接节点 → 读取文件列表
/// - 115 准备好时：卡片所在页面还开着就直接打开播放器；页面已经关了就弹一句全局提示
/// - 已经在 115 下载好的资源记在本机，下次卡片按钮直接是「播放」
/// - 播放窗口里点了「后台继续」的控制器也放在这里（park）
/// 播放窗口打开时用 take 接手同一份控制器，不会重复提交离线任务。
/// 只负责「持有、汇总状态和提示」，115 离线和 BT 解析的流程仍然全部在 MagnetController 里。
@MainActor
final class MagnetRelayCenter: ObservableObject {
    static let shared = MagnetRelayCenter()

    /// 卡片上显示的 115 进度
    enum Status: Equatable {
        /// BT：正在找节点（已连上几个）
        case connecting(Int)
        /// BT：连上了，正在读取文件列表
        case reading
        case submitting
        case downloading(Double)
        /// 115 下载完了，正在找视频
        case preparing
        case ready
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .connecting, .reading, .submitting, .downloading, .preparing: return true
            case .ready, .failed: return false
            }
        }
    }

    private struct Job {
        let controller: MagnetController
        let title: String
        let mode: MagnetPlaybackRequest.Mode
        var watcher: AnyCancellable?
    }

    /// 准备好、该打开播放器的资源
    struct ReadyItem: Equatable {
        let hash: String
        let mode: MagnetPlaybackRequest.Mode
        let token = UUID()
    }

    /// 全局轻提示（首页根视图上显示）
    @Published var message: String?
    /// 每个资源（信息哈希，小写）这次的 115 进度
    @Published private(set) var statuses: [String: Status] = [:]
    /// 已经在 115 下载好过的资源（保存在本机）
    @Published private(set) var downloaded: Set<String> = []
    /// 刚准备好、而且它所在的页面还开着的资源：页面看到后打开播放器，再调用 consumeReady
    @Published private(set) var readyToOpen: ReadyItem?

    private var jobs: [String: Job] = [:]
    /// 正开着的页面关心的资源（计数，同一资源可能出现在多个页面）
    private var watching: [String: Int] = [:]
    private let defaults: UserDefaults
    private let storageKey = "hplayer.magnet.cloudDownloaded"
    private let limit = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        downloaded = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    // MARK: 状态

    func status(_ infoHash: String?) -> Status? {
        guard let hash = Self.normalize(infoHash) else { return nil }
        return statuses[hash]
    }

    /// 115 里已经有了（这次刚准备好，或者以前下载过）
    func isDownloaded(_ infoHash: String?) -> Bool {
        guard let hash = Self.normalize(infoHash) else { return false }
        return statuses[hash] == .ready || downloaded.contains(hash)
    }

    func isWorking(_ infoHash: String?) -> Bool { status(infoHash)?.isWorking ?? false }

    /// 失败的那份是哪种方式（卡片上「重试」用）
    func failedMode(_ infoHash: String?) -> MagnetPlaybackRequest.Mode? {
        guard let hash = Self.normalize(infoHash), case .failed = statuses[hash] else { return nil }
        return jobs[hash]?.mode
    }

    /// 已经准备好、等着打开的那份是哪种方式
    func readyMode(_ infoHash: String?) -> MagnetPlaybackRequest.Mode? {
        guard let hash = Self.normalize(infoHash), statuses[hash] == .ready else { return nil }
        return jobs[hash]?.mode
    }

    /// 别处（播放窗口）用 115 播放成功时也记一笔
    func markDownloaded(_ infoHash: String?) {
        guard let hash = Self.normalize(infoHash), !downloaded.contains(hash) else { return }
        downloaded.insert(hash)
        save()
    }

    // MARK: 页面

    func watch(_ hashes: [String]) {
        for hash in hashes.compactMap(Self.normalize) { watching[hash, default: 0] += 1 }
    }

    func unwatch(_ hashes: [String]) {
        for hash in hashes.compactMap(Self.normalize) {
            let count = (watching[hash] ?? 0) - 1
            watching[hash] = count > 0 ? count : nil
        }
    }

    func consumeReady() { readyToOpen = nil }

    // MARK: 115 播放

    /// 资源卡片上点了「115 播放」：交给 115 离线，进度在卡片上显示。
    /// 115 里已经有的资源再提交一次也只是找回原来的任务，很快就会准备好。
    func startCloud(magnet: String, title: String, client: Direct115Client?) {
        guard let link = MagnetLink.parse(magnet), let client else { return }
        let hash = link.infoHash.lowercased()
        if let status = statuses[hash], status.isWorking { return }
        removeJob(hash)
        let controller = MagnetController()
        controller.activate()
        controller.configureCloud(client: client, enabled: true)
        statuses[hash] = downloaded.contains(hash) ? .preparing : .submitting
        adopt(controller, hash: hash, title: title, mode: .cloud)
        controller.open(link)
    }

    /// 资源卡片上点了「磁力播放」：软件自带的 BT 解析，连节点、读文件列表的进度在卡片上显示
    func startBT(magnet: String, title: String) {
        guard let link = MagnetLink.parse(magnet) else { return }
        let hash = link.infoHash.lowercased()
        if let status = statuses[hash], status.isWorking { return }
        removeJob(hash)
        let controller = MagnetController()
        controller.activate()
        controller.configureCloud(client: nil, enabled: false)
        statuses[hash] = .connecting(0)
        adopt(controller, hash: hash, title: title, mode: .bt)
        controller.open(link)
    }

    /// 卡片上点了「取消」，或失败后关掉提示
    func cancel(_ infoHash: String?) {
        guard let hash = Self.normalize(infoHash) else { return }
        removeJob(hash)
        statuses[hash] = nil
        if readyToOpen?.hash == hash { readyToOpen = nil }
    }

    /// 播放窗口里点了「后台继续」
    func park(_ controller: MagnetController, title: String) {
        guard let hash = Self.normalize(controller.link?.infoHash) else { return }
        removeJob(hash)
        statuses[hash] = .submitting
        adopt(controller, hash: hash, title: title, mode: .cloud)
        message = "已转到后台，115 准备好后会提醒你"
    }

    /// 播放窗口打开时取回这份控制器；指定了方式时只取同一种方式的（没有就返回 nil）
    func take(infoHash: String?, mode: MagnetPlaybackRequest.Mode?) -> MagnetController? {
        guard let hash = Self.normalize(infoHash), let job = jobs[hash] else { return nil }
        if let mode, job.mode != mode { return nil }
        jobs[hash] = nil
        job.watcher?.cancel()
        statuses[hash] = nil
        if readyToOpen?.hash == hash { readyToOpen = nil }
        return job.controller
    }

    // MARK: 内部

    private func adopt(_ controller: MagnetController, hash: String, title: String, mode: MagnetPlaybackRequest.Mode) {
        var job = Job(controller: controller, title: title, mode: mode)
        // objectWillChange 在改动之前发出；放到下一轮再读，拿到的是改动后的值
        job.watcher = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(hash) }
            }
        jobs[hash] = job
        refresh(hash)
    }

    private func removeJob(_ hash: String) {
        guard let job = jobs.removeValue(forKey: hash) else { return }
        job.watcher?.cancel()
        job.controller.deactivate()
    }

    private func refresh(_ hash: String) {
        guard let job = jobs[hash] else { return }
        let controller = job.controller
        let previous = statuses[hash]
        let next = job.mode == .cloud ? cloudStatus(controller, previous: previous) : btStatus(controller)
        guard next != previous else { return }
        statuses[hash] = next
        switch next {
        case .ready:
            if job.mode == .cloud {
                markDownloaded(hash)
                // 结果（文件列表、115 播放地址）留在控制器里；BT 引擎这时用不上，先放掉
                controller.deactivate()
            } else if controller.playerVisible {
                // 只有一个正片时控制器会自己开播；这时还没有播放窗口，先停下，等播放窗口接手再播
                controller.closePlayer()
            }
            if watching[hash] != nil {
                readyToOpen = ReadyItem(hash: hash, mode: job.mode)
            } else {
                message = job.mode == .cloud ? "「\(job.title)」已在 115 准备好，点「播放」就能看"
                    : "「\(job.title)」可以播放了，点「播放」开始"
            }
        case .failed(let reason):
            // 以前下载过、这次却找不到了（比如网盘里删掉了）：按钮回到「115 播放」
            if job.mode == .cloud, downloaded.remove(hash) != nil { save() }
            job.watcher?.cancel()
            controller.deactivate()
            jobs[hash] = Job(controller: controller, title: job.title, mode: job.mode, watcher: nil)
            if watching[hash] == nil { message = "「\(job.title)」没有准备好：\(reason)" }
        case .connecting, .reading, .submitting, .downloading, .preparing:
            break
        }
    }

    private func cloudStatus(_ controller: MagnetController, previous: Status?) -> Status {
        switch controller.cloud {
        case .off:
            if controller.phase == .failed {
                return .failed(controller.error.isEmpty ? "115 离线没有完成" : controller.error)
            }
            return previous ?? .submitting
        case .submitting:
            return previous == .preparing ? .preparing : .submitting
        case .downloading(let percent):
            return percent >= 100 || (previous == .preparing && percent <= 0) ? .preparing : .downloading(percent)
        case .ready:
            return .ready
        case .failed(let reason):
            return .failed(reason)
        }
    }

    private func btStatus(_ controller: MagnetController) -> Status {
        switch controller.phase {
        case .failed:
            return .failed(controller.error.isEmpty ? "没能解析这个磁力链接" : controller.error)
        case .ready:
            return controller.catalog == nil ? .reading : .ready
        case .idle, .resolving:
            return controller.step >= .metadata ? .reading : .connecting(controller.swarm.connected)
        }
    }

    private func save() {
        var list = Array(downloaded)
        if list.count > limit { list = Array(list.suffix(limit)); downloaded = Set(list) }
        defaults.set(list, forKey: storageKey)
    }

    private static func normalize(_ infoHash: String?) -> String? {
        guard let hash = infoHash?.lowercased(), !hash.isEmpty else { return nil }
        return hash
    }
}
