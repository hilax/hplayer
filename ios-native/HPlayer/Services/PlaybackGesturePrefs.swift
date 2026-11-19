import Combine
import CoreGraphics
import Foundation

// MARK: - 播放手势枚举定义

/// 播放画面双击动作
enum PlaybackDoubleTapAction: String, CaseIterable, Identifiable {
    /// 左 1/3 快退、中间 1/3 播放/暂停、右 1/3 快进
    case splitSeekAndToggle
    /// 全屏双击统一播放/暂停
    case playPause
    /// 关闭双击，单击控制栏零延迟响应
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .splitSeekAndToggle: return "左退 / 中停 / 右进"
        case .playPause: return "播放 / 暂停"
        case .off: return "关闭（单击无延迟）"
        }
    }

    var shortTitle: String {
        switch self {
        case .splitSeekAndToggle: return "分区双击"
        case .playPause: return "双击暂停"
        case .off: return "无双击"
        }
    }
}

/// 分区双击的三个区域
enum PlaybackDoubleTapRegion: Equatable {
    case left
    case center
    case right
}

/// 分区双击单次跳转步长（秒）
enum PlaybackDoubleTapStep: Int, CaseIterable, Identifiable {
    case s5 = 5
    case s10 = 10
    case s15 = 15
    case s30 = 30

    var id: Int { rawValue }
    var seconds: Double { Double(rawValue) }
    var title: String { "\(rawValue) 秒" }
}

/// 长按临时倍速档位
enum PlaybackBoostRateOption: String, CaseIterable, Identifiable {
    case r15 = "1.5"
    case r20 = "2"
    case r25 = "2.5"
    case r30 = "3"
    case r40 = "4"

    var id: String { rawValue }

    var rate: Float {
        switch self {
        case .r15: return 1.5
        case .r20: return 2.0
        case .r25: return 2.5
        case .r30: return 3.0
        case .r40: return 4.0
        }
    }

    var title: String { "\(rawValue)×" }
}

/// 长按期间的附加滑动行为
enum PlaybackLongPressExtra: String, CaseIterable, Identifiable {
    /// 长按后直接滑动，平滑转为快进快退或调亮度音量
    case slideToSeek
    /// 长按中手指上滑锁住倍速，松手后继续保持倍速
    case swipeUpToLock
    /// 仅按住时加速，不响应伴随滑动
    case holdOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slideToSeek: return "滑动转进度拖动"
        case .swipeUpToLock: return "上滑锁定倍速"
        case .holdOnly: return "仅按住生效"
        }
    }
}

/// 左右滑动快进/快退的灵敏度
enum PlaybackSeekSensitivity: String, CaseIterable, Identifiable {
    case precise
    case standard
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .precise: return "精准（慢）"
        case .standard: return "标准"
        case .fast: return "快速"
        }
    }

    /// 滑满整屏宽度对应的跳转时长（秒）
    func seekRange(duration: Double) -> Double {
        let safeDuration = max(0, duration)
        switch self {
        case .precise:
            return min(240, max(60, safeDuration * 0.3))
        case .standard:
            return min(540, max(90, safeDuration * 0.6))
        case .fast:
            return min(900, max(150, safeDuration * 0.85))
        }
    }
}

/// 左/右半屏上下滑动映射动作
enum PlaybackVerticalAxisAction: String, CaseIterable, Identifiable {
    case brightness
    case volume
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightness: return "亮度"
        case .volume: return "音量"
        case .off: return "关闭"
        }
    }
}

/// 亮度 / 音量上下滑动灵敏度
enum PlaybackLevelSensitivity: String, CaseIterable, Identifiable {
    case low
    case standard
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "低"
        case .standard: return "标准"
        case .high: return "高"
        }
    }

    /// 滑满屏高的数值倍率
    var multiplier: Double {
        switch self {
        case .low: return 0.8
        case .standard: return 1.2
        case .high: return 1.65
        }
    }
}

/// 双指捏合画面手势动作
enum PlaybackPinchAction: String, CaseIterable, Identifiable {
    /// 外扩切换填充（去黑边），内捏回到适应画面
    case toggleFill
    /// 双指自由缩放（1.0× – 2.0×）
    case freeZoom
    /// 关闭双指捏合
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleFill: return "适应 / 填充切换"
        case .freeZoom: return "自由缩放"
        case .off: return "关闭"
        }
    }
}

// MARK: - 完整手势配置模型

struct PlaybackGestureSettings: Equatable {
    var doubleTapAction: PlaybackDoubleTapAction
    var doubleTapStep: PlaybackDoubleTapStep
    var longPressBoostEnabled: Bool
    var longPressBoostRate: PlaybackBoostRateOption
    var longPressExtra: PlaybackLongPressExtra
    var horizontalSeekEnabled: Bool
    var seekSensitivity: PlaybackSeekSensitivity
    var pullDownToCancelSeek: Bool
    var leftVerticalAction: PlaybackVerticalAxisAction
    var rightVerticalAction: PlaybackVerticalAxisAction
    var levelSensitivity: PlaybackLevelSensitivity
    var pinchAction: PlaybackPinchAction
    var disableVerticalInPortrait: Bool
    var lockDisablesAllGestures: Bool

    static let `default` = PlaybackGestureSettings(
        doubleTapAction: .splitSeekAndToggle,
        doubleTapStep: .s10,
        longPressBoostEnabled: true,
        longPressBoostRate: .r30,
        longPressExtra: .slideToSeek,
        horizontalSeekEnabled: true,
        seekSensitivity: .standard,
        pullDownToCancelSeek: true,
        leftVerticalAction: .brightness,
        rightVerticalAction: .volume,
        levelSensitivity: .standard,
        pinchAction: .toggleFill,
        disableVerticalInPortrait: false,
        lockDisablesAllGestures: false
    )

    var isDefault: Bool { self == .default }

    /// 是否至少有一侧开启了上下滑亮度/音量调节
    var hasAnyVerticalAction: Bool {
        leftVerticalAction != .off || rightVerticalAction != .off
    }

    /// 展示在「我的 › 播放」列表行尾的简短摘要
    var summaryText: String {
        if isDefault { return "默认" }
        var parts: [String] = [doubleTapAction.shortTitle]
        if longPressBoostEnabled {
            parts.append("长按 \(longPressBoostRate.title)")
        }
        return parts.joined(separator: " · ")
    }

    /// 计算双击落点所在的左 / 中 / 右三分区域
    func doubleTapRegion(at x: CGFloat, width: CGFloat) -> PlaybackDoubleTapRegion {
        guard width > 0 else { return .center }
        let ratio = x / width
        if ratio < 1.0 / 3.0 { return .left }
        if ratio > 2.0 / 3.0 { return .right }
        return .center
    }

    /// 根据起手横坐标与当前横竖屏状态，解析上下滑动应执行的动作
    func verticalAction(at x: CGFloat, width: CGFloat, isLandscape: Bool) -> PlaybackVerticalAxisAction {
        if !isLandscape && disableVerticalInPortrait { return .off }
        guard width > 0 else { return .off }
        return x < width / 2 ? leftVerticalAction : rightVerticalAction
    }

    /// 判断横滑快进过程中，手指下滑位移是否达到「取消本次跳转」阈值
    func shouldCancelSeek(translationY: CGFloat, surfaceHeight: CGFloat) -> Bool {
        guard pullDownToCancelSeek else { return false }
        let threshold = min(84, max(54, surfaceHeight * 0.22))
        return translationY >= threshold
    }
}

// MARK: - 持久化读写

enum PlaybackGesturePrefs {
    enum Key {
        static let doubleTapAction = "player.gesture.doubleTapAction"
        static let doubleTapStep = "player.gesture.doubleTapStep"
        static let longPressBoostEnabled = "player.gesture.longPressBoostEnabled"
        static let longPressBoostRate = "player.gesture.longPressBoostRate"
        static let longPressExtra = "player.gesture.longPressExtra"
        static let horizontalSeekEnabled = "player.gesture.horizontalSeekEnabled"
        static let seekSensitivity = "player.gesture.seekSensitivity"
        static let pullDownToCancelSeek = "player.gesture.pullDownToCancelSeek"
        static let leftVerticalAction = "player.gesture.leftVerticalAction"
        static let rightVerticalAction = "player.gesture.rightVerticalAction"
        static let levelSensitivity = "player.gesture.levelSensitivity"
        static let pinchAction = "player.gesture.pinchAction"
        static let disableVerticalInPortrait = "player.gesture.disableVerticalInPortrait"
        static let lockDisablesAllGestures = "player.gesture.lockDisablesAllGestures"
    }

    static func load(from defaults: UserDefaults = .standard) -> PlaybackGestureSettings {
        let base = PlaybackGestureSettings.default
        return PlaybackGestureSettings(
            doubleTapAction: defaults.string(forKey: Key.doubleTapAction)
                .flatMap(PlaybackDoubleTapAction.init(rawValue:)) ?? base.doubleTapAction,
            doubleTapStep: defaults.object(forKey: Key.doubleTapStep) != nil
                ? (PlaybackDoubleTapStep(rawValue: defaults.integer(forKey: Key.doubleTapStep)) ?? base.doubleTapStep)
                : base.doubleTapStep,
            longPressBoostEnabled: bool(forKey: Key.longPressBoostEnabled, in: defaults, default: base.longPressBoostEnabled),
            longPressBoostRate: defaults.string(forKey: Key.longPressBoostRate)
                .flatMap(PlaybackBoostRateOption.init(rawValue:)) ?? base.longPressBoostRate,
            longPressExtra: defaults.string(forKey: Key.longPressExtra)
                .flatMap(PlaybackLongPressExtra.init(rawValue:)) ?? base.longPressExtra,
            horizontalSeekEnabled: bool(forKey: Key.horizontalSeekEnabled, in: defaults, default: base.horizontalSeekEnabled),
            seekSensitivity: defaults.string(forKey: Key.seekSensitivity)
                .flatMap(PlaybackSeekSensitivity.init(rawValue:)) ?? base.seekSensitivity,
            pullDownToCancelSeek: bool(forKey: Key.pullDownToCancelSeek, in: defaults, default: base.pullDownToCancelSeek),
            leftVerticalAction: defaults.string(forKey: Key.leftVerticalAction)
                .flatMap(PlaybackVerticalAxisAction.init(rawValue:)) ?? base.leftVerticalAction,
            rightVerticalAction: defaults.string(forKey: Key.rightVerticalAction)
                .flatMap(PlaybackVerticalAxisAction.init(rawValue:)) ?? base.rightVerticalAction,
            levelSensitivity: defaults.string(forKey: Key.levelSensitivity)
                .flatMap(PlaybackLevelSensitivity.init(rawValue:)) ?? base.levelSensitivity,
            pinchAction: defaults.string(forKey: Key.pinchAction)
                .flatMap(PlaybackPinchAction.init(rawValue:)) ?? base.pinchAction,
            disableVerticalInPortrait: bool(forKey: Key.disableVerticalInPortrait, in: defaults, default: base.disableVerticalInPortrait),
            lockDisablesAllGestures: bool(forKey: Key.lockDisablesAllGestures, in: defaults, default: base.lockDisablesAllGestures)
        )
    }

    static func save(_ settings: PlaybackGestureSettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.doubleTapAction.rawValue, forKey: Key.doubleTapAction)
        defaults.set(settings.doubleTapStep.rawValue, forKey: Key.doubleTapStep)
        defaults.set(settings.longPressBoostEnabled, forKey: Key.longPressBoostEnabled)
        defaults.set(settings.longPressBoostRate.rawValue, forKey: Key.longPressBoostRate)
        defaults.set(settings.longPressExtra.rawValue, forKey: Key.longPressExtra)
        defaults.set(settings.horizontalSeekEnabled, forKey: Key.horizontalSeekEnabled)
        defaults.set(settings.seekSensitivity.rawValue, forKey: Key.seekSensitivity)
        defaults.set(settings.pullDownToCancelSeek, forKey: Key.pullDownToCancelSeek)
        defaults.set(settings.leftVerticalAction.rawValue, forKey: Key.leftVerticalAction)
        defaults.set(settings.rightVerticalAction.rawValue, forKey: Key.rightVerticalAction)
        defaults.set(settings.levelSensitivity.rawValue, forKey: Key.levelSensitivity)
        defaults.set(settings.pinchAction.rawValue, forKey: Key.pinchAction)
        defaults.set(settings.disableVerticalInPortrait, forKey: Key.disableVerticalInPortrait)
        defaults.set(settings.lockDisablesAllGestures, forKey: Key.lockDisablesAllGestures)
    }

    private static func bool(forKey key: String, in defaults: UserDefaults, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : fallback
    }
}

/// 播放手势设置的共享状态源：设置页修改后，正在打开或下次打开的播放器即时生效。
@MainActor
final class PlaybackGestureStore: ObservableObject {
    static let shared = PlaybackGestureStore()

    @Published var settings: PlaybackGestureSettings {
        didSet {
            guard settings != oldValue else { return }
            PlaybackGesturePrefs.save(settings, to: defaults)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = PlaybackGesturePrefs.load(from: defaults)
    }

    func resetToDefaults() {
        settings = .default
    }
}
