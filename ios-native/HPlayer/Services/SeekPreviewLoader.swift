import Foundation
import MobileVLCKit
import UIKit

/// 拖动进度时取目标位置的画面，显示在拖动提示里。
/// 另开一个 VLC 缩略图任务，同一时间只跑一个；手指还在动时只记下最新的位置，
/// 上一张取完再取最新这张，所以停下来的那个位置总会有画面。
@MainActor
final class SeekPreviewLoader: NSObject, ObservableObject, VLCMediaThumbnailerDelegate {
    @Published private(set) var image: UIImage?
    @Published private(set) var loading = false

    private weak var playback: VLCPlaybackController?
    private var thumbnailer: VLCMediaThumbnailer?
    private var pendingFraction: Float?
    private var shownFraction: Float?
    private var runningFraction: Float = 0
    /// 每次重置加一，旧任务回来的画面就不要了
    private var generation = 0
    private var runningGeneration = 0

    /// fraction：目标时间占总时长的比例
    func request(fraction: Double, from playback: VLCPlaybackController) {
        self.playback = playback
        let value = Float(min(max(fraction, 0), 0.995))
        if let shownFraction, abs(shownFraction - value) < 0.003, pendingFraction == nil { return }
        pendingFraction = value
        if thumbnailer == nil { startNext() }
    }

    func reset() {
        generation += 1
        pendingFraction = nil
        shownFraction = nil
        image = nil
        loading = false
    }

    private func startNext() {
        guard let fraction = pendingFraction, let media = playback?.makePreviewMedia() else {
            pendingFraction = nil
            loading = false
            return
        }
        pendingFraction = nil
        let next = VLCMediaThumbnailer(media: media, andDelegate: self)
        next.snapshotPosition = fraction
        next.thumbnailWidth = 320
        next.thumbnailHeight = 180
        runningFraction = fraction
        runningGeneration = generation
        thumbnailer = next
        loading = true
        next.fetchThumbnail()
    }

    private func finish(_ result: UIImage?) {
        thumbnailer = nil
        if runningGeneration == generation, let result {
            image = result
            shownFraction = runningFraction
        }
        if pendingFraction != nil, runningGeneration == generation {
            startNext()
        } else {
            loading = false
        }
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        let result = UIImage(cgImage: thumbnail)
        Task { @MainActor [weak self] in self?.finish(result) }
    }
}
