import XCTest
import CoreGraphics
import UIKit
@testable import HPlayer

final class HomeAmbientTintTests: XCTestCase {
    // MARK: 循环

    func testCarouselWrapsBothWays() {
        // a b c → c' a b c a'
        XCTAssertEqual(HeroLoop.pages(["a", "b", "c"]), ["c", "a", "b", "c", "a"])
        XCTAssertEqual(HeroLoop.pages(["a"]), ["a"], "A single artwork does not loop")
        XCTAssertEqual(HeroLoop.page(forReal: 0, count: 3), 1)
        XCTAssertEqual(HeroLoop.real(0, count: 3), 2, "The copy before the first page is the last artwork")
        XCTAssertEqual(HeroLoop.real(4, count: 3), 0, "The copy after the last page is the first artwork")
        XCTAssertEqual(HeroLoop.real(2, count: 3), 1)
        XCTAssertEqual(HeroLoop.wrapTarget(0, count: 3), 3)
        XCTAssertEqual(HeroLoop.wrapTarget(4, count: 3), 1)
        XCTAssertNil(HeroLoop.wrapTarget(2, count: 3))
        XCTAssertNil(HeroLoop.wrapTarget(0, count: 1))
        XCTAssertEqual(HeroLoop.real(0, count: 1), 0)
    }

    // MARK: 封面取色

    func testPageTintKeepsTheHueButCapsBrightnessAndSaturation() {
        // The purple behind "Dancing with the Stars" in the reference video.
        let source = (red: 111.0 / 255, green: 78.0 / 255, blue: 136.0 / 255)
        let purple = ArtworkTint.page(red: source.red, green: source.green, blue: source.blue)
        XCTAssertEqual(max(purple.red, purple.green, purple.blue), ArtworkTint.maxBrightness, accuracy: 0.0001)
        XCTAssertEqual(hue(purple.red, purple.green, purple.blue), hue(source.red, source.green, source.blue), accuracy: 0.5)

        // Already dark enough (the brown behind "Papa"): unchanged.
        let brown = ArtworkTint.page(red: 74.0 / 255, green: 64.0 / 255, blue: 62.0 / 255)
        XCTAssertEqual(brown.red, 74.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(brown.green, 64.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(brown.blue, 62.0 / 255, accuracy: 0.0001)

        // A loud primary colour is toned down instead of filling the page.
        let red = ArtworkTint.page(red: 1, green: 0, blue: 0)
        XCTAssertEqual(red.red, ArtworkTint.maxBrightness, accuracy: 0.0001)
        XCTAssertEqual(red.green / red.red, 1 - ArtworkTint.maxSaturation, accuracy: 0.0001)
        XCTAssertEqual(red.green, red.blue, accuracy: 0.0001)

        XCTAssertEqual(ArtworkTint.page(red: 0, green: 0, blue: 0), ArtworkTint(red: 0, green: 0, blue: 0))
        let grey = ArtworkTint.page(red: 0.9, green: 0.9, blue: 0.9)
        XCTAssertEqual(grey.red, ArtworkTint.maxBrightness, accuracy: 0.0001)
        XCTAssertEqual(grey.green, grey.blue, accuracy: 0.0001)
    }

    func testAverageColourOnlyCountsWhatTheHeroShows() throws {
        // 200×100 landscape: 50px red on both sides, blue in the middle. A 4:5 hero crop shows only the middle 80px.
        let image = try XCTUnwrap(makeImage(width: 200, height: 100) { x in
            x < 50 || x >= 150 ? (255, 0, 0) : (0, 0, 255)
        })
        let average = try XCTUnwrap(ArtworkTint.averageColor(of: image, aspect: 0.8))
        XCTAssertEqual(average.blue, 1, accuracy: 0.03)
        XCTAssertEqual(average.red, 0, accuracy: 0.03)
        XCTAssertEqual(average.green, 0, accuracy: 0.03)

        // Half-and-half within the visible part averages to the midpoint.
        let split = try XCTUnwrap(makeImage(width: 80, height: 100) { x in x < 40 ? (255, 255, 255) : (0, 0, 0) })
        let grey = try XCTUnwrap(ArtworkTint.averageColor(of: split, aspect: 0.8))
        XCTAssertEqual(grey.red, 0.5, accuracy: 0.06)
        XCTAssertEqual(grey.green, grey.blue, accuracy: 0.01)
    }

    func testNoCarouselKeepsThePlainPageBackground() {
        let palette = HeroPalette()
        XCTAssertEqual(palette.tint(forKey: nil), .plain)
        XCTAssertEqual(palette.tint(forKey: ""), .plain)
        XCTAssertEqual(palette.tint(forKey: "https://example.com/a.jpg"), .pending, "Not measured yet")
    }

    func testPastelKeepsTheHueAndStaysLight() {
        let blue = ArtworkTint(red: 0.08, green: 0.28, blue: 0.35)
        let pastel = blue.pastel
        XCTAssertGreaterThan(min(pastel.red, pastel.green, pastel.blue), 0.5, "Dark text must stay readable on it")
        XCTAssertEqual(hue(pastel.red, pastel.green, pastel.blue), hue(blue.red, blue.green, blue.blue), accuracy: 6)
        XCTAssertGreaterThan(pastel.blue, pastel.red)
        let black = ArtworkTint(red: 0, green: 0, blue: 0).pastel
        XCTAssertEqual(black.red, 0.957, accuracy: 0.001)
    }

    // MARK: 轮播内容与动漫卡片

    func testSlidesAlternateLibraryAndOnlineUntilTheLimit() {
        let banners = (1...3).map { AnimeBanner(id: $0, vid: 100 + $0, img: "https://example.com/\($0).webp", vname: "B\($0)",
                                                 continu: nil, content: nil, gold: nil, oid: nil, pid: nil) }
        XCTAssertEqual(HomeSlide.interleave(featured: [], banners: banners).map(\.id), ["anime|1", "anime|2", "anime|3"])
        XCTAssertEqual(HomeSlide.interleave(featured: [], banners: banners, limit: 2).count, 2)
        XCTAssertTrue(HomeSlide.interleave(featured: [], banners: []).isEmpty)
    }

    func testAnimeCardEpisodeTextReadsEveryFormat() {
        func item(_ continu: String?, total: Int? = nil, isend: Int? = nil) -> AnimeVideoItem {
            AnimeVideoItem(id: 1, name: "x", continu: continu, total: total, isend: isend)
        }
        XCTAssertEqual(AnimeEpisodeText.short(item("28|周四五11:00更")), "更新至 28 集")
        XCTAssertEqual(AnimeEpisodeText.short(item("6#周六23:00更")), "更新至 6 集")
        XCTAssertEqual(AnimeEpisodeText.short(item("更新至26集")), "更新至 26 集")
        XCTAssertEqual(AnimeEpisodeText.short(item("全52集")), "全 52 集")
        XCTAssertEqual(AnimeEpisodeText.short(item("双语 1080P", total: 1, isend: 1)), "全 1 集")
        XCTAssertEqual(AnimeEpisodeText.short(item("抢先版 AI修复")), "抢先版 AI修复")
        XCTAssertNil(AnimeEpisodeText.short(item("一段非常非常长的连载说明文字")))
        XCTAssertNil(AnimeEpisodeText.short(item(nil)))

        XCTAssertEqual(AnimeEpisodeText.status(item("28|周四五11:00更")), .init(title: "更新", highlighted: true))
        XCTAssertEqual(AnimeEpisodeText.status(item("全52集")), .init(title: "完结", highlighted: false))
        XCTAssertEqual(AnimeEpisodeText.status(item("双语", isend: 1)), .init(title: "完结", highlighted: false))
        XCTAssertNil(AnimeEpisodeText.status(item("抢先版 AI修复")))
    }

    // MARK: Helpers

    private func hue(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        _ = UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Double(hue) * 360
    }

    private func makeImage(width: Int, height: Int, color: (Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = color(x)
                let offset = (y * width + x) * 4
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
                pixels[offset + 3] = 255
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
