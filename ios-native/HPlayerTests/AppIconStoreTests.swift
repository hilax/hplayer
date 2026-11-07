import XCTest
@testable import HPlayer

@MainActor
final class AppIconStoreTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    private func makeStore(
        system: @escaping () -> String? = { nil },
        clock: Clock = Clock(),
        apply: ((String?, @escaping (Error?) -> Void) -> Void)? = nil,
        saved: ((String?) -> Void)? = nil
    ) -> AppIconStore {
        // 用例之间不共享真实偏好，避免上一个用例写入的选择影响下一个用例的初始态。
        UserDefaults.standard.removeObject(forKey: AppIconStore.choiceKey)
        return AppIconStore(systemName: system, apply: apply, persist: saved, now: { clock.date })
    }

    /// 回调经 Task @MainActor  hop 回主线程，断言前让主 runloop 转一圈。
    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testSelectionMovesImmediatelyWithoutWaitingForSystem() {
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        let store = makeStore(apply: { name, done in
            requested.append(name)
            completion = done
        })
        XCTAssertEqual(store.selected, .prism)
        store.select(.ocean)
        XCTAssertEqual(store.selected, .ocean, "勾选必须在点按当帧跟随，不等系统回调")
        XCTAssertTrue(store.isChanging)
        XCTAssertEqual(requested, ["AppIconOcean"])
        completion?(nil)
        settle()
        XCTAssertFalse(store.isChanging)
        XCTAssertEqual(store.notice, .success(.ocean, previous: .prism))
    }

    func testFailureRollsBackToPreviousChoice() {
        var completion: ((Error?) -> Void)?
        var saved: [String?] = []
        let store = makeStore(apply: { _, done in completion = done }, saved: { saved.append($0) })
        store.select(.mint)
        completion?(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "拒绝"]))
        settle()
        XCTAssertEqual(store.selected, .prism, "失败必须回滚勾选，不能留下桌面与页内不一致")
        XCTAssertEqual(saved.last ?? nil, nil)
        XCTAssertEqual(store.notice, .failure("拒绝"))
    }

    func testPosix35IsTreatedAsApplied() {
        var completion: ((Error?) -> Void)?
        let store = makeStore(apply: { _, done in completion = done })
        store.select(.iris)
        completion?(NSError(domain: NSPOSIXErrorDomain, code: 35))
        settle()
        XCTAssertEqual(store.selected, .iris)
        XCTAssertEqual(store.notice, .success(.iris, previous: .prism))
    }

    func testStaleSystemReadCannotClobberFreshSelection() {
        let clock = Clock()
        var system: String? = nil
        var completion: ((Error?) -> Void)?
        let store = makeStore(system: { system }, clock: clock, apply: { _, done in completion = done })
        store.select(.coral)
        completion?(nil)
        settle()
        // 系统确认弹窗关闭触发回前台校准，但 SpringBoard 仍返回旧值。
        store.refreshFromSystem()
        XCTAssertEqual(store.selected, .coral, "settle 期内的旧系统值不得覆盖刚选中的样式")
        clock.advance(AppIconStore.settleInterval + 1)
        system = "AppIconCoral"
        store.refreshFromSystem()
        XCTAssertEqual(store.selected, .coral, "settle 后系统与选择一致时不做无谓覆盖")
        system = "AppIconMint"
        store.refreshFromSystem()
        XCTAssertEqual(store.selected, .mint, "settle 之后系统真实变化仍要校准")
    }

    func testUndoRestoresPreviousIcon() {
        var requested: [String?] = []
        let store = makeStore(apply: { name, done in
            requested.append(name)
            done(nil)
        })
        store.select(.ocean)
        settle()
        XCTAssertEqual(store.notice, .success(.ocean, previous: .prism))
        store.undo()
        settle()
        XCTAssertEqual(store.selected, .prism)
        XCTAssertEqual(requested, ["AppIconOcean", nil])
    }

    func testSelectingPrismNormalizesLegacyAlternate() {
        var requested: [String?] = []
        let store = makeStore(system: { "AppIconPrism" }, apply: { name, done in
            requested.append(name)
            done(nil)
        })
        XCTAssertEqual(store.selected, .prism)
        store.select(.prism)
        XCTAssertEqual(requested, [nil], "遗留 AppIconPrism 字符串要归一化为 nil")
    }

    func testLaunchMigratesSystemValueIntoStoredChoice() {
        let key = AppIconStore.choiceKey
        let original = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        var saved: [String?] = []
        let store = makeStore(system: { "AppIconOcean" }, saved: { saved.append($0) })
        XCTAssertEqual(store.selected, .ocean, "旧版本没写过偏好时以系统当前值迁移")
        XCTAssertEqual(saved, ["AppIconOcean"])
    }
}