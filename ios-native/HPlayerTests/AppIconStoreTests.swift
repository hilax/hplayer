import Combine
import XCTest
@testable import HPlayer

@MainActor
final class AppIconStoreTests: XCTestCase {
    private struct RecordedHUD: Equatable {
        let text: String
        let tone: HUDTone
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppIconStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeStore(
        defaults: UserDefaults? = nil,
        system: @escaping () -> String? = { nil },
        supportsIcons: Bool = true,
        apply: @escaping (String?, @escaping (Error?) -> Void) -> Void = { _, done in done(nil) },
        showHUD: (@MainActor (String, HUDTone) -> Void)? = nil,
        dismissHUD: (@MainActor () -> Void)? = nil
    ) -> AppIconStore {
        AppIconStore(
            defaults: defaults ?? makeDefaults(),
            systemName: system,
            apply: apply,
            supportsAlternateIcons: { supportsIcons },
            showHUD: showHUD ?? { _, _ in },
            dismissHUD: dismissHUD ?? {}
        )
    }

    private func complete(
        _ callback: ((Error?) -> Void)?,
        error: Error? = nil,
        store: AppIconStore
    ) async {
        let finished = expectation(description: "Icon request completed on the main actor")
        let subscription = store.$isChanging.filter { !$0 }.first().sink { _ in finished.fulfill() }
        callback?(error)
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testSelectionMovesImmediatelyPersistsAfterSuccessWithoutDuplicateHUD() async {
        let defaults = makeDefaults()
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        var huds: [RecordedHUD] = []
        var dismissCount = 0
        let store = makeStore(
            defaults: defaults,
            apply: { name, done in
                requested.append(name)
                completion = done
            },
            showHUD: { text, tone in huds.append(RecordedHUD(text: text, tone: tone)) },
            dismissHUD: { dismissCount += 1 }
        )
        store.select(.ocean)
        XCTAssertEqual(store.selected, .ocean)
        XCTAssertTrue(store.isChanging)
        XCTAssertEqual(requested, ["AppIconOcean"])
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism",
                       "An in-flight request must not become the saved choice")

        await complete(completion, store: store)
        XCTAssertFalse(store.isChanging)
        XCTAssertTrue(huds.isEmpty, "System alert already confirms success; app must not stack a duplicate success HUD")
        XCTAssertGreaterThanOrEqual(dismissCount, 2, "Start and completion should clear any stale HUD")
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "ocean")
    }

    func testFailureKeepsPreviousConfirmedChoiceAndReportsUnifiedErrorHUD() async {
        let defaults = makeDefaults()
        defaults.set("ocean", forKey: AppIconStore.choiceKey)
        var completion: ((Error?) -> Void)?
        var huds: [RecordedHUD] = []
        let store = makeStore(
            defaults: defaults,
            apply: { _, done in completion = done },
            showHUD: { text, tone in huds.append(RecordedHUD(text: text, tone: tone)) }
        )
        store.select(.mint)
        await complete(completion, error: NSError(domain: "test", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: "拒绝"]), store: store)
        XCTAssertEqual(store.selected, .ocean)
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "ocean")
        XCTAssertEqual(huds, [RecordedHUD(text: "更换失败：拒绝", tone: .error)])
        XCTAssertEqual(makeStore(defaults: defaults).selected, .ocean)
    }

    func testDuplicateSystemCallbackDoesNotEmitDuplicateHUD() async {
        var completion: ((Error?) -> Void)?
        var huds: [RecordedHUD] = []
        let store = makeStore(
            apply: { _, done in completion = done },
            showHUD: { text, tone in huds.append(RecordedHUD(text: text, tone: tone)) }
        )
        store.select(.mint)
        let failure = NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "忙"])
        await complete(completion, error: failure, store: store)
        // 模拟异常重复回调
        completion?(failure)
        await Task.yield()
        XCTAssertEqual(huds.count, 1, "A single request must never produce duplicate HUD notifications")
    }

    func testDefaultHUDIntegrationUsesSharedHUDCenterAndClearsOnNextSuccess() async {
        HUDCenter.shared.dismiss()
        defer { HUDCenter.shared.dismiss() }

        var completion: ((Error?) -> Void)?
        let store = AppIconStore(
            defaults: makeDefaults(),
            systemName: { nil },
            apply: { _, done in completion = done },
            supportsAlternateIcons: { true }
        )

        store.select(.coral)
        await complete(completion, error: NSError(domain: "test", code: 3,
                                                 userInfo: [NSLocalizedDescriptionKey: "系统繁忙"]), store: store)
        XCTAssertEqual(HUDCenter.shared.current?.tone, .error)
        XCTAssertEqual(HUDCenter.shared.current?.text, "更换失败：系统繁忙")

        store.select(.coral)
        await complete(completion, store: store)
        XCTAssertNil(HUDCenter.shared.current, "Successful icon switch should clear stale error HUD without stacking a new toast")
    }

    func testPosix35WithoutMatchingSystemIconIsAFailure() async {
        let defaults = makeDefaults()
        var completion: ((Error?) -> Void)?
        var huds: [RecordedHUD] = []
        let store = makeStore(
            defaults: defaults,
            apply: { _, done in completion = done },
            showHUD: { text, tone in huds.append(RecordedHUD(text: text, tone: tone)) }
        )
        store.select(.iris)
        await complete(completion, error: NSError(domain: NSPOSIXErrorDomain, code: 35), store: store)
        XCTAssertEqual(store.selected, .prism)
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism")
        XCTAssertEqual(huds.count, 1)
        XCTAssertEqual(huds.first?.tone, .error, "An unconfirmed error must report failure via unified HUD")
    }

    func testPosix35CanSucceedWhenSystemConfirmsRequestedIcon() async {
        var system: String? = nil
        var completion: ((Error?) -> Void)?
        var huds: [RecordedHUD] = []
        let store = makeStore(
            system: { system },
            apply: { _, done in completion = done },
            showHUD: { text, tone in huds.append(RecordedHUD(text: text, tone: tone)) }
        )
        store.select(.iris)
        system = "AppIconIris"
        await complete(completion, error: NSError(domain: NSPOSIXErrorDomain, code: 35), store: store)
        XCTAssertEqual(store.selected, .iris)
        XCTAssertTrue(huds.isEmpty)
    }

    func testConfirmedSelectionSurvivesStaleSystemValuesAndPageRecreation() async {
        let defaults = makeDefaults()
        var system: String? = nil
        var completion: ((Error?) -> Void)?
        let store = makeStore(defaults: defaults, system: { system }, apply: { _, done in completion = done })
        store.select(.coral)
        await complete(completion, store: store)

        // The old two-second guard eventually accepted these stale reads as a new selection.
        // Reopening settings and relaunching must use the last confirmed choice at any time.
        for staleName in [nil, "AppIconPrism", "AppIconOcean", "UnknownFutureIcon"] as [String?] {
            system = staleName
            XCTAssertEqual(store.selected, .coral)
            let reopened = makeStore(defaults: defaults, system: { system })
            XCTAssertEqual(reopened.selected, .coral)
            XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "coral")
        }
    }

    func testRestoredDefaultIsSavedExplicitlyEvenWhenSystemStillReportsAnAlternate() async {
        let defaults = makeDefaults()
        defaults.set("ocean", forKey: AppIconStore.choiceKey)
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        let store = makeStore(defaults: defaults, system: { "AppIconOcean" }, apply: { name, done in
            requested.append(name)
            completion = done
        })
        store.select(.prism)
        await complete(completion, store: store)
        XCTAssertEqual(requested, [nil])
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism")
        XCTAssertEqual(makeStore(defaults: defaults, system: { "AppIconOcean" }).selected, .prism)
    }

    func testSwitchingBackToPreviousIconPersistsCleanly() async {
        let defaults = makeDefaults()
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        let store = makeStore(defaults: defaults, apply: { name, done in
            requested.append(name)
            completion = done
        })
        store.select(.ocean)
        await complete(completion, store: store)
        store.select(.prism)
        await complete(completion, store: store)
        XCTAssertEqual(store.selected, .prism)
        XCTAssertEqual(requested, ["AppIconOcean", nil])
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism")
    }

    func testRequestsAreSerializedWhileChanging() async {
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        let store = makeStore(apply: { name, done in
            requested.append(name)
            completion = done
        })
        store.select(.ocean)
        store.select(.mint)
        store.select(.prism)
        XCTAssertEqual(requested, ["AppIconOcean"])
        XCTAssertEqual(store.selected, .ocean)
        await complete(completion, store: store)
    }

    func testUnsupportedDeviceShowsWarningHUDAndDoesNotRequestOrPersistAChange() {
        let defaults = makeDefaults()
        var huds: [RecordedHUD] = []
        let store = makeStore(
            defaults: defaults,
            supportsIcons: false,
            apply: { _, _ in
                XCTFail("Unsupported devices must not request an alternate icon")
            },
            showHUD: { text, tone in huds.append(RecordedHUD(text: text, tone: tone)) }
        )
        store.select(.mint)
        XCTAssertEqual(store.selected, .prism)
        XCTAssertFalse(store.isChanging)
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism")
        XCTAssertEqual(huds, [RecordedHUD(text: "当前设备暂不支持更换应用图标", tone: .warning)])
    }

    func testSelectingCurrentAlternateDoesNotSendAnotherRequestOrHUD() {
        var huds: [RecordedHUD] = []
        let store = makeStore(
            system: { "AppIconOcean" },
            apply: { _, _ in
                XCTFail("Selecting the active style must not send a duplicate request")
            },
            showHUD: { text, tone in huds.append(RecordedHUD(text: text, tone: tone)) }
        )
        store.select(.ocean)
        XCTAssertFalse(store.isChanging)
        XCTAssertTrue(huds.isEmpty)
    }

    func testSelectingPrismNormalizesLegacyAlternate() async {
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        let store = makeStore(system: { "AppIconPrism" }, apply: { name, done in
            requested.append(name)
            completion = done
        })
        XCTAssertEqual(store.selected, .prism)
        store.select(.prism)
        XCTAssertEqual(requested, [nil])
        await complete(completion, store: store)
    }

    func testLaunchMigratesLegacySavedSystemNamesToStableChoiceIDs() {
        for icon in HomeScreenIcon.allCases {
            let defaults = makeDefaults()
            defaults.set(icon.alternateName ?? "AppIconPrism", forKey: AppIconStore.choiceKey)
            let store = makeStore(defaults: defaults)
            XCTAssertEqual(store.selected, icon)
            XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), icon.rawValue)
        }
    }

    func testFirstLaunchMigratesSystemIconAndInvalidSavedChoiceFallsBackToSystem() {
        for stored in [nil, "UnknownFutureIcon"] as [String?] {
            let defaults = makeDefaults()
            defaults.set(stored, forKey: AppIconStore.choiceKey)
            let store = makeStore(defaults: defaults, system: { "AppIconOcean" })
            XCTAssertEqual(store.selected, .ocean)
            XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "ocean")
        }
    }
}
