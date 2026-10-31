import XCTest

/// Every reviewed artboard is exercised through a real native view or state.
final class ScreenCatalogUITests: XCTestCase {
    func test01Home() { capture("home", expected: "首页") }
    func test02HomeMore() { capture("home-more", expected: "电影") }
    func test03HomeEmpty() { capture("home-empty", expected: "让好内容，在这里相遇") }
    func test04Movies() { capture("movies", expected: "电影") }
    func test05Series() { capture("series", expected: "剧集") }
    func test06People() { capture("people", expected: "演员合集") }
    func test07Person() { capture("person", expected: "提莫西·查拉梅") }
    func test08Detail() { capture("detail", expected: "人生切割术") }
    func test09Continue() { capture("continue", expected: "继续观看") }
    func test10Add() { capture("add", expected: "添加影片") }
    func test11FilmMenu() { capture("film-menu", expected: "影片选项") }
    func test12Library() { capture("library", expected: "资源库") }
    func test13LibraryEmpty() { capture("library-empty", expected: "资源库") }
    func test14Files() { capture("files", expected: "影视收藏") }
    func test15FilesSelect() { capture("files-select", expected: "选择视频") }
    func test16Local() { capture("local", expected: "本机视频") }
    func test17Search() { capture("search", expected: "找到你想看的") }
    func test18SearchResults() { capture("search-results", expected: "沙丘 2") }
    func test19SearchEmpty() { capture("search-empty", expected: "暂时没有找到") }
    func test20Manage() { capture("manage", expected: "媒体库管理") }
    func test21FolderPicker() { capture("folder-picker", expected: "选择扫描目录") }
    func test22Unmatched() { capture("unmatched", expected: "未匹配影片") }
    func test23Match() { capture("match", expected: "匹配封面") }
    func test24Metadata() { capture("metadata", expected: "资料来源") }
    func test25Credentials() { capture("credentials", expected: "资料接口凭证") }
    func test26Settings() { capture("settings", expected: "设置") }
    func test27Appearance() { capture("appearance", expected: "你喜欢的观看氛围") }
    func test28Connect115() { capture("connect115", expected: "连接 115 网盘") }
    func test29Official() { capture("official", expected: "115 官方授权") }
    func test30Licenses() { capture("licenses", expected: "致谢开源社区") }
    func test31Magnet() { capture("magnet", expected: "粘贴，即刻开播") }
    func test32Resolving() { capture("resolving", expected: "正在获取影片目录") }
    func test33MagnetFiles() { capture("magnet-files", expected: "资源目录") }
    func test34Torrent() { capture("torrent", expected: "BT 云下载") }
    func test35TorrentFiles() { capture("torrent-files", expected: "选择下载文件") }
    func test36Portrait() { capture("portrait", expected: "portrait") }
    func test37Landscape() { capture("landscape", expected: "landscape") }
    func test38Playback() { capture("playback", expected: "播放设置") }
    func test39Tracks() { capture("tracks", expected: "字幕与音轨") }
    func test40Episodes() { capture("episodes", expected: "选集") }
    func test41Aspect() { capture("aspect", expected: "画面比例") }
    func test42HomeLight() { capture("home", expected: "首页", style: "light") }
    func test43LibraryLight() { capture("library", expected: "资源库", style: "light") }
    func test44FilesLight() { capture("files", expected: "影视收藏", style: "light") }
    func test45SearchLight() { capture("search-results", expected: "沙丘 2", style: "light") }
    func test46MetadataLight() { capture("metadata", expected: "资料来源", style: "light") }
    func test47SettingsLight() { capture("settings", expected: "设置", style: "light") }

    private func capture(_ screen: String, expected: String, style: String = "dark") {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["HPLAYER_DESIGN_SCREEN"] = screen
        app.launchEnvironment["HPLAYER_DESIGN_STYLE"] = style
        app.launchEnvironment["HPLAYER_UI_TEST_115_HEADERS"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_115_COOKIE"] = "UID=ui-test; CID=ui-test; SEID=ui-test; KID=ui-test"
        app.launchEnvironment["HPLAYER_UI_TEST_KEEP_CONTROLS_VISIBLE"] = "1"
        app.launchEnvironment["HPLAYER_UI_TEST_URL"] = "http://127.0.0.1:8765/hls-fixture/index.m3u8"
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        if ["portrait", "landscape", "playback", "tracks", "episodes", "aspect"].contains(screen) {
            XCTAssertTrue(app.buttons["playback.close"].waitForExistence(timeout: 25))
            if screen == "portrait" || screen == "landscape" {
                XCTAssertTrue(wait { (app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height) == (screen == "landscape") })
                XCTAssertTrue(wait { self.seconds(app.staticTexts["playback.elapsed"].label) > 0 })
            }
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["catalog.\(screen)"].firstMatch.waitForExistence(timeout: 25))
        }
        if screen == "home-more" {
            let movies = app.staticTexts["电影"].firstMatch
            for _ in 0..<3 {
                let distance = movies.frame.minY - 140
                if distance < 30 { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                let end = start.withOffset(CGVector(dx: 0, dy: -min(distance, app.windows.firstMatch.frame.height * 0.45)))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        if screen == "home-more" {
            XCTAssertTrue(app.buttons["home.scrolledAdd"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["home.scrolledAdd"].isHittable, "Scrolled navigation must remain within the safe area")
        }
        if screen == "add" { app.buttons["home.sources"].tap() }
        if screen == "film-menu" { app.buttons["影片选项"].tap() }
        if screen != "portrait" && screen != "landscape" {
            XCTAssertTrue(app.staticTexts[expected].firstMatch.waitForExistence(timeout: 10), "Missing native state: \(screen)")
        }
        if screen.hasPrefix("home") {
            XCTAssertFalse(app.buttons["home.scanStatus"].exists)
            XCTAssertFalse(app.otherElements["home.matchingState"].exists)
            XCTAssertFalse(app.staticTexts["待匹配"].exists)
        }
        // Allow the native presentation transition and localhost artwork requests to finish.
        Thread.sleep(forTimeInterval: 1.2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Prototype41-\(screen)-\(style)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: 15) == .completed
    }
    private func seconds(_ text: String) -> Double {
        text.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }
}
