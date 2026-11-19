import CoreGraphics
import XCTest
@testable import HPlayer

@MainActor
final class PlaybackGesturePrefsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "PlaybackGesturePrefsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testDefaultSettingsPersistCustomizationsAndResetCleanly() {
        let defaults = makeDefaults()
        let store = PlaybackGestureStore(defaults: defaults)
        XCTAssertEqual(store.settings, .default)
        XCTAssertTrue(store.settings.isDefault)
        XCTAssertEqual(store.settings.summaryText, "默认")

        store.settings.doubleTapAction = .playPause
        store.settings.doubleTapStep = .s15
        store.settings.longPressBoostRate = .r25
        store.settings.longPressExtra = .swipeUpToLock
        store.settings.seekSensitivity = .fast
        store.settings.leftVerticalAction = .volume
        store.settings.rightVerticalAction = .brightness
        store.settings.disableVerticalInPortrait = true
        store.settings.lockDisablesAllGestures = true

        let reloaded = PlaybackGestureStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings, store.settings)
        XCTAssertFalse(reloaded.settings.isDefault)
        XCTAssertEqual(reloaded.settings.summaryText, "双击暂停 · 长按 2.5×")

        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.settings, .default)
        XCTAssertEqual(PlaybackGesturePrefs.load(from: defaults), .default)
        XCTAssertEqual(reloaded.settings.summaryText, "默认")
    }

    func testDisablingDoubleTapAndLongPressUpdatesSummary() {
        var settings = PlaybackGestureSettings.default
        settings.doubleTapAction = .off
        settings.longPressBoostEnabled = false
        settings.leftVerticalAction = .off
        settings.rightVerticalAction = .off
        XCTAssertFalse(settings.hasAnyVerticalAction)
        XCTAssertEqual(settings.summaryText, "无双击")
    }

    func testDoubleTapRegionSplitsIntoEqualThirds() {
        let settings = PlaybackGestureSettings.default
        XCTAssertEqual(settings.doubleTapRegion(at: 50, width: 300), .left)
        XCTAssertEqual(settings.doubleTapRegion(at: 99, width: 300), .left)
        XCTAssertEqual(settings.doubleTapRegion(at: 150, width: 300), .center)
        XCTAssertEqual(settings.doubleTapRegion(at: 201, width: 300), .right)
        XCTAssertEqual(settings.doubleTapRegion(at: 290, width: 300), .right)
        XCTAssertEqual(settings.doubleTapRegion(at: 0, width: 0), .center)
    }

    func testVerticalAxisMappingAndPortraitGuard() {
        var settings = PlaybackGestureSettings.default
        XCTAssertEqual(settings.verticalAction(at: 60, width: 300, isLandscape: false), .brightness)
        XCTAssertEqual(settings.verticalAction(at: 240, width: 300, isLandscape: false), .volume)

        settings.leftVerticalAction = .volume
        settings.rightVerticalAction = .brightness
        XCTAssertEqual(settings.verticalAction(at: 60, width: 300, isLandscape: true), .volume)
        XCTAssertEqual(settings.verticalAction(at: 240, width: 300, isLandscape: true), .brightness)

        settings.disableVerticalInPortrait = true
        XCTAssertEqual(settings.verticalAction(at: 60, width: 300, isLandscape: false), .off)
        XCTAssertEqual(settings.verticalAction(at: 240, width: 300, isLandscape: false), .off)
        XCTAssertEqual(settings.verticalAction(at: 60, width: 300, isLandscape: true), .volume)
    }

    func testSeekSensitivityAndPullDownCancelThreshold() {
        let precise = PlaybackSeekSensitivity.precise.seekRange(duration: 1800)
        let standard = PlaybackSeekSensitivity.standard.seekRange(duration: 1800)
        let fast = PlaybackSeekSensitivity.fast.seekRange(duration: 1800)
        XCTAssertLessThan(precise, standard)
        XCTAssertLessThan(standard, fast)
        XCTAssertEqual(standard, 540, accuracy: 0.01)

        var settings = PlaybackGestureSettings.default
        XCTAssertFalse(settings.shouldCancelSeek(translationY: 30, surfaceHeight: 400))
        XCTAssertTrue(settings.shouldCancelSeek(translationY: 90, surfaceHeight: 400))

        settings.pullDownToCancelSeek = false
        XCTAssertFalse(settings.shouldCancelSeek(translationY: 160, surfaceHeight: 400))
    }

    func testCorruptedStoredValuesFallbackSafelyToDefaults() {
        let defaults = makeDefaults()
        defaults.set("invalid_mode", forKey: PlaybackGesturePrefs.Key.doubleTapAction)
        defaults.set(999, forKey: PlaybackGesturePrefs.Key.doubleTapStep)
        defaults.set("99x", forKey: PlaybackGesturePrefs.Key.longPressBoostRate)
        defaults.set("unknown", forKey: PlaybackGesturePrefs.Key.pinchAction)

        let loaded = PlaybackGesturePrefs.load(from: defaults)
        XCTAssertEqual(loaded, .default)
    }
}
