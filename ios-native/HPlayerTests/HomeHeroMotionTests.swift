import XCTest
@testable import HPlayer

final class HomeHeroMotionTests: XCTestCase {
    func testBothVisiblePagesReportTheSameFractionalPosition() throws {
        // A quarter swipe on a 400-point pager, inset 24 points from the window.
        let outgoing = try XCTUnwrap(HeroBlend.position(samples: [0: -76], originX: 24, width: 400, count: 3))
        let incoming = try XCTUnwrap(HeroBlend.position(samples: [1: 324], originX: 24, width: 400, count: 3))
        XCTAssertEqual(outgoing, 0.25, accuracy: 0.001)
        XCTAssertEqual(incoming, outgoing, accuracy: 0.001)
    }

    func testOverscrollStaysOnTheFirstOrLastArtwork() throws {
        XCTAssertEqual(try XCTUnwrap(HeroBlend.position(samples: [0: 80], originX: 0, width: 400, count: 3)), 0)
        XCTAssertEqual(try XCTUnwrap(HeroBlend.position(samples: [2: -80], originX: 0, width: 400, count: 3)), 2)
        let only = HeroBlend(position: 10, count: 1)
        XCTAssertEqual(only.lower, 0)
        XCTAssertEqual(only.upper, 0)
        XCTAssertEqual(only.fraction, 0)
    }

    func testCancelledSwipeReturnsToTheOriginalBackdrop() {
        let state = HeroMotionState()
        state.update(samples: [0: -160, 1: 240], originX: 0, width: 400, count: 3)
        let partial = HeroBlend(position: state.position ?? -1, count: 3)
        XCTAssertEqual(partial.lower, 0)
        XCTAssertEqual(partial.upper, 1)
        XCTAssertGreaterThan(partial.fraction, 0)
        XCTAssertLessThan(partial.fraction, 0.5)

        state.update(samples: [0: 0, 1: 400], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.position, 0)
        XCTAssertEqual(HeroBlend(position: state.position ?? -1, count: 3).fraction, 0)
    }

    func testTheNextPageBecomesTheOpaqueBaseWithoutAColorDip() {
        let before = HeroBlend(position: 0.9999, count: 3)
        let after = HeroBlend(position: 1, count: 3)
        XCTAssertEqual(before.upper, after.lower)
        XCTAssertEqual(before.fraction, 1, accuracy: 0.0001)
        XCTAssertEqual(after.fraction, 0)
    }

    func testInvalidOrOffscreenGeometryDoesNotResetTheBackdrop() {
        let state = HeroMotionState()
        state.reset(to: 1)
        state.update(samples: [0: -800, 2: 800], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.position, 1)
        state.update(samples: [0: 0], originX: 0, width: 0, count: 3)
        XCTAssertEqual(state.position, 1)
        state.update(samples: [0: .nan], originX: 0, width: 400, count: 3)
        XCTAssertEqual(state.position, 1)
        XCTAssertNil(HeroBlend.position(samples: [:], originX: 0, width: 400, count: 0))
    }
}
