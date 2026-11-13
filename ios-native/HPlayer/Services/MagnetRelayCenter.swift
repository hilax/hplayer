import Combine
import Foundation

/// 磁力播放窗口里点了「后台继续」：115 离线还在云端下载，窗口先关掉，
/// 这里接着持有那份 MagnetController，等 115 准备好时弹一句提示，资源卡片上的按钮也变成「播放」。
/// 再次点播放时窗口直接接手这份控制器，不会重新提交离线任务。
/// 只负责「持有和提示」，115 离线和 BT 解析的流程仍然全部在 MagnetController 里。
@MainActor
final class MagnetRelayCenter: ObservableObject {
    static let shared = MagnetRelayCenter()

    struct Job {
        let controller: MagnetController
        let title: String
        var watcher: AnyCancellable?
    }

    /// 全局轻提示（首页根视图上显示）
    @Published var message: String?
    /// 已经在 115 准备好、可以直接播放的资源（信息哈希，小写）
    @Published private(set) var ready: Set<String> = []
    /// 正在后台等 115 的资源
    @Published private(set) var working: Set<String> = []

    private var jobs: [String: Job] = [:]

    /// 把正在等 115 的控制器放到后台
    func park(_ controller: MagnetController, title: String) {
        guard let hash = controller.link?.infoHash.lowercased() else { return }
        jobs[hash]?.watcher?.cancel()
        var job = Job(controller: controller, title: title)
        job.watcher = controller.$cloud
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                Task { @MainActor in self?.cloudChanged(state, hash: hash) }
            }
        jobs[hash] = job
        working.insert(hash)
        ready.remove(hash)
        message = "已转到后台，115 准备好后会提醒你"
    }

    /// 播放窗口打开时取回后台的控制器（没有就返回 nil）
    func take(infoHash: String?) -> MagnetController? {
        guard let hash = infoHash?.lowercased(), let job = jobs.removeValue(forKey: hash) else { return nil }
        job.watcher?.cancel()
        working.remove(hash)
        ready.remove(hash)
        return job.controller
    }

    func isReady(_ infoHash: String?) -> Bool {
        guard let hash = infoHash?.lowercased() else { return false }
        return ready.contains(hash)
    }

    func isWorking(_ infoHash: String?) -> Bool {
        guard let hash = infoHash?.lowercased() else { return false }
        return working.contains(hash)
    }

    private func cloudChanged(_ state: MagnetController.CloudState, hash: String) {
        guard let job = jobs[hash] else { return }
        switch state {
        case .ready:
            guard !ready.contains(hash) else { return }
            working.remove(hash)
            ready.insert(hash)
            // 结果（文件列表、115 播放地址）留在控制器里；BT 引擎这时用不上，先放掉
            job.controller.deactivate()
            message = "「\(job.title)」已在 115 准备好，点「播放」就能看"
        case .failed(let reason):
            job.watcher?.cancel()
            jobs.removeValue(forKey: hash)
            working.remove(hash)
            job.controller.deactivate()
            message = "「\(job.title)」没有准备好：\(reason)"
        case .off, .submitting, .downloading:
            break
        }
    }
}
