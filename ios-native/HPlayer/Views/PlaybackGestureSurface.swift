import CoreHaptics
import SwiftUI
import UIKit

/// 滑动快进 / 进度条拖动速度档位（决定 CoreHaptics 刻度质感）
enum SeekHapticSpeed: Equatable {
    case slow
    case normal
    case fast
}

/// 触感轨迹模式：全屏横滑与细进度条采用不同的物理刻度步长
enum SeekHapticMode: Equatable {
    case pan
    case scrubber

    var stepPoints: Double {
        switch self {
        case .pan: return 10.0
        case .scrubber: return 8.0
        }
    }
}

/// 滑动快进 / 进度条拖动震动事件类型
enum SeekHapticEvent: Equatable {
    case begin
    case tick(speed: SeekHapticSpeed)
    case majorTick
    case origin
    case boundary
    case commit
    case cancelToggle(cancelled: Bool)
}

/// 滑动快进 / 进度条拖动触感节奏控制器：
/// - 优先按屏幕物理位移刻度（pan 10pt / scrubber 8pt）与迟滞锚点触发，任何片长和灵敏度下都紧密跟手、不抖动误触；
/// - 24ms 最短节流且被节流时不提前推进锚点，高速扫过时不会丢段，并按指速切换清脆锐度；
/// - 每 5 个刻度输出一次大刻度（majorTick），滑回起点输出一次原点凹槽（origin）；
/// - 滑到片头（0）或片尾边界触发一次厚重边界阻尼（boundary），停在边界不连震；
/// - 松手落点位移 >= 0.5s 时给一次扎实落定反馈（commit）。
struct SeekHapticTracker {
    enum Edge: Equatable { case none, start, end }

    static let minTickInterval: TimeInterval = 0.024
    static let majorTickStride = 5
    static let slowSpeedThreshold: Double = 140.0
    static let fastSpeedThreshold: Double = 480.0
    static let commitThresholdSeconds: Double = 0.5

    let mode: SeekHapticMode

    private(set) var lastTickTime: Double = 0
    private(set) var lastTickUptime: TimeInterval = -.infinity
    private(set) var hitEdge: Edge = .none
    private(set) var startTime: Double = 0
    private(set) var isActive = false

    private(set) var startPositionPt: Double?
    private(set) var lastAnchorPt: Double?
    private(set) var lastPositionPt: Double?
    private(set) var lastSampleUptime: TimeInterval = -.infinity
    private(set) var smoothedVelocityPtPerSec: Double = 0
    private(set) var ticksSinceBegin: Int = 0
    private(set) var leftOrigin: Bool = false

    init(mode: SeekHapticMode = .pan) {
        self.mode = mode
    }

    static func stepSeconds(for duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 10.0 }
        if duration <= 30 { return 1.0 }
        if duration <= 180 { return 3.0 }
        if duration <= 900 { return 5.0 }
        return 10.0
    }

    static func speedClass(for velocityPtPerSec: Double) -> SeekHapticSpeed {
        if velocityPtPerSec < slowSpeedThreshold { return .slow }
        if velocityPtPerSec < fastSpeedThreshold { return .normal }
        return .fast
    }

    mutating func begin(
        at time: Double,
        duration: Double,
        positionPt: Double? = nil,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> SeekHapticEvent {
        startTime = time
        lastTickTime = time
        lastTickUptime = now
        hitEdge = .none
        isActive = true
        startPositionPt = positionPt
        lastAnchorPt = positionPt
        lastPositionPt = positionPt
        lastSampleUptime = now
        smoothedVelocityPtPerSec = 0
        ticksSinceBegin = 0
        leftOrigin = false
        return .begin
    }

    mutating func update(
        target: Double,
        duration: Double,
        upperBound: Double? = nil,
        positionPt: Double? = nil,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> SeekHapticEvent? {
        guard isActive, duration > 0, target.isFinite else { return nil }
        let maxBound = upperBound.map { min(max($0, 0), duration) } ?? duration
        let clamped = min(max(target, 0), maxBound)

        if let posPt = positionPt {
            if let prevPt = lastPositionPt {
                let dt = now - lastSampleUptime
                if dt > 0.001 {
                    let instant = abs(posPt - prevPt) / dt
                    smoothedVelocityPtPerSec = smoothedVelocityPtPerSec == 0
                        ? instant
                        : smoothedVelocityPtPerSec * 0.45 + instant * 0.55
                }
            }
            lastPositionPt = posPt
            lastSampleUptime = now
        }

        let edge: Edge
        if clamped <= 0.05 {
            edge = .start
        } else if clamped >= max(0, maxBound - 0.5) {
            edge = .end
        } else {
            edge = .none
        }

        if edge != .none {
            lastAnchorPt = positionPt
            lastTickTime = clamped
            if hitEdge != edge {
                hitEdge = edge
                lastTickUptime = now
                return .boundary
            }
            return nil
        }
        hitEdge = .none

        if let posPt = positionPt {
            if lastAnchorPt == nil {
                startPositionPt = posPt
                lastAnchorPt = posPt
            }
            let anchorPt = lastAnchorPt!
            let originPt = startPositionPt ?? 0
            let distFromOrigin = abs(posPt - originPt)
            if !leftOrigin && distFromOrigin >= mode.stepPoints * 1.6 {
                leftOrigin = true
            }
            if leftOrigin {
                let prevOffset = anchorPt - originPt
                let currOffset = posPt - originPt
                if distFromOrigin <= mode.stepPoints * 0.45 || (prevOffset * currOffset < 0) {
                    leftOrigin = false
                    lastAnchorPt = posPt
                    lastTickTime = clamped
                    ticksSinceBegin = 0
                    lastTickUptime = now
                    return .origin
                }
            }
            guard abs(posPt - anchorPt) >= mode.stepPoints else { return nil }
            guard now - lastTickUptime >= Self.minTickInterval else { return nil }
            lastAnchorPt = posPt
            lastTickTime = clamped
            lastTickUptime = now
            ticksSinceBegin += 1
            return ticksSinceBegin % Self.majorTickStride == 0
                ? .majorTick
                : .tick(speed: Self.speedClass(for: smoothedVelocityPtPerSec))
        } else {
            let step = Self.stepSeconds(for: duration)
            if !leftOrigin && abs(clamped - startTime) >= step * 1.6 {
                leftOrigin = true
            }
            if leftOrigin {
                let prevOff = lastTickTime - startTime
                let currOff = clamped - startTime
                if abs(clamped - startTime) <= step * 0.45 || (prevOff * currOff < 0) {
                    leftOrigin = false
                    lastTickTime = clamped
                    ticksSinceBegin = 0
                    lastTickUptime = now
                    return .origin
                }
            }
            guard abs(clamped - lastTickTime) >= step else { return nil }
            guard now - lastTickUptime >= Self.minTickInterval else { return nil }
            lastTickTime = clamped
            lastTickUptime = now
            ticksSinceBegin += 1
            return ticksSinceBegin % Self.majorTickStride == 0
                ? .majorTick
                : .tick(speed: .normal)
        }
    }

    mutating func end(finalTarget: Double?) -> SeekHapticEvent? {
        defer { reset() }
        guard isActive, let finalTarget, abs(finalTarget - startTime) >= Self.commitThresholdSeconds else { return nil }
        return .commit
    }

    mutating func reset() {
        isActive = false
        lastTickTime = 0
        hitEdge = .none
        startPositionPt = nil
        lastAnchorPt = nil
        lastPositionPt = nil
        lastSampleUptime = -.infinity
        smoothedVelocityPtPerSec = 0
        ticksSinceBegin = 0
        leftOrigin = false
    }
}

/// 播放器滑动 / 进度条拖动触感反馈：
/// 优先使用独立 `CHHapticEngine`（`playsHapticsOnly = true`，不干扰 mpv 音频会话）与预编译 `CHHapticPatternPlayer`；
/// 在不支持 CoreHaptics 的设备或引擎恢复窗口期自动降级到预热 UIKit 刚性冲击反馈，确保零漏震。
@MainActor
enum PlayerHaptics {
    private enum PatternKey: CaseIterable, Hashable {
        case begin
        case tickSlow
        case tickNormal
        case tickFast
        case majorTick
        case origin
        case boundary
        case commit
        case cancelEnter
        case cancelExit
        case tap
    }

    private static var engine: CHHapticEngine?
    private static var engineStarted = false
    private static var players: [PatternKey: CHHapticPatternPlayer] = [:]

    private static let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)

    static func warmUp() {
        prepareFallbackGenerators()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        ensureEngine()
        if let engine {
            buildPlayersIfNeeded(on: engine)
        }
    }

    static func prepareForSeek() {
        warmUp()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let engine else { return }
        if !engineStarted {
            do {
                try engine.start()
                engineStarted = true
            } catch {
                engineStarted = false
            }
        }
        buildPlayersIfNeeded(on: engine)
    }

    static func cooldown() {
        engineStarted = false
        engine?.stop(completionHandler: nil)
    }

    static func fire(_ event: SeekHapticEvent?) {
        guard let event else { return }
        let key = patternKey(for: event)
        if playCoreHaptic(key) {
            return
        }
        fireFallback(for: event)
    }

    static func tap() {
        if playCoreHaptic(.tap) {
            return
        }
        rigidImpact.impactOccurred(intensity: 0.78)
        rigidImpact.prepare()
    }

    // MARK: CoreHaptics 管理

    private static func ensureEngine() {
        guard engine == nil else { return }
        do {
            let created = try CHHapticEngine()
            // 必须在 start() 前设置，避免与 mpv 音频会话争抢或触发闪避
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = true
            created.stoppedHandler = { _ in
                Task { @MainActor in
                    engineStarted = false
                }
            }
            created.resetHandler = {
                Task { @MainActor in
                    engineStarted = false
                    players.removeAll()
                    guard let current = engine else { return }
                    do {
                        try current.start()
                        engineStarted = true
                        buildPlayersIfNeeded(on: current)
                    } catch {
                        engineStarted = false
                    }
                }
            }
            engine = created
        } catch {
            engine = nil
            engineStarted = false
        }
    }

    private static func buildPlayersIfNeeded(on engine: CHHapticEngine) {
        guard players.count < PatternKey.allCases.count else { return }
        for key in PatternKey.allCases where players[key] == nil {
            guard let pattern = makePattern(for: key),
                  let player = try? engine.makePlayer(with: pattern) else { continue }
            players[key] = player
        }
    }

    private static func playCoreHaptic(_ key: PatternKey) -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }
        ensureEngine()
        guard let engine else { return false }
        if !engineStarted {
            do {
                try engine.start()
                engineStarted = true
            } catch {
                engineStarted = false
                return false
            }
        }
        buildPlayersIfNeeded(on: engine)
        guard let player = players[key] else { return false }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            engineStarted = false
            players.removeAll()
            return false
        }
    }

    private static func patternKey(for event: SeekHapticEvent) -> PatternKey {
        switch event {
        case .begin: return .begin
        case .tick(let speed):
            switch speed {
            case .slow: return .tickSlow
            case .normal: return .tickNormal
            case .fast: return .tickFast
            }
        case .majorTick: return .majorTick
        case .origin: return .origin
        case .boundary: return .boundary
        case .commit: return .commit
        case .cancelToggle(let cancelled): return cancelled ? .cancelEnter : .cancelExit
        }
    }

    private static func makePattern(for key: PatternKey) -> CHHapticPattern? {
        let events: [CHHapticEvent]
        switch key {
        case .begin:
            events = [transientEvent(intensity: 0.85, sharpness: 0.82)]
        case .tickSlow:
            events = [transientEvent(intensity: 0.68, sharpness: 0.84)]
        case .tickNormal:
            events = [transientEvent(intensity: 0.82, sharpness: 0.90)]
        case .tickFast:
            events = [transientEvent(intensity: 0.76, sharpness: 0.98)]
        case .majorTick:
            events = [transientEvent(intensity: 0.96, sharpness: 0.60)]
        case .origin:
            events = [transientEvent(intensity: 0.98, sharpness: 0.50)]
        case .boundary:
            events = [
                transientEvent(time: 0, intensity: 1.0, sharpness: 0.42),
                transientEvent(time: 0.028, intensity: 0.58, sharpness: 0.22),
            ]
        case .commit:
            events = [transientEvent(intensity: 0.90, sharpness: 0.55)]
        case .cancelEnter:
            events = [
                transientEvent(time: 0, intensity: 0.90, sharpness: 0.34),
                transientEvent(time: 0.048, intensity: 0.68, sharpness: 0.22),
            ]
        case .cancelExit:
            events = [transientEvent(intensity: 0.78, sharpness: 0.86)]
        case .tap:
            events = [transientEvent(intensity: 0.78, sharpness: 0.82)]
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    private static func transientEvent(time: TimeInterval = 0, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }

    // MARK: UIKit 降级反馈

    private static func prepareFallbackGenerators() {
        rigidImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()
    }

    private static func fireFallback(for event: SeekHapticEvent) {
        switch event {
        case .begin:
            rigidImpact.impactOccurred(intensity: 0.85)
            rigidImpact.prepare()
        case .tick(let speed):
            let intensity: CGFloat
            switch speed {
            case .slow: intensity = 0.68
            case .normal: intensity = 0.82
            case .fast: intensity = 0.76
            }
            rigidImpact.impactOccurred(intensity: intensity)
            rigidImpact.prepare()
        case .majorTick:
            mediumImpact.impactOccurred(intensity: 0.96)
            mediumImpact.prepare()
        case .origin:
            mediumImpact.impactOccurred(intensity: 1.0)
            mediumImpact.prepare()
        case .boundary:
            heavyImpact.impactOccurred(intensity: 1.0)
            heavyImpact.prepare()
        case .commit:
            mediumImpact.impactOccurred(intensity: 0.90)
            mediumImpact.prepare()
        case .cancelToggle(let cancelled):
            if cancelled {
                mediumImpact.impactOccurred(intensity: 0.92)
                mediumImpact.prepare()
            } else {
                rigidImpact.impactOccurred(intensity: 0.78)
                rigidImpact.prepare()
            }
        }
    }
}

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
