import XCTest

/// Every reviewed artboard is exercised through a real native view or state.
final class ScreenCatalogUITests: XCTestCase {
    func test01Home() { capture("home", expected: "播放") }
    func test02HomeMore() { capture("home-more", expected: "我的片库 · 电影") }
    func test03HomeEmpty() { capture("home-empty", expected: "让好内容，在这里相遇") }
    func test04Movies() { capture("movies", expected: "电影") }
    func test05Series() { capture("series", expected: "剧集") }
    func test06People() { capture("people", expected: "演员合集") }
    func test07Person() { capture("person", expected: "提莫西·查拉梅") }
    func test08Detail() { capture("detail", expected: "人生切割术") }
    func test09Continue() { capture("continue", expected: "继续观看") }
    func test10Add() { capture("add", expected: "添加影片") }
    func test11FilmMenu() { capture("film-menu", expected: "影片选项") }
    func test12Library() { capture("library", expected: "网盘") }
    func test13LibraryEmpty() { capture("library-empty", expected: "网盘") }
    func test14Files() { capture("files", expected: "影视收藏") }
    func test15FilesSelect() { capture("files-select", expected: "已选 3 项") }
    func test16FilesMenu() { capture("files-menu", expected: "新建文件夹") }
    func test17FilesDelete() { capture("files-delete", expected: "删除 3 项？") }
    func test18FilesMove() { capture("files-move", expected: "选择目标文件夹") }
    func test19FileInfo() { capture("file-info", expected: "文件信息") }
    func test20Recycle() { capture("recycle", expected: "回收站") }
    func test21Offline() { capture("offline", expected: "离线下载") }
    func test22OfflineAdd() { capture("offline-add", expected: "添加离线任务") }
    func test23Downloads() { capture("downloads", expected: "下载管理") }
    func test24Local() { capture("local", expected: "本机视频") }
    func test25Search() { capture("search", expected: "找到你想看的") }
    func test26SearchResults() { capture("search-results", expected: "沙丘 2") }
    func test27SearchEmpty() { capture("search-empty", expected: "暂时没有找到") }
    func test28Manage() { capture("manage", expected: "媒体库管理") }
    func test29FolderPicker() { capture("folder-picker", expected: "选择要扫描的文件夹") }
    func test30Unmatched() { capture("unmatched", expected: "未匹配影片") }
    func test31Match() { capture("match", expected: "匹配封面") }
    func test32Metadata() { capture("metadata", expected: "资料来源") }
    func test33Credentials() { capture("credentials", expected: "资料接口凭证") }
    func test34Settings() { capture("settings", expected: "我的") }
    func test35Appearance() { capture("appearance", expected: "外观") }
    func test36Connect115() { capture("connect115", expected: "连接 115 网盘") }
    func test37Licenses() { capture("licenses", expected: "开源许可") }
    func test38Magnet() { capture("magnet", expected: "磁力在线播放") }
    func test39Resolving() { capture("resolving", expected: "正在获取影片目录") }
    func test40MagnetFiles() { capture("magnet-files", expected: "资源目录") }
    func test41Portrait() { capture("portrait", expected: "portrait") }
    func test42Landscape() { capture("landscape", expected: "landscape") }
    func test43Playback() { capture("playback", expected: "倍速") }
    func test44Tracks() { capture("tracks", expected: "字幕") }
    func test45Episodes() { capture("episodes", expected: "选集") }
    func test46Aspect() { capture("aspect", expected: "画面比例") }
    func test47HomeLight() { capture("home", expected: "播放", style: "light") }
    func test48LibraryLight() { capture("library", expected: "网盘", style: "light") }
    func test49FilesLight() { capture("files", expected: "影视收藏", style: "light") }
    func test50SearchLight() { capture("search-results", expected: "沙丘 2", style: "light") }
    func test51MetadataLight() { capture("metadata", expected: "资料来源", style: "light") }
    func test52SettingsLight() { capture("settings", expected: "我的", style: "light") }
    func test53Catalog() { capture("catalog", expected: "片库") }
    // 2.0 新增页面
    func test54MagnetTab() { capture("magnet-tab", expected: "磁力") }
    func test55Transfers() { capture("transfers", expected: "传输中心") }
    func test56Watchlist() { capture("watchlist", expected: "我的追番") }
    // 竖屏播放页改版
    func test57Sleep() { capture("sleep", expected: "定时关闭") }
    func test58PortraitLight() { capture("portrait", expected: "portrait", style: "light") }
    func test59SleepLight() { capture("sleep", expected: "定时关闭", style: "light") }
    func test60EpisodesLight() { capture("episodes", expected: "选集", style: "light") }
    func test61PlaybackLight() { capture("playback", expected: "倍速", style: "light") }
    func test62TracksLight() { capture("tracks", expected: "字幕", style: "light") }
    func test63AspectLight() { capture("aspect", expected: "画面比例", style: "light") }

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
        if ["portrait", "landscape", "playback", "tracks", "episodes", "aspect", "sleep"].contains(screen) {
            XCTAssertTrue(app.buttons["playback.close"].waitForExistence(timeout: 25))
            if screen == "portrait" || screen == "landscape" {
                // 播放器在独立窗口里：按钮写着「竖屏」就是在横屏，此时播放画面区域也是真的宽大于高
                let orientationButton = app.buttons["playback.orientation"]
                XCTAssertTrue(wait { orientationButton.exists && (orientationButton.label == "竖屏") == (screen == "landscape") })
                XCTAssertTrue(wait {
                    let frame = app.windows.firstMatch.frame
                    return (frame.width > frame.height) == (screen == "landscape")
                })
                XCTAssertTrue(wait { self.seconds(app.staticTexts["playback.elapsed"].label) > 0 })
            }
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["catalog.\(screen)"].firstMatch.waitForExistence(timeout: 25))
        }
        if screen == "home-more" {
            let movies = app.staticTexts["home.shelf.movies"].firstMatch
            for _ in 0..<3 {
                let distance = movies.frame.minY - 140
                if distance < 30 { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                let end = start.withOffset(CGVector(dx: 0, dy: -min(distance, app.windows.firstMatch.frame.height * 0.45)))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        if screen == "home-more" {
            XCTAssertTrue(app.staticTexts["home.shelf.movies"].firstMatch.waitForExistence(timeout: 5))
        }
        if screen == "add" { app.buttons["home.sources"].tap() }
        if screen == "film-menu" {
            // 轮播卡片长按 →「更多选项」打开影片选项面板
            app.buttons["home.heroPlay"].firstMatch.press(forDuration: 1.2)
            let more = app.buttons["更多选项"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
        }
        if screen == "files-menu" {
            // 目录页右上角的「更多」菜单：点开后截图
            let menu = app.buttons["library.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            menu.tap()
        }
        if screen == "sleep" {
            XCTAssertTrue(app.buttons["playback.sleep.off"].waitForExistence(timeout: 10), "Sleep timer menu should be open")
            XCTAssertTrue(app.buttons["playback.sleep.30"].isSelected, "The preset 30 minute option is marked")
        }
        // 竖屏的快捷菜单：倍速、字幕与音轨、画面比例都是按钮旁边的弹出菜单，选集是底部抽屉
        if screen == "playback" {
            XCTAssertTrue(app.buttons["playback.speed.1.5"].waitForExistence(timeout: 10), "Speed menu should be open")
            XCTAssertFalse(app.buttons["关闭设置"].exists, "There is no bottom settings sheet")
        }
        if screen == "tracks" {
            XCTAssertTrue(app.buttons["playback.subtitle.off"].waitForExistence(timeout: 10), "Subtitle menu should be open")
        }
        if screen == "aspect" {
            XCTAssertTrue(app.sliders["画面缩放"].waitForExistence(timeout: 10), "Aspect menu should be open")
        }
        if screen == "episodes" {
            XCTAssertTrue(app.buttons["关闭选集"].waitForExistence(timeout: 10), "Episode drawer should be open")
        }
        if !["portrait", "landscape", "sleep", "playback", "tracks", "aspect"].contains(screen) {
            XCTAssertTrue(wait {
                if screen == "home" { return app.buttons["home.heroPlay"].exists }
                return self.shows(expected, in: app)
            }, "Missing native state: \(screen)")
        }
        if screen.hasPrefix("home") {
            XCTAssertFalse(app.buttons["home.scanStatus"].exists)
            XCTAssertFalse(app.otherElements["home.matchingState"].exists)
            XCTAssertFalse(app.staticTexts["待匹配"].exists)
        }
        if screen == "home" {
            let bar = app.otherElements["home.heroBar"]
            XCTAssertTrue(bar.exists)
            XCTAssertFalse(bar.staticTexts["首页"].exists)
        }
        if screen == "files-menu" {
            // 2.0：离线下载和下载管理合并为传输中心
            for title in ["传输中心", "回收站"] {
                XCTAssertTrue(wait { self.shows(title, in: app) }, "Missing menu entry: \(title)")
            }
        }
        // Allow the native presentation transition and localhost artwork requests to finish.
        Thread.sleep(forTimeInterval: 1.2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Prototype41-\(screen)-\(style)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 页面上有没有这段文字：静态文字、导航栏标题，或者菜单里的按钮。
    /// 按文字内容比较，因为带了无障碍标识的元素不一定能直接用文字下标找到。
    private func shows(_ text: String, in app: XCUIApplication) -> Bool {
        if app.staticTexts[text].firstMatch.exists || app.navigationBars[text].exists { return true }
        let byLabel = NSPredicate(format: "label == %@", text)
        return app.staticTexts.matching(byLabel).firstMatch.exists
            || app.buttons.matching(byLabel).firstMatch.exists
            || app.menuItems.matching(byLabel).firstMatch.exists
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: 15) == .completed
    }
    private func seconds(_ text: String) -> Double {
        text.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }
}
