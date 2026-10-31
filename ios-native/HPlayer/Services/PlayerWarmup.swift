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
        queue.async {
            let session = AVAudioSession.sharedInstance()
            _ = session.category
            _ = session.outputVolume
            _ = MTLCreateSystemDefaultDevice()
        }
        // 系统音量控件只能在主线程创建；晚一点、等首页稳定下来再做
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        }
    }
}

/// 播放缓存目录：清掉上次没清掉的缓存文件，并量好这次最多能用多少空间。
/// 这两件事都要访问磁盘，放在后台串行队列里做；播放内核也在同一个队列里创建，所以一定排在清理之后。
enum PlayerDiskCache {
    static let queue = DispatchQueue(label: "app.hplayer.player.engine", qos: .userInitiated)

    private static let lock = NSLock()
    private static var measuredLimit: Int?

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent("PlayerCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 清理上次没清掉的缓存文件（例如 App 被系统结束），再重新量一下手机的剩余空间
    static func prepare() {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            let value = measure()
            lock.lock()
            measuredLimit = value
            lock.unlock()
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
