import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 播放页右侧上下滑动调节的是 iPhone 的系统音量，而不是 VLC 内部的软件音量。
///
/// - 写入：通过隐藏的 MPVolumeView 滑块设置系统音量，与音量键、控制中心是同一个值。
/// - 读取：监听 AVAudioSession.outputVolume，按音量键或在控制中心调节时同步回来。
/// - 播放页里放着 MPVolumeView 时，系统自带的音量浮层不会再弹出，由播放页自己的小提示代替。
@MainActor
final class SystemVolumeController: ObservableObject {
    /// 当前系统音量（0...1）
    @Published private(set) var level: Double
    /// 用户按音量键或在控制中心改了音量时递增，播放页据此显示音量提示。
    @Published private(set) var externalChangeCount = 0

    private weak var slider: UISlider?
    private var observation: NSKeyValueObservation?
    private var lastProgrammaticChange = Date.distantPast
    private var pendingValue: Double?

    init() {
        level = Double(AVAudioSession.sharedInstance().outputVolume)
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        level = Double(session.outputVolume)
        guard observation == nil else { return }
        // KVO 可能在任意线程回调，切回主线程再更新
        observation = session.observe(\.outputVolume, options: [.new]) { @Sendable [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.systemVolumeDidChange(Double(value))
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    /// 找到了系统音量滑块（模拟器等环境可能没有）
    var controlsSystemVolume: Bool { slider != nil }

    func attach(_ slider: UISlider) {
        self.slider = slider
        if let pendingValue { apply(pendingValue) }
    }

    func set(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        level = clamped
        lastProgrammaticChange = Date()
        apply(clamped)
    }

    private func apply(_ value: Double) {
        guard let slider else {
            pendingValue = value
            return
        }
        pendingValue = nil
        let target = Float(value)
        guard abs(slider.value - target) > 0.001 else { return }
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    private func systemVolumeDidChange(_ value: Double) {
        let programmatic = Date().timeIntervalSince(lastProgrammaticChange) < 0.5
        if programmatic { return }
        level = min(max(value, 0), 1)
        externalChangeCount += 1
    }
}

/// 把 MPVolumeView 放进播放页的视图层级：它几乎透明且不接收触摸，只用来驱动系统音量。
struct SystemVolumeHost: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        DispatchQueue.main.async {
            if let slider = Self.findSlider(in: view) { controller.attach(slider) }
        }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    private static func findSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider { return slider }
            if let slider = findSlider(in: subview) { return slider }
        }
        return nil
    }
}
