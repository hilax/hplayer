import SwiftUI
import UIKit

struct PlaybackGestureSurface: UIViewRepresentable {
    var status: String
    /// 是否启用双击识别；关闭时 `doubleTap.isEnabled = false`，单击可零延迟立即响应。
    var doubleTapEnabled: Bool = true
    /// 是否启用长按识别
    var longPressEnabled: Bool = true
    /// 长按触发时长（秒），0.30s 手感更干脆
    var longPressDuration: TimeInterval = 0.30
    /// 是否允许长按与拖动同时识别（滑动转进度拖动时为 true；上滑锁定倍速/仅按住时为 false）
    var allowSimultaneousPanWithLongPress: Bool = true
    /// 是否启用双指捏合手势
    var pinchEnabled: Bool = false

    var onTap: () -> Void
    var onDoubleTap: () -> Void = {}
    /// 带落点与画布尺寸的双击回调；设置后优先于 `onDoubleTap`
    var onDoubleTapAt: ((CGPoint, CGSize) -> Void)? = nil
    var onBoost: (Bool) -> Void
    /// 长按期间手指移动回调（用于上滑锁定倍速等附加手势）
    var onLongPressDrag: ((UIGestureRecognizer.State, CGPoint, CGPoint, CGSize) -> Void)? = nil
    var onPan: (UIGestureRecognizer.State, CGPoint, CGPoint, CGSize) -> Void
    /// 双指捏合回调：(state, scale, velocity)
    var onPinch: ((UIGestureRecognizer.State, CGFloat, CGFloat) -> Void)? = nil
    /// 这次拖动是从屏幕上下边缘起手的（下拉控制中心 / 通知中心、上滑回桌面的区域）
    var onPanStartsAtSystemEdge: (Bool) -> Void = { _ in }
    /// 这次拖动是从屏幕左右边缘起手的（全面屏侧滑返回 / 横屏虎口握持防误触区）
    var onPanStartsAtSideEdge: (Bool) -> Void = { _ in }

    /// 离屏幕上下边缘这么近起手的拖动，多半是系统手势（横屏时右上角下拉控制中心、底部上滑回桌面）
    static let systemEdgeZone: CGFloat = 44
    /// 离屏幕左右边缘这么近起手的横滑，多半是边缘手势或单手握持误触
    static let sideEdgeZone: CGFloat = 24

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "playback.surface"
        view.accessibilityLabel = "播放画面"

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        // 长按倍速和拖动是否同时识别由偏好控制：
        // - 滑动转进度拖动：同时识别，长按后一滑立刻退出倍速并接管拖动；
        // - 上滑锁定倍速 / 仅按住：互斥，避免长按上滑被拖动抢走。
        pan.delegate = context.coordinator

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        longPress.minimumPressDuration = longPressDuration
        longPress.allowableMovement = 8
        longPress.isEnabled = longPressEnabled
        longPress.delegate = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.isEnabled = pinchEnabled
        pinch.delegate = context.coordinator

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.isEnabled = doubleTapEnabled

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        // A drag, pinch, or long press must never also toggle the controls when the finger lifts.
        tap.require(toFail: pan)
        tap.require(toFail: doubleTap)
        tap.require(toFail: longPress)
        tap.require(toFail: pinch)
        doubleTap.require(toFail: pan)
        doubleTap.require(toFail: pinch)

        context.coordinator.doubleTapRecognizer = doubleTap
        context.coordinator.longPressRecognizer = longPress
        context.coordinator.pinchRecognizer = pinch

        [pan, longPress, pinch, doubleTap, tap].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityValue = status
        context.coordinator.doubleTapRecognizer?.isEnabled = doubleTapEnabled
        if let longPress = context.coordinator.longPressRecognizer {
            longPress.isEnabled = longPressEnabled
            if abs(longPress.minimumPressDuration - longPressDuration) > 0.001 {
                longPress.minimumPressDuration = longPressDuration
            }
        }
        context.coordinator.pinchRecognizer?.isEnabled = pinchEnabled
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.parent.onBoost(false)
        view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlaybackGestureSurface
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        weak var longPressRecognizer: UILongPressGestureRecognizer?
        weak var pinchRecognizer: UIPinchGestureRecognizer?

        private var boostActive = false
        private var panOrigin = CGPoint.zero
        private var longPressOrigin = CGPoint.zero

        init(_ parent: PlaybackGestureSurface) { self.parent = parent }

        /// 仅在开启「滑动转进度拖动」时允许拖动和长按倍速同时识别；其余组合保持系统互斥
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard parent.allowSimultaneousPanWithLongPress else { return false }
            let pair = [gestureRecognizer, other]
            return pair.contains { $0 is UIPanGestureRecognizer } && pair.contains { $0 is UILongPressGestureRecognizer }
        }

        @objc func tap() { parent.onTap() }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else {
                parent.onDoubleTap()
                return
            }
            if let onDoubleTapAt = parent.onDoubleTapAt {
                onDoubleTapAt(recognizer.location(in: view), view.bounds.size)
            } else {
                parent.onDoubleTap()
            }
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                longPressOrigin = location
                boostActive = true
                parent.onBoost(true)
                parent.onLongPressDrag?(.began, longPressOrigin, .zero, view.bounds.size)
            case .changed:
                guard boostActive else { return }
                let translation = CGPoint(x: location.x - longPressOrigin.x, y: location.y - longPressOrigin.y)
                parent.onLongPressDrag?(.changed, longPressOrigin, translation, view.bounds.size)
            case .ended, .cancelled, .failed:
                if boostActive {
                    let translation = CGPoint(x: location.x - longPressOrigin.x, y: location.y - longPressOrigin.y)
                    parent.onLongPressDrag?(recognizer.state, longPressOrigin, translation, view.bounds.size)
                    parent.onBoost(false)
                }
                boostActive = false
            default: break
            }
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            if recognizer.state == .began {
                let location = recognizer.location(in: view)
                panOrigin = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                if boostActive { parent.onBoost(false); boostActive = false }
                // 按整块屏幕算起手点离上下 / 左右边缘多远（播放画面不一定占满屏幕）
                if let window = view.window {
                    let start = view.convert(panOrigin, to: window)
                    let verticalZone = PlaybackGestureSurface.systemEdgeZone
                    let sideZone = PlaybackGestureSurface.sideEdgeZone
                    parent.onPanStartsAtSystemEdge(start.y < verticalZone || start.y > window.bounds.height - verticalZone)
                    parent.onPanStartsAtSideEdge(start.x < sideZone || start.x > window.bounds.width - sideZone)
                } else {
                    parent.onPanStartsAtSystemEdge(false)
                    parent.onPanStartsAtSideEdge(false)
                }
            }
            parent.onPan(recognizer.state, panOrigin, translation, view.bounds.size)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began, boostActive {
                parent.onBoost(false)
                boostActive = false
            }
            parent.onPinch?(recognizer.state, recognizer.scale, recognizer.velocity)
        }
    }
}
