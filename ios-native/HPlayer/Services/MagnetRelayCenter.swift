import Combine
import Foundation

/// 磁力「115 播放」的进度中心。
/// - 资源卡片上点「115 播放」：在这里起一份 MagnetController（只走 115 离线），进度直接画在卡片上，不遮住播放器
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
        case submitting
        case downloading(Double)
        /// 115 下载完了，正在找视频
        case preparing
        case ready
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .submitting, .downloading, .preparing: return true
            case .ready, .failed: return false
            }
        }
    }

    private struct Job {
        let controller: MagnetController
        let title: String
        var watcher: AnyCancellable?
    }

    /// 全局轻提示（首页根视图上显示）
    @Published var message: String?
    /// 每个资源（信息哈希，小写）这次的 115 进度
    @Published private(set) var statuses: [String: Status] = [:]
    /// 已经在 115 下载好过的资源（保存在本机）
    @Published private(set) var downloaded: Set<String> = []
    /// 刚准备好、而且它所在的页面还开着的资源：页面看到后打开播放器，再调用 consumeReady
    @Published private(set) var readyToOpen: String?

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
        if statuses[hash] == .ready, jobs[hash] != nil {
            readyToOpen = hash
            return
        }
        removeJob(hash)
        let controller = MagnetController()
        controller.activate()
        controller.configureCloud(client: client, enabled: true)
        statuses[hash] = downloaded.contains(hash) ? .preparing : .submitting
        adopt(controller, hash: hash, title: title)
        controller.open(link)
    }

    /// 卡片上点了「取消」，或失败后关掉提示
    func cancel(_ infoHash: String?) {
        guard let hash = Self.normalize(infoHash) else { return }
        removeJob(hash)
        statuses[hash] = nil
        if readyToOpen == hash { readyToOpen = nil }
    }

    /// 播放窗口里点了「后台继续」
    func park(_ controller: MagnetController, title: String) {
        guard let hash = Self.normalize(controller.link?.infoHash) else { return }
        removeJob(hash)
        statuses[hash] = .submitting
        adopt(controller, hash: hash, title: title)
        message = "已转到后台，115 准备好后会提醒你"
    }

    /// 播放窗口打开时取回这份控制器（没有就返回 nil）
    func take(infoHash: String?) -> MagnetController? {
        guard let hash = Self.normalize(infoHash), let job = jobs.removeValue(forKey: hash) else { return nil }
        job.watcher?.cancel()
        statuses[hash] = nil
        if readyToOpen == hash { readyToOpen = nil }
        return job.controller
    }

    // MARK: 内部

    private func adopt(_ controller: MagnetController, hash: String, title: String) {
        var job = Job(controller: controller, title: title)
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
        let next: Status
        switch controller.cloud {
        case .off:
            if controller.phase == .failed {
                next = .failed(controller.error.isEmpty ? "115 离线没有完成" : controller.error)
            } else {
                next = previous ?? .submitting
            }
        case .submitting:
            next = previous == .preparing ? .preparing : .submitting
        case .downloading(let percent):
            next = percent >= 100 || (previous == .preparing && percent <= 0) ? .preparing : .downloading(percent)
        case .ready:
            next = .ready
        case .failed(let reason):
            next = .failed(reason)
        }
        guard next != previous else { return }
        statuses[hash] = next
        switch next {
        case .ready:
            markDownloaded(hash)
            // 结果（文件列表、115 播放地址）留在控制器里；BT 引擎这时用不上，先放掉
            controller.deactivate()
            if watching[hash] != nil {
                readyToOpen = hash
            } else {
                message = "「\(job.title)」已在 115 准备好，点「播放」就能看"
            }
        case .failed(let reason):
            // 以前下载过、这次却找不到了（比如网盘里删掉了）：按钮回到「115 播放」
            if downloaded.remove(hash) != nil { save() }
            job.watcher?.cancel()
            controller.deactivate()
            jobs[hash] = Job(controller: controller, title: job.title, watcher: nil)
            if watching[hash] == nil { message = "「\(job.title)」没有准备好：\(reason)" }
        case .submitting, .downloading, .preparing:
            break
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
