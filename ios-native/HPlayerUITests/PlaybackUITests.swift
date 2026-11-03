import XCTest

final class PlaybackUITests: XCTestCase {
    func testCloseRestoresPortraitAndAllowsReopening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/hls-fixture/index.m3u8"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        app.launch()

        let close = app.buttons["playback.close"]
        let reopen = app.buttons["playbackTest.reopen"]
        let previousPage = app.staticTexts["playbackTest.previousPage"]
        let orientation = app.buttons["playback.orientation"]
        let surface = app.otherElements["playback.surface"]
        XCTAssertTrue(wait { close.exists && surface.exists && orientation.exists && orientation.label == "竖屏" },
                      "Player should open in landscape; debug=\(debugText(app)); window=\(surface.frame)")
        XCTAssertTrue(wait { self.isLandscape(app) }, "The player window should be in real landscape")
        close.tap()
        XCTAssertTrue(wait { !surface.exists && previousPage.exists && reopen.isHittable && self.isPortraitWindow(app) },
                      "Closing must simply reveal the previous page, which was portrait all along")

        reopen.tap()
        XCTAssertTrue(wait { close.exists && surface.exists && orientation.exists && orientation.label == "竖屏" },
                      "The player should reopen in landscape")
        orientation.tap()
        XCTAssertTrue(wait { orientation.label == "横屏" && !self.isLandscape(app) && surface.frame.height < app.windows.firstMatch.frame.height * 0.5 },
                      "Player should switch to the portrait layout before the second close")
        close.tap()
        XCTAssertTrue(wait { !surface.exists && previousPage.exists && reopen.isHittable && self.isPortraitWindow(app) },
                      "Closing a portrait player should also restore an interactive previous page")
    }

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
        XCTAssertTrue(wait { surface.exists && orientation.exists && orientation.label == "竖屏" }, "Player should open in landscape; debug=\(debugText(app)); window=\(surface.frame)")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(wait { self.isLandscape(app) }, "The player window should be in real landscape")
        let frame = surface.frame
        XCTAssertGreaterThan(pause.frame.midY, frame.height * 0.72, "Landscape transport belongs below the timeline")
        XCTAssertEqual(pause.frame.midX, frame.midX, accuracy: frame.width * 0.03, "Landscape transport sits in the middle, under the timeline")
        XCTAssertLessThan(app.buttons["playback.previous"].frame.midX, pause.frame.midX, "Previous is left of play/pause")
        XCTAssertGreaterThan(app.buttons["playback.next"].frame.midX, pause.frame.midX, "Next is right of play/pause")
        // 画质、倍速在左，字幕、选集在右；时间贴着进度条两端
        let slider = app.sliders.firstMatch
        XCTAssertLessThan(app.buttons["playback.quality"].frame.midX, app.buttons["playback.speed"].frame.midX)
        XCTAssertLessThan(app.buttons["playback.speed"].frame.midX, pause.frame.midX, "Quality and speed sit left of the transport")
        XCTAssertGreaterThan(app.buttons["playback.subtitles"].frame.midX, pause.frame.midX, "Subtitles sit right of the transport")
        XCTAssertGreaterThan(app.buttons["playback.playlist"].frame.midX, app.buttons["playback.subtitles"].frame.midX)
        XCTAssertLessThanOrEqual(elapsed.frame.maxX, slider.frame.minX + 4, "Elapsed time sits left of the timeline")
        XCTAssertGreaterThanOrEqual(app.staticTexts["总时长"].frame.minX, slider.frame.maxX - 4, "Total time sits right of the timeline")
        XCTAssertLessThan(slider.frame.minX - elapsed.frame.maxX, 14, "Elapsed time hugs the timeline")
        XCTAssertLessThan(app.staticTexts["总时长"].frame.minX - slider.frame.maxX, 14, "Total time hugs the timeline")
        XCTAssertLessThan(abs(elapsed.frame.midY - slider.frame.midY), 12, "Elapsed time is on the timeline row")
        XCTAssertGreaterThan(app.buttons["playback.lock"].frame.midX, frame.width * 0.09, "Lock control should sit inward from the edge")
        XCTAssertLessThan(app.buttons["playback.screenshot"].frame.midX, frame.width * 0.91, "Screenshot control should sit inward from the edge")
        XCTAssertTrue(wait { (pause.value as? String) == "playing" && self.seconds(elapsed.label) > 0 && app.sliders.firstMatch.isEnabled }, "HLS should play with working seeking")

        pause.tap()
        XCTAssertTrue(wait { (pause.value as? String) == "paused" })
        // 倍速点开是一条玻璃分段条，停在进度条上方；选一档后自己收起、倍速生效
        app.buttons["playback.speed"].tap()
        let fast = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1.5×")).firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 5), "Speed options open beside the button")
        XCTAssertLessThan(fast.frame.width, 130, "Each speed is a compact segment, not a fixed-width panel")
        snapshot("Popover-speed")
        XCTAssertLessThanOrEqual(fast.frame.maxY, slider.frame.minY + 4, "The speed bar sits above the timeline")
        fast.tap()
        XCTAssertTrue(wait { (surface.value as? String)?.contains("rate=1.5") == true }, "Picking a speed applies it")
        XCTAssertTrue(wait { !fast.exists }, "The speed bar closes after picking")
        app.buttons["playback.speed"].tap()
        let normal = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1.0×")).firstMatch
        XCTAssertTrue(normal.waitForExistence(timeout: 5))
        normal.tap()
        XCTAssertTrue(wait { (surface.value as? String)?.contains("rate=1;") == true }, "Back to normal speed")
        XCTAssertTrue(wait { !normal.exists }, "The speed bar closes by itself before the gestures below")
        let before = seconds(elapsed.label)
        swipe(surface, from: CGVector(dx: 0.4, dy: 0.32), to: CGVector(dx: 0.65, dy: 0.32))
        XCTAssertTrue(wait { (surface.value as? String)?.contains("快进") == true })
        XCTAssertTrue(wait { self.seconds(elapsed.label) > before + 2 }, "Right swipe must advance playback time")
        XCTAssertTrue(wait { self.metric("time", surface: surface) > before + 2 && (pause.value as? String) == "paused" }, "Decoder should seek while preserving pause")
        let afterForward = seconds(elapsed.label)
        swipe(surface, from: CGVector(dx: 0.65, dy: 0.32), to: CGVector(dx: 0.4, dy: 0.32))
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

        let center = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
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
        swipe(surface, from: CGVector(dx: 0.4, dy: 0.32), to: CGVector(dx: 0.65, dy: 0.32))
        XCTAssertFalse(pause.exists, "Locked player hides playback buttons")
        app.buttons["playback.unlock"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3))

        // 字幕与音轨：字幕、音轨、样式三栏，停在进度条上方；点样式会打勾，点空白处收起
        app.buttons["playback.subtitles"].tap()
        let largeSubtitles = app.buttons["字幕样式：大字"]
        XCTAssertTrue(largeSubtitles.waitForExistence(timeout: 5), "Subtitles open with a style column")
        XCTAssertTrue(app.staticTexts["音轨"].exists)
        XCTAssertLessThanOrEqual(largeSubtitles.frame.maxY, slider.frame.minY + 4, "The tracks panel sits above the timeline")
        snapshot("Popover-tracks")
        largeSubtitles.tap()
        XCTAssertTrue(wait { largeSubtitles.isSelected }, "Picking a subtitle style marks it")
        let outlineSubtitles = app.buttons["字幕样式：描边"]
        outlineSubtitles.tap()
        XCTAssertTrue(wait { outlineSubtitles.isSelected }, "Back to the default style")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).tap()
        XCTAssertTrue(wait { !largeSubtitles.exists }, "Tapping outside closes the panel")

        // 更多：解码、提前缓存、定时关闭可以点进二级页再返回
        app.buttons["playback.more"].tap()
        let sleepRow = app.buttons["playback.more.sleep"]
        XCTAssertTrue(sleepRow.waitForExistence(timeout: 5), "More opens as a menu under its button")
        snapshot("Popover-more")
        sleepRow.tap()
        XCTAssertTrue(app.buttons["本集结束"].waitForExistence(timeout: 3), "Sleep timer opens as a submenu")
        snapshot("Popover-more-sleep")
        app.buttons["返回"].tap()
        XCTAssertTrue(sleepRow.waitForExistence(timeout: 3), "Back returns to the main menu")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(wait { !sleepRow.exists })

        // 画面比例从顶栏按钮下面长出来
        app.buttons["playback.aspect"].tap()
        let fillAspect = app.buttons["铺满裁切"]
        XCTAssertTrue(fillAspect.waitForExistence(timeout: 5), "Aspect options drop down from the top bar")
        snapshot("Popover-aspect")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(wait { !fillAspect.exists })

        // 画质从 HD 图标长出来；测试视频不是 115 文件，只有原画
        app.buttons["playback.quality"].tap()
        let original = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "原画")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Quality opens above the HD icon")
        XCTAssertLessThanOrEqual(original.frame.maxY, slider.frame.minY + 4)
        snapshot("Popover-quality")
        // 画质面板在左下，点右边的空白处收起
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).tap()
        XCTAssertTrue(wait { !original.exists }, "Tapping outside closes the quality menu")

        // 选集是右侧的玻璃面板
        app.buttons["playback.playlist"].tap()
        let next = app.buttons["playback.item.direct|测试下一集|http://127.0.0.1:8765/hls-fixture/index.m3u8"]
        XCTAssertTrue(next.waitForExistence(timeout: 3))
        snapshot("Popover-episodes")
        next.tap()
        XCTAssertTrue(app.staticTexts["测试下一集"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait { (pause.value as? String) == "playing" })
        orientation.tap()
        XCTAssertTrue(wait { orientation.label == "横屏" && !self.isLandscape(app) && surface.frame.height < app.windows.firstMatch.frame.height * 0.5 })
        orientation.tap()
        XCTAssertTrue(wait { orientation.label == "竖屏" && self.isLandscape(app) })
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

    /// 模拟快速跳转时旧位置的结束事件晚到：不能切到下一集，真正播完后仍要自动连播。
    func testStaleEOFDuringSeekDoesNotAutoAdvance() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/range/seek-fixture.mkv"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_PREFETCH_KB"] = "256"
        app.launchEnvironment["HPLAYER_UI_TEST_STALE_EOF_ON_SEEK"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_AUTO_NEXT"] = "1"
        app.launch()

        let surface = app.otherElements["playback.surface"]
        let pause = app.buttons["playback.playPause"]
        let slider = app.sliders.firstMatch
        XCTAssertTrue(wait(timeout: 40) {
            surface.exists && (pause.value as? String) == "playing"
                && self.metric("time", surface: surface) > 1 && slider.isEnabled
        }, "The first video should start")
        let before = metric("time", surface: surface)
        swipe(surface, from: CGVector(dx: 0.12, dy: 0.42), to: CGVector(dx: 0.82, dy: 0.42))
        XCTAssertTrue(wait(timeout: 30) {
            let time = self.metric("time", surface: surface)
            return time > before + 80 && time < 280 && app.staticTexts["测试影片"].exists
        }, "A stale EOF must not advance to the next video; status=\(surface.value as? String ?? "")")
        let landed = metric("time", surface: surface)
        XCTAssertTrue(wait(timeout: 15) { self.metric("time", surface: surface) > landed + 2 })
        XCTAssertFalse(app.staticTexts["测试下一集"].exists)

        // The player content is rotated inside a portrait window. XCUITest's
        // normalized slider adjustment does not reliably issue a seek there,
        // so use the same on-screen gesture as the real playback regression.
        swipe(surface, from: CGVector(dx: 0.06, dy: 0.42), to: CGVector(dx: 0.94, dy: 0.42))
        swipe(surface, from: CGVector(dx: 0.06, dy: 0.42), to: CGVector(dx: 0.94, dy: 0.42))
        XCTAssertTrue(wait(timeout: 30) {
            app.staticTexts["测试下一集"].exists || self.metric("time", surface: surface) > 290
        }, "Playback should reach the end after seeking; status=\(surface.value as? String ?? "")")
        XCTAssertTrue(wait(timeout: 30) { app.staticTexts["测试下一集"].exists },
                      "Normal playback at the end should still advance to the next video; status=\(surface.value as? String ?? "")")
    }

    /// The fixture is an actual 3840×2160 H.264/AAC video, served with delayed Range responses.
    func testRapidSeeksKeep4KVideoPlaying() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/range/seek-4k-fixture.mp4"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_PREFETCH_KB"] = "256"
        app.launchEnvironment["HPLAYER_UI_TEST_STALE_EOF_ON_SEEK"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_AUTO_NEXT"] = "1"
        app.launch()

        let surface = app.otherElements["playback.surface"]
        let pause = app.buttons["playback.playPause"]
        XCTAssertTrue(wait(timeout: 60) {
            surface.exists && (pause.value as? String) == "playing" && app.staticTexts["4K"].exists
                && self.metric("time", surface: surface) > 1 && app.sliders.firstMatch.isEnabled
        }, "The 4K fixture should start; status=\(surface.value as? String ?? "")")
        let before = metric("time", surface: surface)
        swipe(surface, from: CGVector(dx: 0.2, dy: 0.42), to: CGVector(dx: 0.48, dy: 0.42))
        swipe(surface, from: CGVector(dx: 0.2, dy: 0.42), to: CGVector(dx: 0.58, dy: 0.42))
        XCTAssertTrue(wait(timeout: 45) {
            let time = self.metric("time", surface: surface)
            return time > before + 25 && time < 80 && app.staticTexts["测试影片"].exists
        }, "Rapid 4K seeks should stay in the same video; status=\(surface.value as? String ?? "")")
        let landed = metric("time", surface: surface)
        XCTAssertTrue(wait(timeout: 20) { self.metric("time", surface: surface) > landed + 1 })
        XCTAssertFalse(app.staticTexts["测试下一集"].exists)
        XCTAssertTrue(app.staticTexts["4K"].exists)
    }

    func testReplayButtonAfterRapidForwardSeeks() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/range/seek-fixture.mkv"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_PREFETCH_KB"] = "256"
        app.launch()

        let surface = app.otherElements["playback.surface"]
        let pause = app.buttons["playback.playPause"]
        XCTAssertTrue(wait(timeout: 40) {
            surface.exists && (pause.value as? String) == "playing"
                && self.metric("time", surface: surface) > 1 && app.sliders.firstMatch.isEnabled
        })
        for _ in 0..<3 {
            swipe(surface, from: CGVector(dx: 0.06, dy: 0.42), to: CGVector(dx: 0.94, dy: 0.42))
        }
        XCTAssertTrue(wait(timeout: 40) {
            self.metric("time", surface: surface) > 298 && (pause.value as? String) == "paused"
        }, "The video should finish normally after reaching the tail; status=\(surface.value as? String ?? "")")

        pause.tap()
        XCTAssertTrue(wait(timeout: 30) {
            let time = self.metric("time", surface: surface)
            return time > 0.5 && time < 10 && (pause.value as? String) == "playing"
        }, "Play should restart the same video without leaving the player; status=\(surface.value as? String ?? "")")
        let replayed = metric("time", surface: surface)
        XCTAssertTrue(wait { self.metric("time", surface: surface) > replayed + 2 })
        XCTAssertTrue(app.staticTexts["测试影片"].exists)
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

    /// 播放器在独立窗口里真横屏：播放器窗口宽大于高（播放期间主窗口是隐藏的，只有这一个窗口）
    private func isLandscape(_ app: XCUIApplication) -> Bool {
        let frame = app.windows.firstMatch.frame
        return frame.width > frame.height
    }

    /// 弹出层的弹簧动画走完再截图，云端构建产物里能直接看到真机渲染的效果
    private func snapshot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func debugText(_ app: XCUIApplication) -> String {
        app.staticTexts["player.debug"].exists ? app.staticTexts["player.debug"].label : "(no debug label)"
    }

    private func isPortraitWindow(_ app: XCUIApplication) -> Bool {
        let frame = app.windows.firstMatch.frame
        return frame.height > frame.width
    }

    private func swipe(_ surface: XCUIElement, from: CGVector, to: CGVector) {
        surface.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: to))
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
