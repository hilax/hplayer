import XCTest

final class PlaybackUITests: XCTestCase {
    func testPlaybackControlsAndLandscape() throws {
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

    /// 模拟 CDN 卡死：测试服务器对第一次往文件后半段跳转的请求只接受连接、不回数据。
    /// 以前会一直「正在缓冲」，只能退出重进；现在播放器要自己发现、重连，
    /// 并从跳转的目标位置接着播。
    func testPlaybackRecoversWhenSeekStalls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/stall/seek-fixture.mp4"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        // 预读调小，跳转时一定会发出新的网络请求
        app.launchEnvironment["HPLAYER_UI_TEST_PREFETCH_KB"] = "256"
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
        let pause = app.buttons["playback.playPause"]
        XCTAssertTrue(wait {
            surface.exists && (pause.value as? String) == "playing"
                && self.metric("time", surface: surface) > 1 && app.sliders.firstMatch.isEnabled
        }, "MP4 should start playing; status=\(surface.value as? String ?? "")")

        let before = metric("time", surface: surface)
        swipe(surface, from: CGVector(dx: 0.15, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.5))
        XCTAssertTrue(wait { (surface.value as? String)?.contains("快进") == true })

        // 跳转用的请求被挂住了：播放器应自动重连，从目标位置继续播放
        XCTAssertTrue(wait(timeout: 45) { self.metric("time", surface: surface) > before + 40 },
                      "Player should reconnect by itself and continue from the seek target; before=\(before) status=\(surface.value as? String ?? "")")
        let resumed = metric("time", surface: surface)
        XCTAssertTrue(wait(timeout: 15) { self.metric("time", surface: surface) > resumed + 2 },
                      "Playback should keep advancing after reconnecting; status=\(surface.value as? String ?? "")")
        XCTAssertEqual(pause.value as? String, "playing")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "HPlayer recovered after stalled seek"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// 像 115 上的 4K MKV 一样：索引在文件末尾、每个请求都要等一会儿、经过本机中转。
    /// 大跨度往后滑要落在目标附近接着播；滑过头只停在结尾前，播完后往回滑还能继续播。
    func testFarSeekInMKVThroughRelay() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/range/seek-fixture.mkv"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        // 缓存调小：和 4K 原画一样，大跨度跳转必须重新向服务器要数据（先读文件末尾的索引，再读目标位置）
        app.launchEnvironment["HPLAYER_UI_TEST_PREFETCH_KB"] = "256"
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
        let pause = app.buttons["playback.playPause"]
        XCTAssertTrue(wait(timeout: 40) {
            surface.exists && (pause.value as? String) == "playing"
                && self.metric("time", surface: surface) > 1 && app.sliders.firstMatch.isEnabled
        }, "MKV should start playing through the relay; status=\(surface.value as? String ?? "")")

        // 300 秒的片子滑满一屏是 180 秒；滑七成大约往后 120 秒，是关键帧跳转
        let before = metric("time", surface: surface)
        swipe(surface, from: CGVector(dx: 0.12, dy: 0.42), to: CGVector(dx: 0.82, dy: 0.42))
        XCTAssertTrue(wait { (surface.value as? String)?.contains("快进") == true })
        XCTAssertTrue(wait(timeout: 30) {
            let time = self.metric("time", surface: surface)
            return time > before + 80 && time < 280
        }, "Far seek should land near the target, not at the end; before=\(before) status=\(surface.value as? String ?? "")")
        let landed = metric("time", surface: surface)
        XCTAssertTrue(wait(timeout: 15) { self.metric("time", surface: surface) > landed + 2 },
                      "Playback should keep going after the far seek; status=\(surface.value as? String ?? "")")

        // 连着滑两次、远远超过结尾：最多停在结尾前 5 秒，播完后停在结尾
        swipe(surface, from: CGVector(dx: 0.06, dy: 0.42), to: CGVector(dx: 0.94, dy: 0.42))
        swipe(surface, from: CGVector(dx: 0.06, dy: 0.42), to: CGVector(dx: 0.94, dy: 0.42))
        XCTAssertTrue(wait(timeout: 30) { self.metric("time", surface: surface) > 290 },
                      "Overshooting should stop just before the end; status=\(surface.value as? String ?? "")")
        XCTAssertTrue(wait(timeout: 20) { (pause.value as? String) == "paused" },
                      "The video should finish; status=\(surface.value as? String ?? "")")

        // 播完以后往回滑：要接着播，不能卡在结尾
        swipe(surface, from: CGVector(dx: 0.82, dy: 0.42), to: CGVector(dx: 0.12, dy: 0.42))
        XCTAssertTrue(wait(timeout: 30) {
            let time = self.metric("time", surface: surface)
            return time > 120 && time < 260 && (pause.value as? String) == "playing"
        }, "Swiping back after the end should resume playback; status=\(surface.value as? String ?? "")")
        let resumed = metric("time", surface: surface)
        XCTAssertTrue(wait(timeout: 15) { self.metric("time", surface: surface) > resumed + 2 },
                      "Playback should advance again after leaving the end; status=\(surface.value as? String ?? "")")
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
