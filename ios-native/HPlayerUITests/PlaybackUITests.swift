import XCTest

final class PlaybackUITests: XCTestCase {
    func testVLCPlaybackControlsAndLandscape() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/hls-fixture/index.m3u8"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        app.launch()
        addTeardownBlock {
            if self.testRun?.hasSucceeded == false {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                self.add(hierarchy)
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
            }
        }

        let surface = app.otherElements["playback.surface"]
        let orientation = app.buttons["playback.orientation"]
        let pause = app.buttons["playback.playPause"]
        let elapsed = app.staticTexts["playback.elapsed"]
        XCTAssertTrue(wait { surface.exists && orientation.exists && app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, "Player should open in landscape")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(wait { (pause.value as? String) == "playing" && self.seconds(elapsed.label) > 0 && app.sliders.firstMatch.isEnabled }, "HLS should play with working seeking")

        pause.tap()
        XCTAssertTrue(wait { (pause.value as? String) == "paused" })
        let before = seconds(elapsed.label)
        swipe(surface, from: CGVector(dx: 0.4, dy: 0.48), to: CGVector(dx: 0.65, dy: 0.48))
        XCTAssertTrue(wait { (surface.value as? String)?.contains("快进") == true })
        XCTAssertTrue(wait { self.seconds(elapsed.label) > before + 2 }, "Right swipe must advance playback time")
        XCTAssertTrue(wait { self.metric("time", surface: surface) > before + 2 && (pause.value as? String) == "paused" }, "Decoder should seek while preserving pause")
        let afterForward = seconds(elapsed.label)
        swipe(surface, from: CGVector(dx: 0.65, dy: 0.48), to: CGVector(dx: 0.4, dy: 0.48))
        XCTAssertTrue(wait { (surface.value as? String)?.contains("快退") == true })
        XCTAssertTrue(wait { self.seconds(elapsed.label) < afterForward - 2 }, "Left swipe must rewind playback time")
        XCTAssertTrue(wait { self.metric("time", surface: surface) < afterForward - 2 && (pause.value as? String) == "paused" })

        swipe(surface, from: CGVector(dx: 0.2, dy: 0.4), to: CGVector(dx: 0.2, dy: 0.65))
        XCTAssertTrue(wait { (surface.value as? String)?.contains("亮度") == true })
        let dimmed = metric("brightness", surface: surface)
        swipe(surface, from: CGVector(dx: 0.2, dy: 0.65), to: CGVector(dx: 0.2, dy: 0.4))
        XCTAssertTrue(wait { self.metric("brightness", surface: surface) > dimmed + 0.1 }, "Left vertical swipe must change brightness")

        swipe(surface, from: CGVector(dx: 0.8, dy: 0.4), to: CGVector(dx: 0.8, dy: 0.65))
        XCTAssertTrue(wait { (surface.value as? String)?.contains("音量") == true })
        let quieter = metric("volume", surface: surface)
        swipe(surface, from: CGVector(dx: 0.8, dy: 0.65), to: CGVector(dx: 0.8, dy: 0.4))
        XCTAssertTrue(wait { self.metric("volume", surface: surface) > quieter + 0.1 }, "Right vertical swipe must change volume")

        let center = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        center.doubleTap()
        XCTAssertTrue(wait { (pause.value as? String) == "playing" }, "Double tap should resume")
        center.press(forDuration: 1.2)
        XCTAssertTrue(wait { (surface.value as? String)?.contains("长按 3×") == true })
        XCTAssertEqual(metric("rate", surface: surface), 1, accuracy: 0.01, "Releasing long press restores normal speed")
        // 松手后重新打开音轨，等它恢复播放再继续
        XCTAssertTrue(wait { (pause.value as? String) == "playing" })
        center.doubleTap()
        XCTAssertTrue(wait { (pause.value as? String) == "paused" }, "Double tap should pause")

        center.tap()
        XCTAssertTrue(wait { !pause.exists }, "Tap should hide controls")
        center.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "Tap should reveal controls")
        app.buttons["playback.lock"].tap()
        XCTAssertTrue(app.buttons["playback.unlock"].waitForExistence(timeout: 3))
        swipe(surface, from: CGVector(dx: 0.4, dy: 0.48), to: CGVector(dx: 0.65, dy: 0.48))
        XCTAssertFalse(pause.exists, "Locked player hides playback buttons")
        app.buttons["playback.unlock"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))

        app.buttons["playback.playlist"].tap()
        let next = app.buttons["playback.item.direct|测试下一集|http://127.0.0.1:8765/hls-fixture/index.m3u8"]
        XCTAssertTrue(next.waitForExistence(timeout: 3))
        next.tap()
        XCTAssertTrue(app.staticTexts["测试下一集"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait { (pause.value as? String) == "playing" })
        orientation.tap()
        XCTAssertTrue(wait { orientation.label == "横屏" && surface.frame.height > surface.frame.width })
        orientation.tap()
        XCTAssertTrue(wait { orientation.label == "竖屏" && surface.frame.width > surface.frame.height })
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "HPlayer landscape gestures"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func swipe(_ surface: XCUIElement, from: CGVector, to: CGVector) {
        surface.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: to))
    }

    private func wait(timeout: TimeInterval = 15, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout) == .completed
    }

    private func seconds(_ text: String) -> Double {
        text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private func metric(_ name: String, surface: XCUIElement) -> Double {
        let text = surface.value as? String ?? ""
        return text.components(separatedBy: ";").compactMap { part -> Double? in
            let components = part.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            return components.count == 2 && components[0] == name ? Double(components[1]) : nil
        }.first ?? -1
    }
}
