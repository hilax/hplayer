import XCTest

final class RedesignFlowUITests: XCTestCase {
    func testSourcePanelAndFilmMatchingRoute() {
        let app = launch("home")
        defer { app.terminate() }
        let sources = app.buttons["home.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 20))
        sources.tap()
        XCTAssertTrue(app.staticTexts["添加影片"].waitForExistence(timeout: 5))
        for title in ["导入本机视频", "添加 115 文件夹", "打开磁力链接"] { XCTAssertTrue(app.staticTexts[title].exists) }
        XCTAssertFalse(app.staticTexts["开始全盘扫描"].exists, "Home's add panel only concerns playable content")
        app.buttons["关闭"].tap()
        app.buttons["影片选项"].tap()
        XCTAssertTrue(app.staticTexts["影片选项"].waitForExistence(timeout: 5))
        app.staticTexts["匹配封面"].tap()
        XCTAssertTrue(app.textFields["metadata.query"].waitForExistence(timeout: 5))
    }

    func testBatchSelectionExcludesFoldersAndUpdatesPlayCount() {
        let app = launch("files-select")
        defer { app.terminate() }
        let selected = app.buttons["播放所选 · 2 项"]
        XCTAssertTrue(selected.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["library.file.dir-1"].exists)
        app.buttons["library.file.movie-0"].tap()
        XCTAssertTrue(app.buttons["播放所选 · 1 项"].exists)
        app.buttons["全选"].tap()
        XCTAssertTrue(app.buttons["播放所选 · 4 项"].exists)
        app.buttons["全不选"].tap()
        let empty = app.buttons["播放所选 · 0 项"]
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(empty.isEnabled)
    }

    func testTorrentSelectionUpdatesCountAndDisablesEmptySubmission() {
        let app = launch("torrent-files")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["torrent.file.0"].waitForExistence(timeout: 20))
        app.buttons["torrent.file.0"].tap()
        XCTAssertFalse(app.buttons["torrent.file.0"].isSelected)
        app.buttons["全选"].tap()
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["已选 6 个文件"].exists)
        for _ in 0..<3 { app.swipeDown() }
        app.buttons["全不选"].tap()
        XCTAssertFalse(app.buttons["创建云下载任务"].isEnabled)
    }

    func testPlayerPanelsCloseBackToPlayback() {
        let app = launch("portrait")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["playback.more"].waitForExistence(timeout: 20))
        app.buttons["playback.more"].tap()
        XCTAssertTrue(app.staticTexts["播放设置"].waitForExistence(timeout: 5))
        app.buttons["1.5"].tap()
        app.buttons["关闭设置"].tap()
        app.buttons["playback.tracks"].tap()
        XCTAssertTrue(app.staticTexts["字幕与音轨"].exists)
        XCTAssertTrue(app.buttons["关闭字幕"].exists)
        XCTAssertTrue(app.staticTexts["音轨"].firstMatch.exists)
        app.buttons["关闭设置"].tap()
        app.buttons["画面"].tap()
        XCTAssertTrue(app.staticTexts["画面比例"].waitForExistence(timeout: 5))
        app.buttons["关闭画面比例"].tap()
        app.buttons["playback.playlist"].tap()
        XCTAssertTrue(app.buttons["关闭选集"].waitForExistence(timeout: 5))
        app.buttons["关闭选集"].tap()
        XCTAssertTrue(app.buttons["playback.playPause"].isHittable)
    }

    private func launch(_ screen: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = screen
        app.launchEnvironment["HPLAYER_DESIGN_STYLE"] = "dark"
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/hls-fixture/index.m3u8"
        app.launch()
        return app
    }
}
