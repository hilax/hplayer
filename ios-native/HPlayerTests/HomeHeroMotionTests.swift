import XCTest
import CoreGraphics
import UIKit
@testable import HPlayer

final class HomeHeroMotionTests: XCTestCase {
    // MARK: 跟手位置

    func testBothVisiblePagesReportTheSameFractionalPosition() throws {
        // A quarter swipe on a 400-point pager, inset 24 points from the window.
        let outgoing = try XCTUnwrap(HeroPagePosition.position(samples: [0: -76], originX: 24, width: 400, count: 3))
        let incoming = try XCTUnwrap(HeroPagePosition.position(samples: [1: 324], originX: 24, width: 400, count: 3))
        XCTAssertEqual(outgoing, 0.25, accuracy: 0.001)
        XCTAssertEqual(incoming, outgoing, accuracy: 0.001)
    }

    func testOverscrollStaysOnTheFirstOrLastPage() throws {
        XCTAssertEqual(try XCTUnwrap(HeroPagePosition.position(samples: [0: 80], originX: 0, width: 400, count: 3)), 0)
        XCTAssertEqual(try XCTUnwrap(HeroPagePosition.position(samples: [2: -80], originX: 0, width: 400, count: 3)), 2)
    }

    func testBackdropSwitchesOnlyAfterTheDragPassesHalfway() {
        let state = HeroMotionState()
        state.update(samples: [0: -160, 1: 240], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.position ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(state.settledIndex, 0, "Less than half a page keeps the current colour")

        state.update(samples: [0: -220, 1: 180], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.settledIndex, 1, "Past halfway the next page's colour takes over before release")

        // Dragging back and letting go returns to the first page and its colour.
        state.update(samples: [0: 0, 1: 400], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.position, 0)
        XCTAssertEqual(state.settledIndex, 0)
    }

    func testSelectionDrivesTheBackdropOnlyUntilPagesReportTheirPosition() {
        let state = HeroMotionState()
        state.follow(selection: 2)
        XCTAssertEqual(state.settledIndex, 2)

        state.update(samples: [1: 0], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.settledIndex, 1)
        // A late selection update must not pull the colour back once geometry is known.
        state.follow(selection: 2)
        XCTAssertEqual(state.settledIndex, 1)

        state.reset(to: 0)
        XCTAssertNil(state.position)
        XCTAssertEqual(state.settledIndex, 0)
    }

    func testInvalidOrOffscreenGeometryKeepsTheCurrentPage() {
        let state = HeroMotionState()
        state.reset(to: 1)
        state.update(samples: [0: -800, 2: 800], originX: 0, width: 400, count: 3)
        XCTAssertNil(state.position)
        XCTAssertEqual(state.settledIndex, 1)
        state.update(samples: [0: 0], originX: 0, width: 0, count: 3)
        state.update(samples: [0: .nan], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.settledIndex, 1)
        XCTAssertNil(HeroPagePosition.position(samples: [:], originX: 0, width: 400, count: 0))
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

    func testNoFeaturedArtworkKeepsThePlainPageBackground() {
        let palette = HeroPalette()
        XCTAssertEqual(palette.tint(items: [], index: 0), .plain)
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
