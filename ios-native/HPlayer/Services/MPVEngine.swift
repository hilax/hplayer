import AVFoundation
import Foundation
import Libmpv
import QuartzCore

/// mpv 播放内核的薄封装：创建、设置选项、发命令、读写属性，以及把内核事件转回主线程。
///
/// mpv 的 C 接口本身是线程安全的；事件在后台串行队列里取出，再整理成 `MPVEvent` 交给主线程处理。
final class MPVEngine {
    enum Value {
        case double(Double)
        case flag(Bool)
        case int(Int64)
        case string(String)
        case none
    }

    enum Event {
        case property(String, Value)
        case startFile
        case fileLoaded
        case playbackRestart
        /// reason：eof / stop / quit / error / redirect；error 是 mpv 给出的错误说明
        case endFile(reason: Int32, error: String?)
        /// 内核的警告和错误日志
        case log(String)
    }

    private(set) var handle: OpaquePointer?
    /// 小窗播放时的 CPU 出图；平时为空，画面由 gpu-next 画在 Metal 图层上
    private var softwareOutput: MPVSoftwareOutput?
    private let outputLock = NSLock()
    private let queue = DispatchQueue(label: "app.hplayer.mpv.events", qos: .userInitiated)
    private let queueIdentity = DispatchSpecificKey<Bool>()
    /// 在主线程调用
    var onEvent: ((Event) -> Void)?

    init?(options: [(String, String)], layer: CAMetalLayer) {
        queue.setSpecific(key: queueIdentity, value: true)
        guard let mpv = mpv_create() else { return nil }
        handle = mpv
        // 警告和错误留着，播放出问题时可以复制给开发者看
        mpv_request_log_messages(mpv, "warn")
        attach(layer: layer, beforeInitialize: true)
        for (name, value) in options {
            mpv_set_option_string(mpv, name, value)
        }
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return nil
        }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let engine = Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue()
            engine.drainEvents()
        }, context)
    }

    deinit {
        destroy()
    }

    /// 画面画在这个 Metal 图层上；换了新的播放页面时把新图层交给内核，下一次打开视频生效
    func attach(layer: CAMetalLayer, beforeInitialize: Bool = false) {
        guard let handle else { return }
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        if beforeInitialize {
            mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        } else {
            mpv_set_property(handle, "wid", MPV_FORMAT_INT64, &wid)
        }
    }

    func destroy() {
        guard let mpv = handle else { return }
        // 渲染上下文必须在内核销毁之前释放
        outputLock.lock()
        let output = softwareOutput
        softwareOutput = nil
        outputLock.unlock()
        output?.shutdown()
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        // 最后一个引用可能由 drainEvents 的闭包释放；这时已经在事件队列上。
        if DispatchQueue.getSpecific(key: queueIdentity) == true {
            mpv_terminate_destroy(mpv)
        } else {
            queue.sync { mpv_terminate_destroy(mpv) }
        }
    }

    // MARK: 属性

    func observe(_ name: String, _ format: mpv_format) {
        guard let handle else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    func set(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    func set(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    func set(_ name: String, _ value: Double) {
        guard let handle else { return }
        var number = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &number)
    }

    func string(_ name: String) -> String? {
        guard let handle, let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func double(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func int(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    func flag(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var value: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    // MARK: 命令

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        var pointers: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer -> Int32 in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                mpv_command(handle, $0)
            }
        }
    }

    // MARK: 小窗播放

    /// 切到 CPU 出图：先建好渲染上下文，再把视频输出换成 libmpv，画面改画进小窗用的图层。
    /// 退到后台以后不能再用 GPU，所以小窗播放期间不走 gpu-next。
    /// 换输出要等内核重建视频链，会阻塞几十毫秒：不要在主线程调用。
    /// 锁只保护 softwareOutput 这个引用，调用内核期间不持有：换输出时内核可能要回主线程（打开 EDR），
    /// 主线程要是在等这把锁就会卡死。开始和结束都在同一个串行队列上调用，彼此不会交错。
    @discardableResult
    func startSoftwareOutput(layer: AVSampleBufferDisplayLayer, hwdec: String, videoSize: CGSize) -> Bool {
        guard let handle else { return false }
        outputLock.lock()
        let existing = softwareOutput
        outputLock.unlock()
        if let existing {
            existing.videoSize = videoSize
            return true
        }
        guard let output = MPVSoftwareOutput(mpv: handle, layer: layer) else { return false }
        output.videoSize = videoSize
        outputLock.lock()
        softwareOutput = output
        outputLock.unlock()
        mpv_set_property_string(handle, "vid", "auto")
        // 硬解码要把帧拷回内存才能交给 CPU 出图
        mpv_set_property_string(handle, "hwdec", hwdec)
        guard mpv_set_property_string(handle, "vo", "libmpv") >= 0 else {
            mpv_set_property_string(handle, "vo", "gpu-next")
            outputLock.lock()
            softwareOutput = nil
            outputLock.unlock()
            output.shutdown()
            return false
        }
        return true
    }

    /// 小窗结束：换回 gpu-next。还在后台时先关掉画面只留声音，回到前台时再打开（和平时退到后台一样）
    func stopSoftwareOutput(hwdec: String, keepVideo: Bool) {
        guard let handle else { return }
        outputLock.lock()
        let output = softwareOutput
        outputLock.unlock()
        guard let output else { return }
        if !keepVideo { mpv_set_property_string(handle, "vid", "no") }
        mpv_set_property_string(handle, "vo", "gpu-next")
        mpv_set_property_string(handle, "hwdec", hwdec)
        outputLock.lock()
        softwareOutput = nil
        outputLock.unlock()
        output.shutdown()
    }

    var softwareOutputActive: Bool {
        outputLock.lock()
        defer { outputLock.unlock() }
        return softwareOutput != nil
    }

    func setSoftwareOutput(videoSize: CGSize? = nil, renderSize: CGSize? = nil) {
        outputLock.lock()
        let output = softwareOutput
        outputLock.unlock()
        if let videoSize { output?.videoSize = videoSize }
        if let renderSize { output?.renderSize = renderSize }
    }

    struct RawFrame {
        let width: Int
        let height: Int
        let stride: Int
        let pixels: Data
    }

    /// 当前这一帧画面（不含字幕），BGR0 像素，用 CPU 转换，不经过 GPU。
    /// 4K 视频一帧有三十多 MB：只在需要时偶尔取一次，不要放在主线程。
    func rawVideoFrame() -> RawFrame? {
        guard let handle else { return nil }
        var result = mpv_node()
        let args = ["screenshot-raw", "video"]
        var pointers: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let status = pointers.withUnsafeMutableBufferPointer { mpv_command_ret(handle, $0.baseAddress, &result) }
        guard status >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list?.pointee else { return nil }
        var width = 0, height = 0, stride = 0
        var format = ""
        var pixels: Data?
        for index in 0..<Int(list.num) {
            guard let rawKey = list.keys[index] else { continue }
            let key = String(cString: rawKey)
            let node = list.values[index]
            switch (key, node.format) {
            case ("w", MPV_FORMAT_INT64): width = Int(node.u.int64)
            case ("h", MPV_FORMAT_INT64): height = Int(node.u.int64)
            case ("stride", MPV_FORMAT_INT64): stride = Int(node.u.int64)
            case ("format", MPV_FORMAT_STRING):
                if let text = node.u.string { format = String(cString: text) }
            case ("data", MPV_FORMAT_BYTE_ARRAY):
                if let array = node.u.ba?.pointee, let bytes = array.data {
                    pixels = Data(bytes: bytes, count: array.size)
                }
            default:
                break
            }
        }
        guard format == "bgr0", width > 0, height > 0, stride >= width * 4,
              let pixels, pixels.count >= stride * height else { return nil }
        return RawFrame(width: width, height: height, stride: stride, pixels: pixels)
    }

    // MARK: 事件

    private func drainEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            var collected: [Event] = []
            while let handle = self.handle {
                guard let event = mpv_wait_event(handle, 0) else { break }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                if let converted = Self.convert(event.pointee) { collected.append(converted) }
                if id == MPV_EVENT_SHUTDOWN { break }
            }
            guard !collected.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let onEvent = self.onEvent else { return }
                collected.forEach(onEvent)
            }
        }
    }

    private static func convert(_ event: mpv_event) -> Event? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let pointer = event.data?.assumingMemoryBound(to: mpv_event_property.self) else { return nil }
            let property = pointer.pointee
            let name = String(cString: property.name)
            guard let data = property.data else { return .property(name, .none) }
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                return .property(name, .double(data.assumingMemoryBound(to: Double.self).pointee))
            case MPV_FORMAT_FLAG:
                return .property(name, .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0))
            case MPV_FORMAT_INT64:
                return .property(name, .int(data.assumingMemoryBound(to: Int64.self).pointee))
            case MPV_FORMAT_STRING:
                guard let text = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else {
                    return .property(name, .none)
                }
                return .property(name, .string(String(cString: text)))
            default:
                return .property(name, .none)
            }
        case MPV_EVENT_START_FILE:
            return .startFile
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_END_FILE:
            guard let pointer = event.data?.assumingMemoryBound(to: mpv_event_end_file.self) else { return nil }
            let info = pointer.pointee
            let reason = Int32(bitPattern: info.reason.rawValue)
            let message = info.error < 0 ? String(cString: mpv_error_string(info.error)) : nil
            return .endFile(reason: reason, error: message)
        case MPV_EVENT_LOG_MESSAGE:
            guard let pointer = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) else { return nil }
            let message = pointer.pointee
            let line = "[\(String(cString: message.prefix))] \(String(cString: message.level)): \(String(cString: message.text))"
            #if DEBUG
            print(line, terminator: "")
            #endif
            return .log(line.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
