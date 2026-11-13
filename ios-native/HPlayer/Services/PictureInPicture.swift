import Accelerate
import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
import Libmpv
import UIKit

// MARK: - 设置

/// 后台小窗播放的开关
enum PictureInPictureSettings {
    private static let autoKey = "player.autoPictureInPicture"

    /// 播放中回到桌面时自动变成小窗继续播（默认打开）
    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
}

// MARK: - CPU 出图

/// 小窗播放用的出图：mpv 用 libmpv 的软件渲染把每一帧画进 CVPixelBuffer，
/// 再交给系统小窗用的 AVSampleBufferDisplayLayer。
///
/// 平时画面由 gpu-next 用 GPU 画在 Metal 图层上，但 App 退到后台以后系统不允许再用 GPU，
/// 所以小窗播放期间换成 CPU 出图。小窗只有几百个点宽，按小窗大小出图，CPU 开销不大；
/// 解码仍然用硬件（videotoolbox-copy）。
final class MPVSoftwareOutput {
    private let queue = DispatchQueue(label: "app.hplayer.mpv.software-output", qos: .userInteractive)
    private var context: OpaquePointer?
    private let layer: AVSampleBufferDisplayLayer
    private let lock = NSLock()
    private var renderPending = false
    private var finished = false
    private var _videoSize = CGSize.zero
    private var _renderSize = CGSize.zero

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var formatDescription: CMVideoFormatDescription?
    /// 先请求带不透明 alpha 的 bgra；内核不支持的话退回 bgr0，自己把 alpha 补成不透明
    private var useBGRA = true
    private let bgraName = strdup("bgra")
    private let bgr0Name = strdup("bgr0")

    /// 视频本身的尺寸，用来定出图比例
    var videoSize: CGSize {
        get { lock.lock(); defer { lock.unlock() }; return _videoSize }
        set { lock.lock(); _videoSize = newValue; lock.unlock() }
    }

    /// 小窗当前的像素尺寸（系统告诉的），用来定出图大小
    var renderSize: CGSize {
        get { lock.lock(); defer { lock.unlock() }; return _renderSize }
        set { lock.lock(); _renderSize = newValue; lock.unlock() }
    }

    init?(mpv: OpaquePointer, layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        let apiType = strdup("sw")
        defer { free(apiType) }
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        var created: OpaquePointer?
        guard mpv_render_context_create(&created, mpv, &params) >= 0, let created else { return nil }
        context = created
        let me = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        mpv_render_context_set_update_callback(created, { raw in
            guard let raw else { return }
            Unmanaged<MPVSoftwareOutput>.fromOpaque(raw).takeUnretainedValue().scheduleRender()
        }, me)
    }

    deinit {
        shutdown()
        free(bgraName)
        free(bgr0Name)
    }

    /// 释放渲染上下文。之后内核不会再回调这里。必须在内核销毁之前调用。
    func shutdown() {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        queue.sync {
            guard let context else { return }
            self.context = nil
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
        }
    }

    /// 内核的回调可能来自任何线程，这里只排一次渲染，真正的渲染在自己的队列上做
    private func scheduleRender() {
        lock.lock()
        if renderPending || finished {
            lock.unlock()
            return
        }
        renderPending = true
        lock.unlock()
        queue.async { [weak self] in self?.renderIfNeeded() }
    }

    private func renderIfNeeded() {
        lock.lock()
        renderPending = false
        lock.unlock()
        guard let context else { return }
        let flags = mpv_render_context_update(context)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        let (width, height) = outputDimensions()
        guard let buffer = PiPFrames.makeBuffer(width: width, height: height, pool: &pool, poolWidth: &poolWidth, poolHeight: &poolHeight) else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        var size: [Int32] = [Int32(width), Int32(height)]
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)
        var result = render(context, size: &size, stride: &stride, base: base, format: useBGRA ? bgraName : bgr0Name)
        if result < 0, useBGRA {
            useBGRA = false
            result = render(context, size: &size, stride: &stride, base: base, format: bgr0Name)
        }
        if result >= 0, !useBGRA, let base {
            PiPFrames.makeOpaque(base: base, width: width, height: height, stride: stride)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard result >= 0 else { return }
        PiPFrames.enqueue(buffer, on: layer, format: &formatDescription)
    }

    private func render(_ context: OpaquePointer, size: inout [Int32], stride: inout Int,
                        base: UnsafeMutableRawPointer?, format: UnsafeMutablePointer<CChar>?) -> Int32 {
        size.withUnsafeMutableBufferPointer { sizePointer in
            withUnsafeMutablePointer(to: &stride) { stridePointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_render(context, &params)
            }
        }
    }

    /// 出图大小：按视频比例，宽度跟着小窗走，限制在 480～1280 像素之间（不超过视频本身）
    private func outputDimensions() -> (Int, Int) {
        let video = videoSize
        let window = renderSize
        let aspect = video.width > 0 && video.height > 0 ? video.width / video.height : 16.0 / 9.0
        var width = window.width > 0 ? window.width : 1024
        width = min(max(width, 480), 1280)
        if video.width > 0 { width = min(width, video.width) }
        let even = { (value: CGFloat) in max(2, Int(value.rounded()) & ~1) }
        return (even(width), even(width / aspect))
    }
}

// MARK: - 帧工具

enum PiPFrames {
    static func makeBuffer(width: Int, height: Int, pool: inout CVPixelBufferPool?,
                           poolWidth: inout Int, poolHeight: inout Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferBytesPerRowAlignmentKey: 64,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// BGR0 的第四个字节是 0：补成 255，免得被当成透明
    static func makeOpaque(base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) {
        var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
        var destination = source
        // 掩码 0x1 是每个像素的第 4 个字节（BGRA 里的 A）
        vImageOverwriteChannelsWithScalar_ARGB8888(255, &source, &destination, 0x1, vImage_Flags(kvImageNoFlags))
    }

    /// 交给小窗图层，马上显示（不按时间排队：节奏已经由内核按音频同步好了）
    static func enqueue(_ buffer: CVPixelBuffer, on layer: AVSampleBufferDisplayLayer, format: inout CMVideoFormatDescription?) {
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer) {
            var created: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &created)
            format = created
        }
        guard let format else { return }
        let now = layer.controlTimebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        layer.enqueue(sample)
    }

    /// 把内核截下的一帧（BGR0、原始分辨率）缩小后放进小窗图层。
    /// 小窗要从播放页的画面「飞」出去，图层里得先有一帧当前画面，系统才认为可以开小窗。
    static func still(from frame: MPVEngine.RawFrame, maxWidth: Int = 1280) -> CVPixelBuffer? {
        let scale = min(1, Double(maxWidth) / Double(frame.width))
        let width = max(2, Int(Double(frame.width) * scale) & ~1)
        let height = max(2, Int(Double(frame.height) * scale) & ~1)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let error = frame.pixels.withUnsafeBytes { raw -> vImage_Error in
            guard let source = raw.baseAddress else { return vImage_Error(kvImageNullPointerArgument) }
            var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(frame.height),
                                      width: vImagePixelCount(frame.width), rowBytes: frame.stride)
            var output = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: rowBytes)
            return vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { return nil }
        makeOpaque(base: base, width: width, height: height, stride: rowBytes)
        return buffer
    }
}

// MARK: - 系统小窗

/// 管理系统画中画（小窗）：
/// - 播放页里放一个看不见的 AVSampleBufferDisplayLayer（垫在画面下面），小窗就从它「飞」出去；
/// - 小窗开始前把内核换成 CPU 出图，画面送进这个图层；小窗结束（点回全屏或关掉）再换回 GPU。
/// - 小窗上的播放 / 暂停、快进快退、进度条都接到 PlaybackController。
@MainActor
final class PlayerPictureInPicture {
    let layer: AVSampleBufferDisplayLayer
    private let controller: AVPictureInPictureController
    private let bridge: PictureInPictureBridge
    private let timebase: CMTimebase?
    private weak var playback: PlaybackController?
    private var subscriptions: Set<AnyCancellable> = []
    private var stillFormat: CMVideoFormatDescription?
    /// 用户点了「回到播放页」：小窗结束后接着播
    private var restoring = false
    /// 正在截取引导帧（避免叠在一起截很多次）
    private var grabbingStill = false

    var isActive: Bool { controller.isPictureInPictureActive }
    var isPossible: Bool { controller.isPictureInPicturePossible }

    init(layer: AVSampleBufferDisplayLayer, playback: PlaybackController) {
        self.layer = layer
        self.playback = playback
        let bridge = PictureInPictureBridge()
        self.bridge = bridge
        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created)
        timebase = created
        if let created {
            CMTimebaseSetTime(created, time: .zero)
            CMTimebaseSetRate(created, rate: 0)
            layer.controlTimebase = created
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: bridge)
        controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = bridge
        controller.requiresLinearPlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = PictureInPictureSettings.automatic
        bridge.owner = self
        observe(playback)
    }

    func setAutomatic(_ enabled: Bool) {
        controller.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    /// 播放页上的小窗按钮
    func start() {
        guard !controller.isPictureInPictureActive else { return }
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }
        // 图层里还没有画面：先放一帧，再试一次
        grabStill { [weak self] in
            guard let self else { return }
            if self.controller.isPictureInPicturePossible {
                self.controller.startPictureInPicture()
            } else {
                self.playback?.notice = "现在还不能开小窗，等视频开始播放后再试"
            }
        }
    }

    func stop() {
        guard controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// 截一帧当前画面放进小窗图层（只截视频，不经过 GPU）。播放开始后和即将退到后台时各做一次，
    /// 这样系统认为可以开小窗，小窗飞出去时也是当前画面。
    func grabStill(then completion: (() -> Void)? = nil) {
        guard !grabbingStill, !controller.isPictureInPictureActive, let engine = playback?.engineForPictureInPicture else {
            completion?()
            return
        }
        grabbingStill = true
        PlayerPictureInPicture.engineQueue.async { [weak self] in
            let buffer = engine.rawVideoFrame().flatMap { PiPFrames.still(from: $0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.grabbingStill = false
                if let buffer, !self.controller.isPictureInPictureActive {
                    PiPFrames.enqueue(buffer, on: self.layer, format: &self.stillFormat)
                }
                // 图层收到画面后系统要一点时间才更新「可以开小窗」
                if let completion {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    completion()
                }
            }
        }
    }

    /// 切换内核输出都在这个串行队列上做（会阻塞到内核换好输出）
    static let engineQueue = DispatchQueue(label: "app.hplayer.pip.engine", qos: .userInitiated)

    // MARK: 和播放状态同步

    private func observe(_ playback: PlaybackController) {
        playback.$playing.combineLatest(playback.$effectiveRate)
            .sink { [weak self] playing, rate in
                guard let self else { return }
                self.bridge.paused = !playing
                if let timebase = self.timebase {
                    CMTimebaseSetRate(timebase, rate: playing ? Double(rate) : 0)
                }
                self.controller.invalidatePlaybackState()
            }
            .store(in: &subscriptions)
        playback.$currentTime
            .sink { [weak self] time in
                guard let self, let timebase = self.timebase, time.isFinite else { return }
                let current = CMTimebaseGetTime(timebase).seconds
                if !current.isFinite || abs(current - time) > 1 {
                    CMTimebaseSetTime(timebase, time: CMTime(seconds: time, preferredTimescale: 600))
                }
            }
            .store(in: &subscriptions)
        playback.$duration
            .removeDuplicates()
            .sink { [weak self] duration in
                guard let self else { return }
                self.bridge.range = duration > 0
                    ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
                    : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
                self.controller.invalidatePlaybackState()
            }
            .store(in: &subscriptions)
    }

    // MARK: 系统回调（都在主线程）

    fileprivate func setPlaying(_ playing: Bool) {
        guard let playback, playback.playing != playing else { return }
        playback.toggle()
    }

    fileprivate func skip(by seconds: Double) {
        playback?.skip(seconds)
    }

    fileprivate func renderSizeChanged(_ size: CMVideoDimensions) {
        playback?.pictureInPictureRenderSizeChanged(CGSize(width: Int(size.width), height: Int(size.height)))
    }

    fileprivate func willStart() {
        restoring = false
        playback?.pictureInPictureWillStart()
    }

    fileprivate func didStart() {
        playback?.pictureInPictureDidStart()
    }

    fileprivate func failedToStart(_ error: Error) {
        playback?.pictureInPictureDidStop(resume: true)
        playback?.notice = "小窗没有打开：\(error.localizedDescription)"
    }

    fileprivate func restore() {
        restoring = true
    }

    fileprivate func didStop() {
        playback?.pictureInPictureDidStop(resume: restoring)
        restoring = false
    }
}

/// 系统小窗的回调对象（AVKit 的两个代理），转给 PlayerPictureInPicture。
/// 查询类的回调（是否暂停、进度范围）要马上返回，所以这两项在这里存一份。
private final class PictureInPictureBridge: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    weak var owner: PlayerPictureInPicture?
    var paused = true
    var range = CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)

    // MARK: 播放控制

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        paused = !playing
        let owner = owner
        Task { @MainActor in owner?.setPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        range
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        paused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        let owner = owner
        Task { @MainActor in owner?.renderSizeChanged(newRenderSize) }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        let owner = owner
        let seconds = skipInterval.seconds
        Task { @MainActor in
            if seconds.isFinite { owner?.skip(by: seconds) }
            completionHandler()
        }
    }

    // MARK: 小窗开始 / 结束

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let owner = owner
        Task { @MainActor in owner?.willStart() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let owner = owner
        Task { @MainActor in owner?.didStart() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        let owner = owner
        Task { @MainActor in owner?.failedToStart(error) }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let owner = owner
        Task { @MainActor in
            owner?.restore()
            completionHandler(true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let owner = owner
        Task { @MainActor in owner?.didStop() }
    }
}
