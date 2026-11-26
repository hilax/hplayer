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

    func testSeekHapticTrackerSpatialHysteresisVelocityMajorOriginAndBoundaries() {
        var pan = SeekHapticTracker(mode: .pan)
        XCTAssertEqual(pan.begin(at: 100, duration: 3600, positionPt: 0, now: 10.0), .begin)

        // Small jitter below pan step (10pt) -> no tick
        XCTAssertNil(pan.update(target: 105, duration: 3600, positionPt: 5.0, now: 10.05))

        // Slow drag (12pt in 0.2s = 60 pt/s < 140) -> .tick(.slow)
        XCTAssertEqual(pan.update(target: 112, duration: 3600, positionPt: 12.0, now: 10.25), .tick(speed: .slow))
        // Tremor immediately after firing -> hysteresis prevents double fire
        XCTAssertNil(pan.update(target: 111, duration: 3600, positionPt: 11.2, now: 10.28))

        // Faster drag (15pt in 0.05s = 300 pt/s) -> .tick(.normal)
        XCTAssertEqual(pan.update(target: 125, duration: 3600, positionPt: 27.0, now: 10.30), .tick(speed: .normal))

        // Ultra-fast drag within < 24ms -> throttled AND anchor does NOT advance
        XCTAssertNil(pan.update(target: 140, duration: 3600, positionPt: 38.0, now: 10.31))
        // Once >= 24ms passes, even 0.5pt more (>= 10pt from anchor 27.0) fires immediately
        XCTAssertEqual(pan.update(target: 141, duration: 3600, positionPt: 38.5, now: 10.33), .tick(speed: .normal))

        // Sustained fast drag (667 pt/s >= 480) -> 4th tick is .tick(.fast), 5th tick becomes .majorTick
        XCTAssertEqual(pan.update(target: 155, duration: 3600, positionPt: 58.5, now: 10.36), .tick(speed: .fast))
        XCTAssertEqual(pan.update(target: 170, duration: 3600, positionPt: 78.5, now: 10.39), .majorTick)

        // Return toward origin (0pt) after leaving >= 16pt -> emits .origin once and resets tick stride
        XCTAssertEqual(pan.update(target: 101, duration: 3600, positionPt: 3.0, now: 10.60), .origin)
        XCTAssertNil(pan.update(target: 100, duration: 3600, positionPt: 0.0, now: 10.65))

        // Flipping directly across origin (-5pt from positive anchor) also emits .origin
        XCTAssertEqual(pan.update(target: 120, duration: 3600, positionPt: 20.0, now: 10.75), .tick(speed: .normal))
        XCTAssertEqual(pan.update(target: 95, duration: 3600, positionPt: -6.0, now: 10.80), .origin)

        // Start & end boundary deduplication
        XCTAssertEqual(pan.update(target: 0, duration: 3600, positionPt: -200.0, now: 10.90), .boundary)
        XCTAssertNil(pan.update(target: 0, duration: 3600, positionPt: -220.0, now: 10.95))
        XCTAssertEqual(pan.update(target: 3595, duration: 3600, upperBound: 3595, positionPt: 200.0, now: 11.05), .boundary)
        XCTAssertNil(pan.update(target: 3595, duration: 3600, upperBound: 3595, positionPt: 215.0, now: 11.10))

        // End after moving >= 0.5s -> .commit
        XCTAssertEqual(pan.end(finalTarget: 135), .commit)
        XCTAssertFalse(pan.isActive)

        // Small jitter (< 0.5s) -> no commit haptic
        _ = pan.begin(at: 50, duration: 3600, positionPt: 0, now: 20.0)
        XCTAssertNil(pan.end(finalTarget: 50.3))

        // Scrubber mode uses tighter 8pt step
        var scrubber = SeekHapticTracker(mode: .scrubber)
        XCTAssertEqual(scrubber.begin(at: 0, duration: 3600, positionPt: 0, now: 30.0), .begin)
        XCTAssertNil(scrubber.update(target: 10, duration: 3600, positionPt: 7.5, now: 30.05))
        XCTAssertEqual(scrubber.update(target: 12, duration: 3600, positionPt: 8.5, now: 30.10), .tick(speed: .slow))
        scrubber.reset()
        XCTAssertFalse(scrubber.isActive)
        XCTAssertNil(scrubber.end(finalTarget: 500))
    }

    func testSeekHapticTrackerTimeFallbackAndPlayerHapticsLifecycle() {
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 0), 10.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 20), 1.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 120), 3.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 600), 5.0)
        XCTAssertEqual(SeekHapticTracker.stepSeconds(for: 3600), 10.0)

        var tracker = SeekHapticTracker(mode: .pan)
        XCTAssertEqual(tracker.begin(at: 100, duration: 3600, now: 10.0), .begin)
        XCTAssertNil(tracker.update(target: 108, duration: 3600, now: 10.05))
        XCTAssertEqual(tracker.update(target: 111, duration: 3600, now: 10.10), .tick(speed: .normal))
        XCTAssertEqual(tracker.update(target: 122, duration: 3600, now: 10.15), .tick(speed: .normal))
        XCTAssertEqual(tracker.update(target: 133, duration: 3600, now: 10.20), .tick(speed: .normal))
        XCTAssertEqual(tracker.update(target: 144, duration: 3600, now: 10.25), .tick(speed: .normal))
        XCTAssertEqual(tracker.update(target: 155, duration: 3600, now: 10.30), .majorTick)
        XCTAssertEqual(tracker.update(target: 101, duration: 3600, now: 10.40), .origin)
        XCTAssertEqual(tracker.update(target: 0, duration: 3600, now: 10.50), .boundary)
        XCTAssertEqual(tracker.end(finalTarget: 101), .commit)

        // Smoke test PlayerHaptics lifecycle on Simulator/device without crashes
        PlayerHaptics.warmUp()
        PlayerHaptics.prepareForSeek()
        for event in [
            SeekHapticEvent.begin,
            .tick(speed: .slow),
            .tick(speed: .normal),
            .tick(speed: .fast),
            .majorTick,
            .origin,
            .boundary,
            .commit,
            .cancelToggle(cancelled: true),
            .cancelToggle(cancelled: false),
        ] {
            PlayerHaptics.fire(event)
        }
        PlayerHaptics.fire(nil)
        PlayerHaptics.tap()
        PlayerHaptics.cooldown()
    }
}
