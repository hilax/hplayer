import Combine
import XCTest
@testable import HPlayer

@MainActor
final class AppIconStoreTests: XCTestCase {
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
        apply: @escaping (String?, @escaping (Error?) -> Void) -> Void = { _, done in done(nil) }
    ) -> AppIconStore {
        AppIconStore(
            defaults: defaults ?? makeDefaults(),
            systemName: system,
            apply: apply,
            supportsAlternateIcons: { supportsIcons }
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

    func testSelectionMovesImmediatelyButPersistsOnlyAfterSuccess() async {
        let defaults = makeDefaults()
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        let store = makeStore(defaults: defaults, apply: { name, done in
            requested.append(name)
            completion = done
        })
        store.select(.ocean)
        XCTAssertEqual(store.selected, .ocean)
        XCTAssertTrue(store.isChanging)
        XCTAssertEqual(requested, ["AppIconOcean"])
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism",
                       "An in-flight request must not become the saved choice")

        await complete(completion, store: store)
        XCTAssertFalse(store.isChanging)
        XCTAssertEqual(store.notice, .success(.ocean, previous: .prism))
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "ocean")
    }

    func testFailureKeepsPreviousConfirmedChoice() async {
        let defaults = makeDefaults()
        defaults.set("ocean", forKey: AppIconStore.choiceKey)
        var completion: ((Error?) -> Void)?
        let store = makeStore(defaults: defaults, apply: { _, done in completion = done })
        store.select(.mint)
        await complete(completion, error: NSError(domain: "test", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: "拒绝"]), store: store)
        XCTAssertEqual(store.selected, .ocean)
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "ocean")
        XCTAssertEqual(store.notice, .failure("拒绝"))
        XCTAssertEqual(makeStore(defaults: defaults).selected, .ocean)
    }

    func testPosix35WithoutMatchingSystemIconIsAFailure() async {
        let defaults = makeDefaults()
        var completion: ((Error?) -> Void)?
        let store = makeStore(defaults: defaults, apply: { _, done in completion = done })
        store.select(.iris)
        await complete(completion, error: NSError(domain: NSPOSIXErrorDomain, code: 35), store: store)
        XCTAssertEqual(store.selected, .prism)
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism")
        guard case .failure = store.notice else { return XCTFail("An unconfirmed error must not report success") }
    }

    func testPosix35CanSucceedWhenSystemConfirmsRequestedIcon() async {
        var system: String? = nil
        var completion: ((Error?) -> Void)?
        let store = makeStore(system: { system }, apply: { _, done in completion = done })
        store.select(.iris)
        system = "AppIconIris"
        await complete(completion, error: NSError(domain: NSPOSIXErrorDomain, code: 35), store: store)
        XCTAssertEqual(store.selected, .iris)
        XCTAssertEqual(store.notice, .success(.iris, previous: .prism))
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

    func testUndoRestoresAndPersistsPreviousIcon() async {
        let defaults = makeDefaults()
        var requested: [String?] = []
        var completion: ((Error?) -> Void)?
        let store = makeStore(defaults: defaults, apply: { name, done in
            requested.append(name)
            completion = done
        })
        store.select(.ocean)
        await complete(completion, store: store)
        store.undo()
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
        store.undo()
        XCTAssertEqual(requested, ["AppIconOcean"])
        XCTAssertEqual(store.selected, .ocean)
        await complete(completion, store: store)
    }

    func testUnsupportedDeviceDoesNotRequestOrPersistAChange() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults, supportsIcons: false, apply: { _, _ in
            XCTFail("Unsupported devices must not request an alternate icon")
        })
        store.select(.mint)
        XCTAssertEqual(store.selected, .prism)
        XCTAssertFalse(store.isChanging)
        XCTAssertEqual(defaults.string(forKey: AppIconStore.choiceKey), "prism")
    }

    func testSelectingCurrentAlternateDoesNotSendAnotherRequest() {
        let store = makeStore(system: { "AppIconOcean" }, apply: { _, _ in
            XCTFail("Selecting the active style must not send a duplicate request")
        })
        store.select(.ocean)
        XCTAssertFalse(store.isChanging)
        XCTAssertNil(store.notice)
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
