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

    func testSeekHapticTrackerMatchesVidHubCadenceEdgesAndThrottle() {
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 0), 10.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 20), 1.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 30), 1.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 120), 5.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 180), 5.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 3600), 10.0)

        var tracker = SeekHapticTracker()
        XCTAssertEqual(tracker.begin(at: 100, duration: 3600, now: 10.0), .begin)
        // Same 10s bucket -> no tick
        XCTAssertNil(tracker.update(target: 108, duration: 3600, now: 10.1))
        // Cross 110s boundary after >= 35ms -> tick
        XCTAssertEqual(tracker.update(target: 112, duration: 3600, now: 10.2), .tick)
        // Ultra-fast swipe within < 35ms -> throttled
        XCTAssertNil(tracker.update(target: 125, duration: 3600, now: 10.21))
        // Next bucket after >= 35ms -> tick
        XCTAssertEqual(tracker.update(target: 135, duration: 3600, now: 10.3), .tick)
        // Hit start boundary (0s) -> single boundary haptic, no repeat while held at 0
        XCTAssertEqual(tracker.update(target: 0, duration: 3600, now: 10.4), .boundary)
        XCTAssertNil(tracker.update(target: 0, duration: 3600, now: 10.5))
        // Leave boundary, then hit end boundary -> boundary haptic once
        XCTAssertEqual(tracker.update(target: 15, duration: 3600, now: 10.6), .tick)
        XCTAssertEqual(tracker.update(target: 3600, duration: 3600, now: 10.7), .boundary)
        XCTAssertNil(tracker.update(target: 3599.8, duration: 3600, now: 10.8))
        // End after moving >= 0.8s -> commit
        XCTAssertEqual(tracker.end(finalTarget: 135), .commit)
        XCTAssertFalse(tracker.isActive)

        // Small jitter (< 0.8s) -> no commit haptic
        _ = tracker.begin(at: 50, duration: 3600, now: 20.0)
        XCTAssertNil(tracker.end(finalTarget: 50.3))

        // Pan-seek ceiling (duration - 5s) hits end boundary cleanly without repeating
        _ = tracker.begin(at: 100, duration: 3600, now: 30.0)
        XCTAssertEqual(tracker.update(target: 3595, duration: 3600, upperBound: 3595, now: 30.1), .boundary)
        XCTAssertNil(tracker.update(target: 3595, duration: 3600, upperBound: 3595, now: 30.2))
        tracker.reset()
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.end(finalTarget: 500))
    }
}
