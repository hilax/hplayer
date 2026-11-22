import Combine
import UIKit

/// 应用图标选择的唯一状态源。
///
/// 系统完成切换后，保存已确认的选择。系统回读只用于首次迁移和核实错误，
/// 不在页面出现 / 回到前台时覆盖用户选择；固定的等待时间不能保证系统缓存已更新。
///
/// 提示交互分工：
/// - 优先通过 `_setAlternateIconName:completionHandler:` 静默切换图标，避免弹出体积庞大且
///   必须手动关闭的 iOS 原生模态弹窗；切换成功后仅设置轻量 `appliedFeedback`，由设置页顶部
///   悬浮小胶囊短时确认并自动消失。
/// - 若静默接口不可用并回退到公开 `setAlternateIconName`（系统已弹出原生框），则不再叠加应用内成功提示，
///   避免重复弹窗。
/// - 切换失败或设备不支持时，统一通过全局 `HUD.show(...)` 反馈，并在下次操作前自动清理。
@MainActor
final class AppIconStore: ObservableObject {
    struct AppliedFeedback: Equatable {
        let id: UInt64
        let icon: HomeScreenIcon

        var message: String {
            icon == .prism ? "已恢复默认图标" : "已更换为「\(icon.title)」"
        }
    }

    /// 页面重建或多个窗口共用同一笔切换，避免请求尚未完成时出现第二份旧状态。
    static let shared = AppIconStore()

    nonisolated static let choiceKey = "hplayer.home_icon_choice"
    nonisolated static let simulatedKey = "hplayer.simulated_alternate_icon"
    nonisolated static let simulatedChoiceKey = "hplayer.home_icon_choice.simulated"

    private static let silentSelector = NSSelectorFromString("_setAlternateIconName:completionHandler:")

    @Published private(set) var selected: HomeScreenIcon
    @Published private(set) var isChanging = false
    @Published private(set) var appliedFeedback: AppliedFeedback?

    private let systemName: @MainActor () -> String?
    private let applyAction: @MainActor (String?, @escaping (Error?, Bool) -> Void) -> Void
    private let defaults: UserDefaults
    private let storageKey: String
    private let supportsIcons: @MainActor () -> Bool
    private let showHUD: @MainActor (String, HUDTone) -> Void
    private let dismissHUD: @MainActor () -> Void
    private let feedbackDuration: TimeInterval
    private var feedbackTask: Task<Void, Never>?
    private var activeRequestID: UInt64?
    private var nextRequestID: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        systemName: (@MainActor () -> String?)? = nil,
        apply: (@MainActor (String?, @escaping (Error?) -> Void) -> Void)? = nil,
        suppressesSystemAlert: Bool = true,
        feedbackDuration: TimeInterval = 2.4,
        supportsAlternateIcons: (@MainActor () -> Bool)? = nil,
        showHUD: (@MainActor (String, HUDTone) -> Void)? = nil,
        dismissHUD: (@MainActor () -> Void)? = nil
    ) {
        self.defaults = defaults
        self.feedbackDuration = feedbackDuration
        let simulated = Self.isSimulatedTest
        self.storageKey = simulated ? Self.simulatedChoiceKey : Self.choiceKey
        // 只影响模拟器 UI 测试，真实偏好与模拟的系统值各自保存。
        if simulated, ProcessInfo.processInfo.environment["HPLAYER_ICON_TEST_RESET"] == "1" {
            defaults.removeObject(forKey: Self.simulatedChoiceKey)
            defaults.removeObject(forKey: Self.simulatedKey)
        }
        self.systemName = systemName ?? {
            if simulated {
                if ProcessInfo.processInfo.environment["HPLAYER_ICON_STALE_SYSTEM"] == "1" { return nil }
                return defaults.string(forKey: Self.simulatedKey)
            }
            return UIApplication.shared.alternateIconName
        }
        self.supportsIcons = supportsAlternateIcons ?? {
            simulated || UIApplication.shared.supportsAlternateIcons
        }
        if let apply {
            self.applyAction = { name, completion in
                apply(name) { error in
                    completion(error, suppressesSystemAlert)
                }
            }
        } else {
            self.applyAction = { name, completion in
                if simulated {
                    // 截图 / UI 测试不触碰 SpringBoard，避免模拟器 POSIX 35 与系统弹窗干扰。
                    defaults.set(name, forKey: Self.simulatedKey)
                    DispatchQueue.main.async { completion(nil, true) }
                    return
                }
                Self.applySystemIcon(name, completion: completion)
            }
        }
        self.showHUD = showHUD ?? { text, tone in
            HUD.show(text, tone)
        }
        self.dismissHUD = dismissHUD ?? {
            HUD.dismiss()
        }
        let stored = defaults.string(forKey: storageKey)
        // 兼容之前保存的 AppIconOcean 等系统名称；新记录统一保存稳定的样式 ID。
        // 默认样式也明确保存 prism，不能用 nil 同时表达「默认」和「没有记录」。
        let initial = stored.flatMap { value in
            HomeScreenIcon(rawValue: value)
                ?? HomeScreenIcon.allCases.first { $0.matchesCurrentName(value) }
        }
            ?? Self.icon(for: self.systemName())
        self.selected = initial
        defaults.set(initial.rawValue, forKey: storageKey)
    }

    nonisolated static var isSimulatedTest: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["HPLAYER_HOME_TEST"] == "1"
        #else
        return false
        #endif
    }

    nonisolated static func icon(for name: String?) -> HomeScreenIcon {
        HomeScreenIcon.allCases.first { $0.matchesCurrentName(name) } ?? .prism
    }

    var supportsAlternateIcons: Bool { supportsIcons() }

    /// 点按样式：勾选立即跟随，不等系统回调。
    func select(_ icon: HomeScreenIcon) {
        guard !isChanging else { return }
        guard supportsAlternateIcons else {
            showHUD("当前设备暂不支持更换应用图标", .warning)
            return
        }
        if icon == selected {
            // 系统仍停在旧注册名（AppIconPrism、AppIconCoral）时重新应用当前名称：
            // 默认图标归一化为 nil，珊瑚橙迁移到不受旧缓存影响的新名。
            if icon.isLegacyName(systemName()) {
                commit(icon, previous: selected)
            } else {
                Haptics.tap()
            }
            return
        }
        commit(icon, previous: selected)
    }

    func dismissFeedback() {
        feedbackTask?.cancel()
        feedbackTask = nil
        appliedFeedback = nil
    }

    private func commit(_ icon: HomeScreenIcon, previous: HomeScreenIcon) {
        nextRequestID &+= 1
        let requestID = nextRequestID
        activeRequestID = requestID
        isChanging = true
        dismissFeedback()
        dismissHUD()
        selected = icon
        Haptics.select()
        applyAction(icon.alternateName) { [weak self] error, usedSilentAPI in
            Task { @MainActor [weak self] in
                guard let self, self.activeRequestID == requestID else { return }
                self.activeRequestID = nil
                self.isChanging = false
                if let error = error as NSError? {
                    // 只有系统回读也确认目标图标时，才接受 POSIX 35 的已生效结果。
                    // 不能把所有 EAGAIN 都当成成功，否则会保存未实际应用的选择。
                    let appliedDespiteError = error.domain == NSPOSIXErrorDomain && error.code == 35
                        && icon.matchesCurrentName(self.systemName())
                    if !appliedDespiteError {
                        self.selected = previous
                        self.appliedFeedback = nil
                        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        let message = detail.isEmpty ? "更换失败，已保留原图标" : "更换失败：\(detail)"
                        self.showHUD(message, .error)
                        return
                    }
                }
                self.defaults.set(icon.rawValue, forKey: self.storageKey)
                self.dismissHUD()
                if usedSilentAPI {
                    self.presentFeedback(id: requestID, icon: icon)
                } else {
                    self.appliedFeedback = nil
                }
            }
        }
    }

    private func presentFeedback(id: UInt64, icon: HomeScreenIcon) {
        feedbackTask?.cancel()
        Haptics.success()
        let feedback = AppliedFeedback(id: id, icon: icon)
        appliedFeedback = feedback
        UIAccessibility.post(notification: .announcement, argument: feedback.message)
        let delay = max(0.05, feedbackDuration)
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.appliedFeedback?.id == feedback.id else { return }
            self.appliedFeedback = nil
        }
    }

    private static func applySystemIcon(
        _ name: String?,
        completion: @escaping (Error?, Bool) -> Void
    ) {
        let app = UIApplication.shared
        guard app.responds(to: silentSelector) else {
            app.setAlternateIconName(name) { error in
                completion(error, false)
            }
            return
        }

        typealias SilentIMP = @convention(c) (
            AnyObject,
            Selector,
            NSString?,
            (@convention(block) (NSError?) -> Void)?
        ) -> Void

        let imp = app.method(for: silentSelector)
        let fn = unsafeBitCast(imp, to: SilentIMP.self)
        let nsName = name as NSString?
        let block: @convention(block) (NSError?) -> Void = { error in
            completion(error, true)
        }
        withExtendedLifetime((nsName, block)) {
            fn(app, silentSelector, nsName, block)
        }
    }
}
