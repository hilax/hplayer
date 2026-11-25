import AVFoundation
import Foundation
import MediaPlayer
import Metal
import UIKit

/// 点封面到播放页出现这段时间里，主线程上每多做一件事，用户就多等一会儿。
/// 这里放的是可以提前做好、或者根本不需要主线程的准备工作。
enum PlayerWarmup {
    private static let queue = DispatchQueue(label: "app.hplayer.player.warmup", qos: .utility)
    private static let lock = NSLock()
    private static var started = false

    /// 首页出来之后调用一次。第一次用音频会话、Metal 图层、系统音量控件，都要和系统服务建立连接，
    /// 每样几十毫秒；放到点开播放页时才做，这些时间就全算进了「点了没反应」里，所以提前做掉。
    static func prepare() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        PlayerDiskCache.prepare()
        // 提前把本机回环中转监听拉起来，并备好内置字幕字体目录，避免首次点开 115 视频时冷启动中转监听。
        LocalStreamProxy.shared.warmUp()
        PlayerDiskCache.queue.async {
            _ = SubtitleFontManager.prepareSubtitleFontDirectory()
        }
        queue.async {
            let session = AVAudioSession.sharedInstance()
            _ = session.category
            _ = session.outputVolume
            _ = MTLCreateSystemDefaultDevice()
        }
        // 系统音量控件只能在主线程创建；晚一点、等首页稳定下来再做，并静默预热 1 个空闲 mpv 内核实例
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            MPVEnginePool.shared.prewarmIfNeeded()
        }
    }
}

/// 空闲 `MPVEngine` 预热池（单实例）：
/// 在后台预先完成 `mpv_create` + `mpv_initialize` + 字体配置 + `hplayer115://` 协议注册（未绑定渲染交换链），
/// 用户点击播放时 0ms 取出并绑定目标 `CAMetalLayer` 后再 `loadfile`，彻底消除内核冷启动耗时且避免 MoltenVK 复用脏交换链黑屏。
final class MPVEnginePool: @unchecked Sendable {
    static let shared = MPVEnginePool()

    private let lock = NSLock()
    private var idleEngine: MPVEngine?
    private var warming = false

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.drain()
        }
    }

    /// 若当前池为空且未在预热，则在后台内核串行队列上异步准备 1 个干净的空闲 `MPVEngine`。
    @MainActor
    func prewarmIfNeeded() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return
        }
        #endif
        let options = PlaybackController.defaultEngineOptions()
        prewarm(with: options)
    }

    func prewarm(with baseOptions: [(String, String)]) {
        lock.lock()
        guard idleEngine == nil, !warming else {
            lock.unlock()
            return
        }
        warming = true
        lock.unlock()

        PlayerDiskCache.queue.async { [weak self] in
            guard let self else { return }
            var options = baseOptions
            if let fontDir = SubtitleFontManager.prepareSubtitleFontDirectory() {
                options.append(("sub-fonts-dir", fontDir.path))
                options.append(("sub-font", SubtitleFontManager.defaultFontName))
                options.append(("osd-fonts-dir", fontDir.path))
                options.append(("osd-font", SubtitleFontManager.defaultFontName))
            }
            let created = MPVEngine(options: options, layer: nil)
            self.lock.lock()
            self.warming = false
            if self.idleEngine == nil {
                self.idleEngine = created
                self.lock.unlock()
            } else {
                self.lock.unlock()
                created?.destroy()
            }
        }
    }

    /// 同步取出已预热好的空闲 `MPVEngine`；池为空时返回 nil（调用方回退到后台现建）。
    func take() -> MPVEngine? {
        lock.lock()
        let taken = idleEngine
        idleEngine = nil
        lock.unlock()
        return taken
    }

    var hasIdleEngine: Bool {
        lock.lock()
        defer { lock.unlock() }
        return idleEngine != nil
    }

    func drain() {
        lock.lock()
        let old = idleEngine
        idleEngine = nil
        lock.unlock()
        if let old {
            PlayerDiskCache.queue.async { old.destroy() }
        }
    }
}

/// 播放缓存目录：清掉上次没清掉的缓存文件，并量好这次最多能用多少空间。
/// 这两件事都要访问磁盘，放在后台串行队列里做；播放内核也在同一个队列里创建，所以一定排在清理之后。
enum PlayerDiskCache {
    static let queue = DispatchQueue(label: "app.hplayer.player.engine", qos: .userInitiated)

    private static let lock = NSLock()
    private static var measuredLimit: Int?
    private static var cleanedOnce = false
    private static var lastMeasuredAt = Date.distantPast

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent("PlayerCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 首次启动时清理上次没清掉的缓存文件（例如 App 被系统结束），再按需重算可用空间；
    /// 避免每次打开播放页都在串行队列上阻塞 MPVEngine 初始化。
    static func prepare() {
        queue.async {
            lock.lock()
            let shouldClean = !cleanedOnce
            cleanedOnce = true
            let shouldMeasure = measuredLimit == nil || Date().timeIntervalSince(lastMeasuredAt) >= 60
            lock.unlock()

            if shouldClean {
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                files.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            if shouldMeasure {
                let value = measure()
                lock.lock()
                measuredLimit = value
                lastMeasuredAt = Date()
                lock.unlock()
            }
        }
    }

    /// 缓存最多用多少 MiB：用最近一次量到的结果；后台还没量完就现量一次
    static func limitMiB() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let measuredLimit { return measuredLimit }
        let value = measure()
        measuredLimit = value
        return value
    }

    /// 最多 2GB；手机剩余空间不多时只用剩余空间的一半
    private static func measure() -> Int {
        let limit = 2048
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free > 0 else { return limit }
        let half = Int(free / 2 / 1_048_576)
        return max(64, min(limit, half))
    }
}

/// 播放用的音频会话。setActive 要和系统音频服务通信，可能阻塞几十到几百毫秒（连着蓝牙耳机、
/// 别的 App 正在放声音时更久），放在后台串行队列里做，不占着主线程。
enum PlayerAudioSession {
    private static let queue = DispatchQueue(label: "app.hplayer.player.audio-session", qos: .userInitiated)

    /// 切到播放类别并激活。传了 activated 的话，激活完成后在主线程回调，带着当前的系统音量。
    static func activate(then activated: (@Sendable (Double) -> Void)? = nil) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
            guard let activated else { return }
            let volume = Double(session.outputVolume)
            DispatchQueue.main.async { activated(volume) }
        }
    }
}
