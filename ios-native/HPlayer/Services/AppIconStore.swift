import Combine
import UIKit

/// 应用图标选择的唯一状态源。
///
/// 系统完成切换后，保存已确认的选择。系统回读只用于首次迁移和核实错误，
/// 不在页面出现 / 回到前台时覆盖用户选择；固定的等待时间不能保证系统缓存已更新。
@MainActor
final class AppIconStore: ObservableObject {
    enum Notice: Equatable {
        case success(HomeScreenIcon, previous: HomeScreenIcon)
        case failure(String)
    }

    /// 页面重建或多个窗口共用同一笔切换，避免请求尚未完成时出现第二份旧状态。
    static let shared = AppIconStore()

    nonisolated static let choiceKey = "hplayer.home_icon_choice"
    nonisolated static let simulatedKey = "hplayer.simulated_alternate_icon"
    nonisolated static let simulatedChoiceKey = "hplayer.home_icon_choice.simulated"

    @Published private(set) var selected: HomeScreenIcon
    @Published private(set) var isChanging = false
    @Published private(set) var notice: Notice?

    private let systemName: @MainActor () -> String?
    private let apply: @MainActor (String?, @escaping (Error?) -> Void) -> Void
    private let defaults: UserDefaults
    private let storageKey: String
    private let supportsIcons: @MainActor () -> Bool
    private var noticeToken = 0

    init(
        defaults: UserDefaults = .standard,
        systemName: (@MainActor () -> String?)? = nil,
        apply: (@MainActor (String?, @escaping (Error?) -> Void) -> Void)? = nil,
        supportsAlternateIcons: (@MainActor () -> Bool)? = nil
    ) {
        self.defaults = defaults
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
        self.apply = apply ?? { name, completion in
            if simulated {
                // 截图 / UI 测试不触碰 SpringBoard，避免模拟器 POSIX 35 与系统弹窗干扰。
                defaults.set(name, forKey: Self.simulatedKey)
                DispatchQueue.main.async { completion(nil) }
                return
            }
            UIApplication.shared.setAlternateIconName(name, completionHandler: completion)
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
        guard !isChanging, supportsAlternateIcons else { return }
        if icon == selected {
            // 默认图标但系统仍遗留旧 alternate 字符串（如 AppIconPrism）时归一化为 nil。
            if icon == .prism, systemName() == "AppIconPrism" {
                commit(icon, previous: selected)
            } else {
                Haptics.tap()
            }
            return
        }
        commit(icon, previous: selected)
    }

    /// 撤销上一次成功切换。
    func undo() {
        guard !isChanging, case .success(_, let previous) = notice else { return }
        clearNotice()
        select(previous)
    }

    func clearNotice() {
        noticeToken += 1
        notice = nil
    }

    private func commit(_ icon: HomeScreenIcon, previous: HomeScreenIcon) {
        isChanging = true
        clearNotice()
        selected = icon
        Haptics.select()
        apply(icon.alternateName) { [self] error in
            Task { @MainActor in
                defer { self.isChanging = false }
                if let error = error as NSError? {
                    // 只有系统回读也确认目标图标时，才接受 POSIX 35 的已生效结果。
                    // 不能把所有 EAGAIN 都当成成功，否则会保存未实际应用的选择。
                    let appliedDespiteError = error.domain == NSPOSIXErrorDomain && error.code == 35
                        && icon.matchesCurrentName(self.systemName())
                    if !appliedDespiteError {
                        self.selected = previous
                        self.publish(.failure(error.localizedDescription))
                        Haptics.warning()
                        return
                    }
                }
                self.defaults.set(icon.rawValue, forKey: self.storageKey)
                self.publish(.success(icon, previous: previous))
                Haptics.success()
            }
        }
    }

    private func publish(_ notice: Notice) {
        self.notice = notice
        noticeToken += 1
        let token = noticeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }
}
