import Combine
import UIKit

/// 应用图标选择的唯一状态源。
///
/// 旧实现把 `UIApplication.shared.alternateIconName` 当作即时真相：切换回调是异步的，
/// 而系统确认弹窗关闭触发 scenePhase 回 active 时，`alternateIconName` 在部分系统上
/// 仍返回旧值，会把刚刚选中的样式覆盖回去——表现为桌面图标已换、页内勾选不动。
/// 这里改为：点按即乐观更新并持久化用户选择；系统值只做「延迟校准」，切换后 2 秒内
/// 不允许覆盖页内状态；失败时回滚到切换前的选择。
@MainActor
final class AppIconStore: ObservableObject {
    enum Notice: Equatable {
        case success(HomeScreenIcon, previous: HomeScreenIcon)
        case failure(String)
    }

    /// 系统确认弹窗消失后的静默接口；不存在时回退公开接口（会弹系统提示）。
    private static let silentSelector = NSSelectorFromString("_setAlternateIconName:completionHandler:")

    nonisolated static let choiceKey = "hplayer.home_icon_choice"
    nonisolated static let simulatedKey = "hplayer.simulated_alternate_icon"
    /// 切换后这段时间内忽略系统回读，避免 SpringBoard 同步延迟把选择覆盖回旧值。
    nonisolated static let settleInterval: TimeInterval = 2.0

    @Published private(set) var selected: HomeScreenIcon
    @Published private(set) var isChanging = false
    @Published private(set) var notice: Notice?

    private let systemName: @MainActor () -> String?
    private let apply: @MainActor (String?, @escaping (Error?) -> Void) -> Void
    private let persist: (String?) -> Void
    private let now: () -> Date
    private var lastChangeAt: Date?
    private var noticeToken = 0

    init(
        systemName: (@MainActor () -> String?)? = nil,
        apply: (@MainActor (String?, @escaping (Error?) -> Void) -> Void)? = nil,
        persist: ((String?) -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.systemName = systemName ?? {
            Self.isSimulatedTest
                ? UserDefaults.standard.string(forKey: Self.simulatedKey)
                : UIApplication.shared.alternateIconName
        }
        self.now = now
        let simulated = Self.isSimulatedTest
        self.persist = persist ?? { value in
            UserDefaults.standard.set(value, forKey: simulated ? Self.simulatedKey : Self.choiceKey)
        }
        self.apply = apply ?? { name, completion in
            if simulated {
                // 截图 / UI 测试不触碰 SpringBoard，避免模拟器 POSIX 35 与系统弹窗干扰。
                UserDefaults.standard.set(name, forKey: Self.simulatedKey)
                DispatchQueue.main.async { completion(nil) }
                return
            }
            Self.requestSystemIcon(name, completion: completion)
        }
        let stored = UserDefaults.standard.string(forKey: simulated ? Self.simulatedKey : Self.choiceKey)
        let initial = stored.flatMap { name in HomeScreenIcon.allCases.first { $0.matchesCurrentName(name) } }
            ?? Self.icon(for: self.systemName())
        self.selected = initial
        // 旧版本没有写过偏好：把系统当前值迁移成本地选择，之后以本地选择为准。
        if stored == nil { self.persist(initial.alternateName) }
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

    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }

    /// 点按样式：勾选立即跟随，不等系统回调。
    func select(_ icon: HomeScreenIcon) {
        guard !isChanging, supportsAlternateIcons else { return }
        if icon == selected {
            // 默认图标但系统仍遗留旧 alternate 字符串（如 AppIconPrism）时归一化为 nil。
            if icon == .prism, systemName() != nil {
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
        guard case .success(_, let previous) = notice else { return }
        clearNotice()
        select(previous)
    }

    func clearNotice() {
        noticeToken += 1
        notice = nil
    }

    /// 页面出现 / 回到前台时校准：只采纳已经 settle 的系统值。
    func refreshFromSystem() {
        guard !isChanging else { return }
        if let lastChangeAt, now().timeIntervalSince(lastChangeAt) < Self.settleInterval { return }
        let actual = Self.icon(for: systemName())
        guard actual != selected else { return }
        selected = actual
        persist(actual.alternateName)
    }

    private func commit(_ icon: HomeScreenIcon, previous: HomeScreenIcon) {
        isChanging = true
        lastChangeAt = now()
        clearNotice()
        selected = icon
        persist(icon.alternateName)
        Haptics.select()
        apply(icon.alternateName) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isChanging = false
                self.lastChangeAt = self.now()
                if let error = error as NSError? {
                    // iOS 26 模拟器 / 部分系统上 SpringBoard LSIconAlertManager 拿不到 Token
                    // 会报 POSIX 35 (EAGAIN)；图标实际已生效，按成功处理。
                    let benign = error.domain == NSPOSIXErrorDomain && error.code == 35
                    if !benign {
                        self.selected = previous
                        self.persist(previous.alternateName)
                        self.publish(.failure(error.localizedDescription))
                        Haptics.warning()
                        return
                    }
                }
                self.publish(.success(icon, previous: previous))
                Haptics.success()
            }
        }
    }

    private func publish(_ notice: Notice) {
        self.notice = notice
        noticeToken += 1
        let token = noticeToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard self.noticeToken == token else { return }
            self.notice = nil
        }
    }

    /// 优先走不弹系统确认框的静默接口；签名不存在时回退公开接口。
    private static func requestSystemIcon(_ name: String?, completion: @escaping (Error?) -> Void) {
        let app = UIApplication.shared
        if app.responds(to: silentSelector) {
            let block: @convention(block) (Error?) -> Void = { completion($0) }
            app.perform(silentSelector, with: name, with: block)
            return
        }
        app.setAlternateIconName(name, completionHandler: completion)
    }
}