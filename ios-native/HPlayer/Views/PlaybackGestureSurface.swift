import CoreHaptics
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

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
    private static var engineStarting = false
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
        guard !engineStarted && !engineStarting else { return }
        engineStarting = true
        // 异步预热 CoreHaptics 引擎，避免自动休眠唤醒时在手势 .began 阻塞主线程
        engine.start { error in
            Task { @MainActor in
                engineStarting = false
                if error == nil {
                    engineStarted = true
                    if let current = Self.engine {
                        buildPlayersIfNeeded(on: current)
                    }
                } else {
                    engineStarted = false
                }
            }
        }
    }

    static func cooldown() {
        engineStarted = false
        engineStarting = false
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
                    engineStarting = false
                }
            }
            created.resetHandler = {
                Task { @MainActor in
                    engineStarted = false
                    engineStarting = false
                    players.removeAll()
                    prepareForSeek()
                }
            }
            engine = created
        } catch {
            engine = nil
            engineStarted = false
            engineStarting = false
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
            prepareForSeek()
            return false
        }
        buildPlayersIfNeeded(on: engine)
        guard let player = players[key] else { return false }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            engineStarted = false
            engineStarting = false
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

/// 播放器画布拖动事件的完整快照，避免边缘状态经由 SwiftUI `@State` 异步中转导致竞态。
struct PlaybackPanEvent: Equatable {
    let state: UIGestureRecognizer.State
    let origin: CGPoint
    let translation: CGPoint
    let size: CGSize
    let startsAtSystemEdge: Bool
    let startsAtSideEdge: Bool
}

enum PlaybackPanAxis: Equatable {
    case horizontal
    case vertical
}

enum PlaybackPanDecision: Equatable {
    case undecided
    case lock(axis: PlaybackPanAxis, base: CGPoint)
    case reject
}

/// 播放器画布单指滑动的方向锁定与死区基准计算：
/// - 横滑阈值 8pt、竖滑阈值 12pt，避免起手瞬间轻微纵向滚动抢走横滑快进；
/// - 与水平夹角约 50° 以内优先判为横滑（`dx >= dy * 0.84`）；
/// - 锁定基准偏移按死区上限截断，慢滑起手零跳变，快速轻甩也不会把整段位移吞成 0；
/// - 当某一方向被禁用或处于系统边缘保护区时，不因轻微抖动立即中止整次手势，仅在明确走入禁用方向（>= 36pt）时放弃。
enum PlaybackPanResolver {
    static let horizontalLockDistance: CGFloat = 8
    static let verticalLockDistance: CGFloat = 12
    static let horizontalBias: CGFloat = 0.84
    static let rejectCrossAxisDistance: CGFloat = 36

    static func deadzoneBase(_ delta: CGFloat, cap: CGFloat) -> CGFloat {
        guard delta != 0 else { return 0 }
        return copysign(min(abs(delta), cap), delta)
    }

    static func resolve(
        translation: CGPoint,
        horizontalAllowed: Bool,
        verticalAllowed: Bool,
        isEnded: Bool
    ) -> PlaybackPanDecision {
        guard horizontalAllowed || verticalAllowed else { return .reject }
        let dx = abs(translation.x)
        let dy = abs(translation.y)

        let horizontalLeaning = dx >= dy * horizontalBias
        if horizontalLeaning {
            guard dx >= horizontalLockDistance else {
                return isEnded ? .reject : .undecided
            }
            if horizontalAllowed {
                let base = CGPoint(
                    x: deadzoneBase(translation.x, cap: horizontalLockDistance),
                    y: translation.y
                )
                return .lock(axis: .horizontal, base: base)
            }
            // 横滑不可用（例如靠左右边缘起手），仅当明显是纯横滑时才放弃，避免误杀随后的竖滑调节
            if dx >= rejectCrossAxisDistance && dy < dx * 0.5 {
                return .reject
            }
            return isEnded ? .reject : .undecided
        } else {
            guard dy >= verticalLockDistance else {
                return isEnded ? .reject : .undecided
            }
            if verticalAllowed {
                let base = CGPoint(
                    x: translation.x,
                    y: deadzoneBase(translation.y, cap: verticalLockDistance)
                )
                return .lock(axis: .vertical, base: base)
            }
            // 竖滑不可用（例如底边/顶边系统手势区、锁屏或关闭竖滑），仅当明确是陡峭竖滑时才放弃，
            // 起手轻微纵向抖动随后拉平为横滑时仍能顺利进入快进/快退
            if dy >= rejectCrossAxisDistance && dx < dy * 0.5 {
                return .reject
            }
            return isEnded ? .reject : .undecided
        }
    }
}

/// 播放器专用拖动手势识别器：
/// 1. 在 `touchesBegan` 精确记录落点（视图坐标与窗口坐标），消除 UIKit 滞回导致的起手点偏移与双重死区；
/// 2. 持续追踪主触点末位置，确保 `.ended` 时总位移精确不归零；
/// 3. 容忍全面屏横屏握持时的掌心/拇指搭边：当边缘存在静止触点且主画面区落入新触点时自动忽略边缘误触，
///    同时不影响主画面区内的正常双指捏合手势。
final class PlaybackPanGestureRecognizer: UIPanGestureRecognizer {
    var bezelSideWidth: CGFloat = PlaybackGestureSurface.sideEdgeZone
    var bezelVerticalHeight: CGFloat = PlaybackGestureSurface.systemEdgeZone
    var onTouchDown: (() -> Void)?

    private(set) var trackedTouch: UITouch?
    private(set) var touchOriginInView: CGPoint?
    private(set) var touchOriginInWindow: CGPoint?
    private(set) var lastTrackedLocationInView: CGPoint?

    static func isBezelEdge(pointInWindow: CGPoint, windowBounds: CGRect, sideWidth: CGFloat, verticalHeight: CGFloat) -> Bool {
        guard windowBounds.width > 0, windowBounds.height > 0 else { return false }
        let nearSide = pointInWindow.x < sideWidth || pointInWindow.x > windowBounds.width - sideWidth
        let nearVertical = pointInWindow.y < verticalHeight || pointInWindow.y > windowBounds.height - verticalHeight
        return nearSide || nearVertical
    }

    func totalTranslation(in view: UIView) -> CGPoint {
        guard let origin = touchOriginInView else {
            return translation(in: view)
        }
        let current: CGPoint
        if let touch = trackedTouch, numberOfTouches > 0 {
            current = touch.location(in: view)
        } else if let last = lastTrackedLocationInView {
            current = last
        } else {
            return translation(in: view)
        }
        return CGPoint(x: current.x - origin.x, y: current.y - origin.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchDown?()

        if state == .began || state == .changed {
            for touch in touches {
                ignore(touch, for: event)
            }
            return
        }

        guard let view else {
            super.touchesBegan(touches, with: event)
            return
        }

        let incoming = Array(touches)
        let nonEdgeIncoming = incoming.filter { !isInBezelEdge($0, in: view) }
        let edgeIncoming = incoming.filter { isInBezelEdge($0, in: view) }

        if trackedTouch == nil {
            if !nonEdgeIncoming.isEmpty && !edgeIncoming.isEmpty {
                for touch in edgeIncoming {
                    ignore(touch, for: event)
                }
                if nonEdgeIncoming.count == 1, let primary = nonEdgeIncoming.first {
                    recordPrimaryTouch(primary, in: view)
                }
                super.touchesBegan(Set(nonEdgeIncoming), with: event)
                return
            }
            if incoming.count == 1, let primary = incoming.first {
                recordPrimaryTouch(primary, in: view)
            }
            super.touchesBegan(touches, with: event)
            return
        }

        if let existing = trackedTouch {
            if isInBezelEdge(existing, in: view),
               isNearlyStationary(existing, in: view),
               !nonEdgeIncoming.isEmpty {
                ignore(existing, for: event)
                for touch in edgeIncoming {
                    ignore(touch, for: event)
                }
                if nonEdgeIncoming.count == 1, let primary = nonEdgeIncoming.first {
                    recordPrimaryTouch(primary, in: view)
                } else {
                    clearTrackedTouch()
                }
                super.touchesBegan(Set(nonEdgeIncoming), with: event)
                return
            }

            if !isInBezelEdge(existing, in: view), nonEdgeIncoming.isEmpty {
                for touch in edgeIncoming {
                    ignore(touch, for: event)
                }
                return
            }
        }

        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, let view, touches.contains(trackedTouch) {
            lastTrackedLocationInView = trackedTouch.location(in: view)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, let view, touches.contains(trackedTouch) {
            lastTrackedLocationInView = trackedTouch.location(in: view)
        }
        super.touchesEnded(touches, with: event)
        if let trackedTouch, touches.contains(trackedTouch), state == .possible || state == .failed {
            clearTrackedTouch()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, let view, touches.contains(trackedTouch) {
            lastTrackedLocationInView = trackedTouch.location(in: view)
        }
        super.touchesCancelled(touches, with: event)
        if let trackedTouch, touches.contains(trackedTouch), state == .possible || state == .failed {
            clearTrackedTouch()
        }
    }

    override func reset() {
        super.reset()
        clearTrackedTouch()
    }

    private func recordPrimaryTouch(_ touch: UITouch, in view: UIView) {
        trackedTouch = touch
        let pointInView = touch.location(in: view)
        touchOriginInView = pointInView
        lastTrackedLocationInView = pointInView
        if let window = view.window {
            touchOriginInWindow = touch.location(in: window)
        } else {
            touchOriginInWindow = nil
        }
    }

    private func clearTrackedTouch() {
        trackedTouch = nil
        touchOriginInView = nil
        touchOriginInWindow = nil
        lastTrackedLocationInView = nil
    }

    private func isInBezelEdge(_ touch: UITouch, in view: UIView) -> Bool {
        guard let window = view.window else { return false }
        return Self.isBezelEdge(
            pointInWindow: touch.location(in: window),
            windowBounds: window.bounds,
            sideWidth: bezelSideWidth,
            verticalHeight: bezelVerticalHeight
        )
    }

    private func isNearlyStationary(_ touch: UITouch, in view: UIView) -> Bool {
        guard let origin = touchOriginInView else { return true }
        let current = touch.location(in: view)
        return hypot(current.x - origin.x, current.y - origin.y) < 10
    }
}

struct PlaybackGestureSurface: UIViewRepresentable {
    var status: String
    /// 是否启用双击识别；关闭时 `doubleTap.isEnabled = false`，单击可零延迟立即响应。
    var doubleTapEnabled: Bool = true
    /// 是否启用长按识别
    var longPressEnabled: Bool = true
    /// 当前播放状态是否允许触发长按倍速（暂停且未锁定倍速时不拦截拖动）
    var canBeginLongPress: Bool = true
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
    var onPan: (PlaybackPanEvent) -> Void
    /// 双指捏合回调：(state, scale, velocity)
    var onPinch: ((UIGestureRecognizer.State, CGFloat, CGFloat) -> Void)? = nil

    /// 离屏幕上下边缘这么近起手的拖动，多半是系统手势（横屏时右上角下拉控制中心、底部上滑回桌面）
    static let systemEdgeZone: CGFloat = 44
    /// 离屏幕左右边缘这么近起手的横滑，多半是边缘手势或单手握持误触
    static let sideEdgeZone: CGFloat = 24
    /// 双指捏合忽略左右极窄边框内的掌心搭边误触，避免把单指滑动劫持成捏合
    static let pinchBezelIgnoreZone: CGFloat = 16

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = pinchEnabled
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "playback.surface"
        view.accessibilityLabel = "播放画面"

        let pan = PlaybackPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.onTouchDown = { PlayerHaptics.prepareForSeek() }
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

        context.coordinator.panRecognizer = pan
        context.coordinator.doubleTapRecognizer = doubleTap
        context.coordinator.longPressRecognizer = longPress
        context.coordinator.pinchRecognizer = pinch

        [pan, longPress, pinch, doubleTap, tap].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        if view.accessibilityValue != status {
            view.accessibilityValue = status
        }
        if view.isMultipleTouchEnabled != pinchEnabled {
            view.isMultipleTouchEnabled = pinchEnabled
        }
        if let doubleTap = context.coordinator.doubleTapRecognizer, doubleTap.isEnabled != doubleTapEnabled {
            doubleTap.isEnabled = doubleTapEnabled
        }
        if let longPress = context.coordinator.longPressRecognizer {
            if longPress.isEnabled != longPressEnabled {
                longPress.isEnabled = longPressEnabled
            }
            if abs(longPress.minimumPressDuration - longPressDuration) > 0.001 {
                longPress.minimumPressDuration = longPressDuration
            }
        }
        if let pinch = context.coordinator.pinchRecognizer, pinch.isEnabled != pinchEnabled {
            pinch.isEnabled = pinchEnabled
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.parent.onBoost(false)
        view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlaybackGestureSurface
        weak var panRecognizer: PlaybackPanGestureRecognizer?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        weak var longPressRecognizer: UILongPressGestureRecognizer?
        weak var pinchRecognizer: UIPinchGestureRecognizer?

        private var boostActive = false
        private var panOrigin = CGPoint.zero
        private var panStartsAtSystemEdge = false
        private var panStartsAtSideEdge = false
        private var longPressOrigin = CGPoint.zero

        init(_ parent: PlaybackGestureSurface) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === longPressRecognizer {
                guard parent.canBeginLongPress else { return false }
                if let panState = panRecognizer?.state, panState == .began || panState == .changed {
                    return false
                }
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === pinchRecognizer,
               let view = gestureRecognizer.view,
               let window = view.window,
               window.bounds.width >= 300 {
                let point = touch.location(in: window)
                let margin = PlaybackGestureSurface.pinchBezelIgnoreZone
                if point.x < margin || point.x > window.bounds.width - margin {
                    return false
                }
            }
            return true
        }

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
            let playbackPan = recognizer as? PlaybackPanGestureRecognizer
            let translation = playbackPan?.totalTranslation(in: view) ?? recognizer.translation(in: view)
            if recognizer.state == .began {
                if let exactOrigin = playbackPan?.touchOriginInView {
                    panOrigin = exactOrigin
                } else {
                    let location = recognizer.location(in: view)
                    panOrigin = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                }
                if boostActive {
                    parent.onBoost(false)
                    boostActive = false
                }
                // 按整块屏幕算起手点离上下 / 左右边缘多远（播放画面不一定占满屏幕）
                if let window = view.window {
                    let start = playbackPan?.touchOriginInWindow ?? view.convert(panOrigin, to: window)
                    let verticalZone = PlaybackGestureSurface.systemEdgeZone
                    let sideZone = PlaybackGestureSurface.sideEdgeZone
                    panStartsAtSystemEdge = start.y < verticalZone || start.y > window.bounds.height - verticalZone
                    panStartsAtSideEdge = start.x < sideZone || start.x > window.bounds.width - sideZone
                } else {
                    panStartsAtSystemEdge = false
                    panStartsAtSideEdge = false
                }
            } else if recognizer.state == .changed, boostActive {
                parent.onBoost(false)
                boostActive = false
            }
            let event = PlaybackPanEvent(
                state: recognizer.state,
                origin: panOrigin,
                translation: translation,
                size: view.bounds.size,
                startsAtSystemEdge: panStartsAtSystemEdge,
                startsAtSideEdge: panStartsAtSideEdge
            )
            parent.onPan(event)
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                panStartsAtSystemEdge = false
                panStartsAtSideEdge = false
            }
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
