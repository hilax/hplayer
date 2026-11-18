import CoreFoundation
import CoreGraphics
import CoreText
import CryptoKit
import XCTest
@testable import HPlayer

final class OnlineSubtitleTests: XCTestCase {
    func testSubtitleQueryBuilderHandlesMoviesSeriesAndAVCodes() {
        let movieURL = URL(string: "https://example.com/The.Martian.2015.1080p.BluRay.x264.mkv")!
        let movie = SubtitleQueryBuilder.build(rawTitle: "火星救援 The.Martian.2015.1080p.BluRay.mkv", streamURL: movieURL)
        XCTAssertFalse(movie.isAdultVideo)
        XCTAssertNil(movie.avCatalogCode)
        XCTAssertTrue(movie.xunleiQueries.contains("火星救援"))
        XCTAssertTrue(movie.xunleiQueries.contains("The Martian"))

        let animeURL = URL(string: "https://example.com/ep08.m3u8")!
        let anime = SubtitleQueryBuilder.build(rawTitle: "葬送的芙莉莲 第08集", streamURL: animeURL)
        XCTAssertFalse(anime.isAdultVideo)
        XCTAssertEqual(anime.parsed.episode, 8)
        XCTAssertTrue(anime.xunleiQueries.contains("葬送的芙莉莲 E08"))

        // 标准有码番号
        let ssis = SubtitleQueryBuilder.build(
            rawTitle: "[hhd800.com]SSIS-001.1080p.mp4",
            streamURL: URL(string: "https://example.com/video.mp4")!
        )
        XCTAssertTrue(ssis.isAdultVideo)
        XCTAssertEqual(ssis.avCatalogCode, "SSIS-001")
        XCTAssertEqual(ssis.xunleiQueries, ["SSIS-001"])

        let abf = SubtitleQueryBuilder.build(
            rawTitle: "abf-159ch.mp4",
            streamURL: URL(string: "https://example.com/video.mp4")!
        )
        XCTAssertEqual(abf.avCatalogCode, "ABF-159")

        // FC2 / HEYZO / Jable videoId 兜底识别
        let fc2 = SubtitleQueryBuilder.build(
            rawTitle: "fc2ppv-4526925.mp4",
            streamURL: URL(string: "https://example.com/video.mp4")!
        )
        XCTAssertTrue(fc2.isAdultVideo)
        XCTAssertEqual(fc2.avCatalogCode, "FC2-PPV-4526925")

        let heyzo = SubtitleQueryBuilder.extractAVCode(from: "HEYZO_1234_HD.mp4")
        XCTAssertEqual(heyzo, "HEYZO-1234")

        let jable = SubtitleQueryBuilder.build(
            rawTitle: "中文字幕 高清无码流出",
            streamURL: URL(string: "https://example.com/index.m3u8")!,
            fallbackIdentifier: "ipx-343-chinese-subtitle",
            isAdultHint: true
        )
        XCTAssertTrue(jable.isAdultVideo)
        XCTAssertEqual(jable.avCatalogCode, "IPX-343")
    }

    func testFingerprintMatchesBetweenLocalFileAndHTTPRangeStream() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-sub-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 生成 256 KiB 确定性测试数据
        let totalSize = 262_144
        var payload = Data(count: totalSize)
        payload.withUnsafeMutableBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for idx in 0..<totalSize {
                bytes[idx] = UInt8((idx &* 31 &+ 17) & 0xFF)
            }
        }
        let localURL = dir.appendingPathComponent("sample.mkv")
        try payload.write(to: localURL)

        let localFP = await VideoSubtitleFingerprint.compute(localFileURL: localURL)
        let unwrappedLocal = try XCTUnwrap(localFP)
        XCTAssertEqual(unwrappedLocal.fileSize, Int64(totalSize))
        XCTAssertEqual(unwrappedLocal.xunleiCID?.count, 40)
        XCTAssertEqual(unwrappedLocal.shooterHash?.split(separator: ";").count, 4)
        XCTAssertEqual(unwrappedLocal.openSubHash?.count, 16)

        // 验证通过 HTTP Range 获取的数据算出完全相同的三组指纹
        RoutedURLProtocol.install { request in
            guard let rangeHeader = request.value(forHTTPHeaderField: "Range"),
                  rangeHeader.hasPrefix("bytes=") else {
                return RoutedURLProtocol.Reply(status: 200, headers: [:], body: payload)
            }
            let bounds = rangeHeader.dropFirst(6).split(separator: "-")
            let start = Int(bounds[0]) ?? 0
            let end = min(totalSize - 1, Int(bounds[1]) ?? (totalSize - 1))
            let slice = payload.subdata(in: start..<(end + 1))
            return RoutedURLProtocol.Reply(
                status: 206,
                headers: ["Content-Range": "bytes \(start)-\(end)/\(totalSize)"],
                body: slice
            )
        }

        let streamURL = try XCTUnwrap(URL(string: "http://127.0.0.1:9999/v/1/sample.mkv"))
        let remoteFP = await VideoSubtitleFingerprint.compute(
            streamURL: streamURL,
            knownFileSize: Int64(totalSize),
            session: RoutedURLProtocol.session()
        )
        XCTAssertEqual(remoteFP, unwrappedLocal)

        // 小文件与 HLS 清单不应产出文件哈希
        let tinyURL = dir.appendingPathComponent("tiny.mp4")
        try Data(repeating: 0x22, count: 4096).write(to: tinyURL)
        let tinyFP = await VideoSubtitleFingerprint.compute(localFileURL: tinyURL)
        XCTAssertNil(tinyFP)

        let hlsFP = await VideoSubtitleFingerprint.compute(
            streamURL: URL(string: "https://example.com/live/index.m3u8")!,
            session: RoutedURLProtocol.session()
        )
        XCTAssertNil(hlsFP)
    }

    func testSubtitleTextDecoderHandlesGB18030UTF16AndRejectsHTML() throws {
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + Data("1\n00:00:01,000 --> 00:00:03,000\n你好世界\n".utf8)
        let decodedUTF8 = try XCTUnwrap(SubtitleTextDecoder.decode(utf8BOM))
        XCTAssertFalse(decodedUTF8.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(decodedUTF8.contains("你好世界"))

        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        let srtSample = "1\r\n00:01:02,000 --> 00:01:05,000\r\n简体中文字幕测试\r\n"
        let gbData = try XCTUnwrap(srtSample.data(using: gbEncoding))
        let decodedGB = try XCTUnwrap(SubtitleTextDecoder.decode(gbData))
        XCTAssertTrue(decodedGB.contains("简体中文字幕测试"))

        let assSample = "\u{FEFF}[Script Info]\nTitle: Test\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,测试对话"
        let utf16Data = try XCTUnwrap(assSample.data(using: .utf16LittleEndian))
        let decodedUTF16 = try XCTUnwrap(SubtitleTextDecoder.decode(utf16Data))
        XCTAssertTrue(decodedUTF16.contains("[Script Info]"))

        let htmlError = Data("<!DOCTYPE html><html><body>404 Not Found</body></html>".utf8)
        XCTAssertNil(SubtitleTextDecoder.decode(htmlError))

        let zipMagic = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])
        XCTAssertNil(SubtitleTextDecoder.decode(zipMagic))
    }

    func testMultiSourceSearchRanksHashAndChineseSubtitlesHighest() async throws {
        RoutedURLProtocol.install { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("api-shoulei-ssl.xunlei.com") {
                if url.contains("cid=AABBCCDDEEFF") {
                    return .json([
                        "code": 0,
                        "data": [[
                            "url": "https://cdn.example.com/matched-hash.ass",
                            "ext": "ass",
                            "name": "The.Martian.2015.BluRay.chs.ass",
                            "simple_name": "简体[ASS]火星救援",
                            "duration": 8_200_000,
                            "languages": ["简体"],
                        ]],
                    ])
                }
                return .json([
                    "code": 0,
                    "data": [[
                        "url": "https://cdn.example.com/by-name.srt",
                        "ext": "srt",
                        "name": "The.Martian.2015.srt",
                        "simple_name": "繁体[SRT]火星救援",
                        "duration": 8_198_000,
                        "languages": ["繁体"],
                    ]],
                ])
            }
            if url.contains("shooter.cn") {
                return .json([[
                    "Desc": "Shooter Sub",
                    "Delay": 0,
                    "Files": [["Ext": "srt", "Link": "https://cdn.example.com/shooter.srt"]],
                ]])
            }
            if url.contains("v3-cinemeta.strem.io") {
                return .json(["metas": [["id": "tt3659388", "imdb_id": "tt3659388", "name": "The Martian"]]])
            }
            if url.contains("opensubtitles-v3.strem.io") {
                return .json([
                    "subtitles": [
                        [
                            "id": "101",
                            "url": "https://cdn.example.com/opensub-en.srt",
                            "lang": "eng",
                            "subtitleFileName": "The.Martian.2015.en.srt",
                        ],
                        [
                            "id": "102",
                            "url": "https://cdn.example.com/opensub-zh.srt",
                            "lang": "zho",
                            "subtitleFileName": "The.Martian.2015.zh-hans.srt",
                        ],
                    ],
                ])
            }
            if url == "https://cdn.example.com/matched-hash.ass" {
                let ass = "[Script Info]\nTitle: Matched\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,哈希命中"
                return RoutedURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/plain"], body: Data(ass.utf8))
            }
            return RoutedURLProtocol.Reply(status: 404)
        }

        let service = OnlineSubtitleService(
            session: RoutedURLProtocol.session(),
            enabledSourcesProvider: { OnlineSubtitleSource.allCases }
        )
        let context = OnlineSubtitleContext(
            rawTitle: "The.Martian.2015.1080p.BluRay.mkv",
            streamURL: URL(string: "https://example.com/The.Martian.2015.1080p.BluRay.mkv")!,
            durationSeconds: 8200
        )
        let fingerprint = VideoSubtitleFingerprint(
            fileSize: 2_000_000_000,
            xunleiCID: "AABBCCDDEEFF",
            shooterHash: "111;222;333;444",
            openSubHash: "0123456789abcdef"
        )

        let result = await service.search(context: context, fingerprint: fingerprint)
        XCTAssertGreaterThanOrEqual(result.candidates.count, 4)

        let top = try XCTUnwrap(OnlineSubtitleService.autoPick(from: result.candidates))
        XCTAssertEqual(top.source, .xunlei)
        XCTAssertTrue(top.matchedByHash)
        XCTAssertEqual(top.downloadURL.absoluteString, "https://cdn.example.com/matched-hash.ass")

        let downloaded = await service.downloadSubtitleText(from: top)
        XCTAssertTrue(downloaded?.contains("哈希命中") == true)
    }

    func testAVCatalogSearchParsesSubtitleCatAndSpaceEncodedDownloadLinks() async throws {
        RoutedURLProtocol.install { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("subtitlecat.com/index.php") {
                let html = """
                <table class="table sub-table"><tbody>
                <tr>
                    <td><a href="subs/1707/ssis-001-zhTW.html">ssis-001-zhTW</a> (translated from Chinese)</td>
                    <td>👍</td>
                    <td><span>12<span class="sub-table__metric-unit"> downloads</span></span></td>
                </tr>
                <tr>
                    <td><a href="subs/999/unrelated-movie.html">Unrelated Movie</a></td>
                    <td></td>
                    <td><span>50<span class="sub-table__metric-unit"> downloads</span></span></td>
                </tr>
                </tbody></table>
                """
                return RoutedURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/html"], body: Data(html.utf8))
            }
            if url.contains("subtitlecat.com/subs/1707/ssis-001-zhTW.html") {
                // 故意包含空格路径，验证百分号安全拼接逻辑
                let detail = """
                <a id="download_zh-CN" href="/subs/1750/ssis-001 zhTW-zh-CN.srt" class="green-link">Download</a>
                <a id="download_zh-TW" href="/subs/1707/ssis-001 zhTW-zh-TW.srt" class="green-link">Download</a>
                """
                return RoutedURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/html"], body: Data(detail.utf8))
            }
            if url.contains("api-shoulei-ssl.xunlei.com") {
                return .json(["code": 0, "data": []])
            }
            if url == "https://www.subtitlecat.com/subs/1750/ssis-001%20zhTW-zh-CN.srt" {
                let srt = "1\n00:00:05,000 --> 00:00:08,000\n中文字幕匹配成功\n"
                return RoutedURLProtocol.Reply(status: 200, headers: ["Content-Type": "text/plain"], body: Data(srt.utf8))
            }
            return RoutedURLProtocol.Reply(status: 404)
        }

        let service = OnlineSubtitleService(
            session: RoutedURLProtocol.session(),
            enabledSourcesProvider: { OnlineSubtitleSource.allCases }
        )
        let context = OnlineSubtitleContext(
            rawTitle: "[98t.tv]SSIS-001.mp4",
            streamURL: URL(string: "https://example.com/index.m3u8")!,
            fallbackIdentifier: "ssis-001",
            isAdultVideo: true
        )

        let result = await service.search(context: context, fingerprint: nil)
        XCTAssertEqual(result.query, "SSIS-001")
        XCTAssertEqual(result.candidates.count, 2, "不相关影片应被过滤，仅保留 SSIS-001 简繁两条")
        XCTAssertFalse(
            RoutedURLProtocol.requests().contains { ($0.url?.absoluteString ?? "").contains("opensubtitles-v3") },
            "AV 番号视频不应浪费请求去查 OpenSubtitles"
        )

        let best = try XCTUnwrap(OnlineSubtitleService.autoPick(from: result.candidates))
        XCTAssertEqual(best.source, .subtitlecat)
        XCTAssertEqual(best.languageLabel, "简体中文")

        let text = await service.downloadSubtitleText(from: best)
        XCTAssertTrue(text?.contains("中文字幕匹配成功") == true)
    }

    @MainActor
    func testCacheAndPlaybackControllerSubtitleDelaySync() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-sub-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = OnlineSubtitleCache(directory: dir)
        let candidate = OnlineSubtitleCandidate(
            id: "test|1",
            title: "Test.srt",
            languageLabel: "简体中文",
            format: "srt",
            source: .subtitlecat,
            downloadURL: URL(string: "https://example.com/test.srt")!,
            matchedByHash: false,
            durationSeconds: nil,
            score: 100
        )
        let savedURL = try XCTUnwrap(cache.saveSubtitleText("1\n00:00:01,000 --> 00:00:02,000\nOK\n", for: candidate))
        XCTAssertEqual(cache.cachedFileCount, 1)

        let videoKey = "sid|p115:abc"
        cache.rememberSelection(candidate, fileURL: savedURL, delaySeconds: 1.5, for: videoKey)
        let restored = try XCTUnwrap(cache.savedSelection(for: videoKey))
        XCTAssertEqual(restored.selection.delaySeconds, 1.5, accuracy: 0.01)
        XCTAssertEqual(restored.fileURL.lastPathComponent, savedURL.lastPathComponent)

        cache.clearAll()
        XCTAssertEqual(cache.cachedFileCount, 0)
        XCTAssertNil(cache.savedSelection(for: videoKey))

        let player = PlaybackController()
        player.open(URL(string: "https://example.com/movie.mkv")!, autoRecover: false, title: "SSIS-001.mp4")
        XCTAssertEqual(player.subtitleDelayLabel, "0.0s")
        player.nudgeSubtitleDelay(by: 0.5)
        XCTAssertEqual(player.subtitleDelay, 0.5, accuracy: 0.01)
        XCTAssertEqual(player.subtitleDelayLabel, "+0.5s")
        player.nudgeSubtitleDelay(by: -1.0)
        XCTAssertEqual(player.subtitleDelay, -0.5, accuracy: 0.01)
        XCTAssertEqual(player.subtitleDelayLabel, "-0.5s")
        player.setSubtitleDelay(120)
        XCTAssertEqual(player.subtitleDelay, 60, accuracy: 0.01)
        player.resetSubtitleDelay()
        XCTAssertEqual(player.subtitleDelay, 0, accuracy: 0.01)
        XCTAssertEqual(player.subtitleDelayLabel, "0.0s")
    }

    func testBundledCJKFontIsIsolatedAndCoversChineseAndJapaneseGlyphs() throws {
        let bundledURL = try XCTUnwrap(SubtitleFontManager.bundledFontURL(in: .main), "应用包内必须包含 NotoSansSC-Regular.otf")
        let size = try XCTUnwrap((try? bundledURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
        XCTAssertGreaterThan(size, 1_000_000)

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-font-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 预先写入杂项文件，验证隔离字体目录仅保留目标字体避免 libass 误扫
        let strayDir = tempRoot.appendingPathComponent(SubtitleFontManager.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: strayDir.appendingPathComponent("unrelated.txt"))

        let preparedDir = try XCTUnwrap(SubtitleFontManager.prepareSubtitleFontDirectory(in: .main, cacheRoot: tempRoot))
        let items = try FileManager.default.contentsOfDirectory(atPath: preparedDir.path)
        XCTAssertEqual(items, ["\(SubtitleFontManager.bundledFontFileName).\(SubtitleFontManager.bundledFontExtension)"])

        let provider = try XCTUnwrap(CGDataProvider(url: preparedDir.appendingPathComponent(items[0]) as CFURL))
        let cgFont = try XCTUnwrap(CGFont(provider))
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 24, nil, nil)

        let sampleChars = Array("你好世界繁體中文電影字幕あいうえおカキクケコABC123".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: sampleChars.count)
        let allMapped = CTFontGetGlyphsForCharacters(ctFont, sampleChars, &glyphs, sampleChars.count)
        XCTAssertTrue(allMapped, "内置字体应完整覆盖简体、繁体、日文假名与英数字形，不得出现缺字方框")
    }

    func testDecoderDisambiguatesBig5NoBOMUTF16AndSanitizesASS() throws {
        // 1. 验证 Big5 繁体字幕不被 GB18030 超集吞掉而产出乱码
        let big5Encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        )
        let traditionalSample = "1\r\n00:00:01,000 --> 00:00:04,000\r\n這就是繁體中文電影字幕測試，聽見嗎？\r\n"
        let big5Data = try XCTUnwrap(traditionalSample.data(using: big5Encoding))
        let decodedBig5 = try XCTUnwrap(SubtitleTextDecoder.decode(big5Data))
        XCTAssertTrue(decodedBig5.contains("這就是繁體中文電影字幕測試"), "实际输出: \(decodedBig5)")

        // 2. 验证无 BOM 的 UTF-16LE 不会落入 .utf8 混入 \0
        let rawUTF16 = "1\n00:00:02,000 --> 00:00:05,000\n无BOM测试ABC\n"
        let noBOMData = try XCTUnwrap(rawUTF16.data(using: .utf16LittleEndian))
        let decodedNoBOM = try XCTUnwrap(SubtitleTextDecoder.decode(noBOMData))
        XCTAssertFalse(decodedNoBOM.contains("\u{0000}"))
        XCTAssertTrue(decodedNoBOM.contains("无BOM测试ABC"))

        // 3. 验证 ASS 清理 [Fonts]/[Graphics]、桌面缺失字体替换为 Noto Sans SC 以及超重模糊限幅
        let heavyASS = """
        [Script Info]
        Title: Heavy
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, Alignment
        Style: Default,微软雅黑,20,&H00FFFFFF,2
        Style: Eng,Arial,14,&H00CCCCCC,2
        [Fonts]
        fontname: broken-win.ttf
        AABBCCDDEEFFGG
        [Graphics]
        filename: logo.png
        00112233
        [Events]
        Format: Layer, Start, End, Style, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,{\\fn方正黑体\\blur18\\fs22}测试对话
        """
        let clean = SubtitleTextDecoder.sanitizeForPlayback(heavyASS, format: "ass")
        XCTAssertFalse(clean.contains("[Fonts]"))
        XCTAssertFalse(clean.contains("[Graphics]"))
        XCTAssertFalse(clean.contains("AABBCCDDEEFFGG"))
        XCTAssertFalse(clean.contains("微软雅黑"))
        XCTAssertFalse(clean.contains("Arial"))
        XCTAssertFalse(clean.contains("方正黑体"))
        XCTAssertTrue(clean.contains("Style: Default,Noto Sans SC,20,&H00FFFFFF,2"))
        XCTAssertTrue(clean.contains("Style: Eng,Noto Sans SC,14,&H00CCCCCC,2"))
        XCTAssertTrue(clean.contains(#"{\fnNoto Sans SC\blur4\fs22}测试对话"#), "实际输出: \(clean)")
    }

    @MainActor
    func testCacheMigrationAndRemoteStreamFingerprintGuard() throws {
        // 验证旧缓存（无 .format-v2 标记）会清理旧字幕文件但保留用户字幕同步偏移 delays
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hplayer-cache-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("stale ass".utf8).write(to: dir.appendingPathComponent("old.ass"))
        let savedDelays = try JSONEncoder().encode(["sid|115:test": -1.2])
        try savedDelays.write(to: dir.appendingPathComponent("delays.json"))

        let cache = OnlineSubtitleCache(directory: dir)
        XCTAssertEqual(cache.cachedFileCount, 0)
        XCTAssertEqual(cache.savedDelay(for: "sid|115:test") ?? 0, -1.2, accuracy: 0.01)

        // 验证只有本地 file:// URL 会发起指纹读取，HTTP/本地代理流不触发并发 Range 请求
        XCTAssertTrue(PlaybackController.shouldComputeSubtitleFingerprint(for: URL(fileURLWithPath: "/tmp/movie.mkv")))
        XCTAssertFalse(PlaybackController.shouldComputeSubtitleFingerprint(for: URL(fileURLWithPath: "/tmp/movie.mkv"), skipRemoteHash: true))
        XCTAssertFalse(PlaybackController.shouldComputeSubtitleFingerprint(for: URL(string: "http://127.0.0.1:18080/stream/115")!))
        XCTAssertFalse(PlaybackController.shouldComputeSubtitleFingerprint(for: URL(string: "https://cdn.example.com/movie.mkv")!))

        // 验证字幕视觉观感调优参数：稍微增大基础字号、上移底边距、彻底修复透明底因 sub-blur 发虚
        let baseScale = try XCTUnwrap(Double(SubtitleStyle.defaultSubScale))
        let largeScale = try XCTUnwrap(Double(SubtitleStyle.large.overrides["sub-scale"] ?? ""))
        XCTAssertGreaterThan(baseScale, 1.05)
        XCTAssertGreaterThan(largeScale, baseScale)
        XCTAssertLessThan(try XCTUnwrap(Int(SubtitleStyle.defaultSubPos)), 100)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(Int(SubtitleStyle.defaultSubMarginY)), 34)
        XCTAssertEqual(SubtitleStyle.soft.overrides["sub-blur"], "0", "透明底不得启用 sub-blur，避免无粗描边时将文字本体高斯模糊")
        XCTAssertNotNil(SubtitleStyle.soft.overrides["sub-shadow-offset"])
    }
}
