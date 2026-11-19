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

    func testDefaultSettingsMatchStandardPresetAndPersistAcrossReloads() {
        let defaults = makeDefaults()
        let store = PlaybackGestureStore(defaults: defaults)
        XCTAssertEqual(store.settings, .default)
        XCTAssertEqual(store.settings.matchingPreset, .standard)
        XCTAssertTrue(store.settings.isDefault)
        XCTAssertEqual(store.settings.summaryText, "标准")

        store.applyPreset(.binge)
        XCTAssertEqual(store.settings.matchingPreset, .binge)
        XCTAssertEqual(store.settings.doubleTapStep, .s15)
        XCTAssertEqual(store.settings.longPressExtra, .swipeUpToLock)
        XCTAssertEqual(store.settings.seekSensitivity, .fast)

        let reloaded = PlaybackGestureStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings, PlaybackGesturePreset.binge.settings)

        reloaded.settings.leftVerticalAction = .volume
        reloaded.settings.rightVerticalAction = .brightness
        XCTAssertNil(reloaded.settings.matchingPreset, "Tweaking a single item should switch from preset to custom")
        XCTAssertTrue(reloaded.settings.summaryText.contains("分区双击"))

        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.settings, .default)
        XCTAssertEqual(PlaybackGesturePrefs.load(from: defaults), .default)
    }

    func testMinimalPresetDisablesDoubleTapAndLocksAllGestures() {
        let minimal = PlaybackGesturePreset.minimal.settings
        XCTAssertEqual(minimal.doubleTapAction, .off)
        XCTAssertFalse(minimal.longPressBoostEnabled)
        XCTAssertFalse(minimal.hasAnyVerticalAction)
        XCTAssertEqual(minimal.pinchAction, .off)
        XCTAssertTrue(minimal.disableVerticalInPortrait)
        XCTAssertTrue(minimal.lockDisablesAllGestures)
        XCTAssertEqual(minimal.summaryText, "防误触")
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
