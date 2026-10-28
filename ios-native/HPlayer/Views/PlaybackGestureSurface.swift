import SwiftUI
import UIKit

struct PlaybackGestureSurface: UIViewRepresentable {
    var status: String
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    var onBoost: (Bool) -> Void
    var onPan: (UIGestureRecognizer.State, CGPoint, CGPoint, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "playback.surface"
        view.accessibilityLabel = "播放画面"

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        longPress.minimumPressDuration = 0.6
        longPress.allowableMovement = 8
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: doubleTap)
        tap.require(toFail: longPress)
        doubleTap.require(toFail: pan)
        [pan, longPress, doubleTap, tap].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityValue = status
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.parent.onBoost(false)
        view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
    }

    final class Coordinator: NSObject {
        var parent: PlaybackGestureSurface
        private var boostActive = false
        private var panOrigin = CGPoint.zero

        init(_ parent: PlaybackGestureSurface) { self.parent = parent }
        @objc func tap() { parent.onTap() }
        @objc func doubleTap() { parent.onDoubleTap() }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                boostActive = true
                parent.onBoost(true)
            case .ended, .cancelled, .failed:
                if boostActive { parent.onBoost(false) }
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
            }
            parent.onPan(recognizer.state, panOrigin, translation, view.bounds.size)
        }
    }
}
