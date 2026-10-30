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
    private let queue = DispatchQueue(label: "app.hplayer.mpv.events", qos: .userInitiated)
    /// 在主线程调用
    var onEvent: ((Event) -> Void)?

    init?(options: [(String, String)], layer: CAMetalLayer) {
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
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        queue.sync {
            mpv_terminate_destroy(mpv)
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
