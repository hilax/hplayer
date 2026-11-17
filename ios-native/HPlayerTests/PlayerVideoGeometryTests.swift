import XCTest
@testable import HPlayer

/// 播放画面的摆放：竖屏时画面要铺满小窗（以前只有 82% 宽，上下还露出垫在下面的小窗图层），
/// 小窗的高度跟着视频比例走；横屏保持原样。
final class PlayerVideoGeometryTests: XCTestCase {
    /// iPhone 15 Pro：横放 852×393，画面图层固定是这个大小
    private let canvas = CGSize(width: 852, height: 393)
    private let portrait = CGSize(width: 393, height: 852)

    private func inlineBox(_ aspect: CGFloat?) -> CGSize {
        CGSize(width: portrait.width,
               height: PlayerVideoGeometry.inlineHeight(width: portrait.width, screenHeight: portrait.height, aspect: aspect))
    }

    func testLandscapeKeepsTheCanvasAtFullSize() {
        for aspect: CGFloat? in [nil, 16.0 / 9.0, 4.0 / 3.0, 2.35, 1, 9.0 / 16.0, 21.0 / 9.0] {
            for stretch in [false, true] {
                let placement = PlayerVideoGeometry.placement(canvas: canvas, container: canvas, aspect: aspect, stretch: stretch)
                XCTAssertEqual(placement.scaleX, 1, accuracy: 0.0001, "aspect=\(String(describing: aspect)) stretch=\(stretch)")
                XCTAssertEqual(placement.scaleY, 1, accuracy: 0.0001, "aspect=\(String(describing: aspect)) stretch=\(stretch)")
            }
        }
    }

    func testWidescreenVideoFillsThePortraitFrame() {
        let box = inlineBox(16.0 / 9.0)
        XCTAssertEqual(box.height, 393 * 9.0 / 16.0, accuracy: 0.5, "A 16:9 video gets a 16:9 frame")
        let placement = PlayerVideoGeometry.placement(canvas: canvas, container: box, aspect: 16.0 / 9.0, stretch: false)
        // 以前是 393 / 852 = 0.461：画面只有 322pt 宽
        XCTAssertEqual(placement.scaleX, 0.5625, accuracy: 0.002)
        XCTAssertEqual(placement.scaleX, placement.scaleY)
        XCTAssertGreaterThanOrEqual(placement.shownSize.width, box.width - 0.01, "No bars left and right")
        XCTAssertGreaterThanOrEqual(placement.shownSize.height, box.height - 0.01, "Nothing shows above or below the picture")
        XCTAssertLessThan(placement.shownSize.width, box.width * 1.01, "Only a sub-pixel sliver may be cropped")
        XCTAssertLessThan(placement.shownSize.height, box.height * 1.01)
    }

    func testUnknownAspectIsLaidOutAsWidescreen() {
        XCTAssertEqual(inlineBox(nil), inlineBox(16.0 / 9.0))
        XCTAssertEqual(PlayerVideoGeometry.placement(canvas: canvas, container: inlineBox(nil), aspect: nil, stretch: false),
                       PlayerVideoGeometry.placement(canvas: canvas, container: inlineBox(nil), aspect: 16.0 / 9.0, stretch: false))
        XCTAssertEqual(inlineBox(0), inlineBox(nil), "A bogus aspect falls back to 16:9")
        XCTAssertEqual(inlineBox(.nan), inlineBox(nil))
    }

    func testTallerVideosGetATallerFrame() {
        let fourThirds = inlineBox(4.0 / 3.0)
        XCTAssertEqual(fourThirds.height, 393 * 0.75, accuracy: 0.5)
        let placement = PlayerVideoGeometry.placement(canvas: canvas, container: fourThirds, aspect: 4.0 / 3.0, stretch: false)
        XCTAssertEqual(placement.shownSize.width, 393, accuracy: 0.5)
        XCTAssertEqual(placement.shownSize.height, fourThirds.height, accuracy: 0.5)

        XCTAssertEqual(inlineBox(1).height, 393, accuracy: 0.5, "A square video gets a square frame")
    }

    func testVerticalVideoStopsAtASquareFrameAndIsNotUpscaled() {
        let box = inlineBox(9.0 / 16.0)
        XCTAssertEqual(box.height, 393, accuracy: 0.5, "The frame never grows past a square")
        let placement = PlayerVideoGeometry.placement(canvas: canvas, container: box, aspect: 9.0 / 16.0, stretch: false)
        XCTAssertEqual(placement.scaleX, 1, accuracy: 0.001)
        XCTAssertEqual(placement.shownSize.height, 393, accuracy: 0.5)
        XCTAssertEqual(placement.shownSize.width, 393 * 9.0 / 16.0, accuracy: 0.5, "Pillarboxed inside the square")
    }

    func testVeryWideVideoIsLetterboxedInsideAWidescreenFrame() {
        let box = inlineBox(2.35)
        XCTAssertEqual(box.height, 393 * 9.0 / 16.0, accuracy: 0.5, "The frame never gets flatter than 16:9")
        let placement = PlayerVideoGeometry.placement(canvas: canvas, container: box, aspect: 2.35, stretch: false)
        XCTAssertEqual(placement.shownSize.width, 393, accuracy: 0.5)
        XCTAssertEqual(placement.shownSize.height, 393 / 2.35, accuracy: 0.5)
    }

    /// 画面图层只有屏幕短边那么高：任何比例在竖屏里都不需要放大（放大会发虚）
    func testPortraitNeverUpscalesTheCanvas() {
        for aspect: CGFloat in [0.4, 9.0 / 16.0, 0.75, 1, 1.2, 4.0 / 3.0, 1.6, 16.0 / 9.0, 1.85, 2.0, 2.35, 2.76, 3.5] {
            let box = inlineBox(aspect)
            let placement = PlayerVideoGeometry.placement(canvas: canvas, container: box, aspect: aspect, stretch: false)
            XCTAssertLessThanOrEqual(placement.scaleX, 1.0001, "aspect=\(aspect)")
            XCTAssertLessThanOrEqual(placement.shownSize.width, box.width * 1.01, "aspect=\(aspect)")
            XCTAssertLessThanOrEqual(placement.shownSize.height, box.height * 1.01, "aspect=\(aspect)")
            // 视频那一块一定被整块画面图层盖住（垫在下面的小窗图层就不会露出来）
            XCTAssertLessThanOrEqual(placement.pictureSize.width, canvas.width + 0.001)
            XCTAssertLessThanOrEqual(placement.pictureSize.height, canvas.height + 0.001)
            // 而且至少有一边顶到小窗的边
            let touchesWidth = abs(placement.shownSize.width - box.width) < box.width * 0.011
            let touchesHeight = abs(placement.shownSize.height - box.height) < box.height * 0.011
            XCTAssertTrue(touchesWidth || touchesHeight, "aspect=\(aspect) shown=\(placement.shownSize) box=\(box)")
        }
    }

    func testStretchMapsTheWholeCanvasOntoTheFrame() {
        let box = inlineBox(16.0 / 9.0)
        let placement = PlayerVideoGeometry.placement(canvas: canvas, container: box, aspect: 16.0 / 9.0, stretch: true)
        XCTAssertEqual(placement.pictureSize, canvas)
        XCTAssertEqual(placement.shownSize.width, box.width, accuracy: 0.01)
        XCTAssertEqual(placement.shownSize.height, box.height, accuracy: 0.01)
    }

    func testFrameHeightIsCappedOnTallScreensAndNeverFlatterThanWidescreen() {
        // iPad 竖屏：正方形太大，最多半屏
        let pad = PlayerVideoGeometry.inlineHeight(width: 820, screenHeight: 1180, aspect: 1)
        XCTAssertEqual(pad, 590, accuracy: 0.5)
        XCTAssertEqual(PlayerVideoGeometry.inlineHeight(width: 820, screenHeight: 1180, aspect: 16.0 / 9.0), 820 * 9.0 / 16.0, accuracy: 0.5)
        // 屏幕很矮时也不低于 16:9
        XCTAssertEqual(PlayerVideoGeometry.inlineHeight(width: 400, screenHeight: 300, aspect: 1), 225, accuracy: 0.5)
    }

    func testRotationTargetsTheInlineFrameInPortraitAndTheWholeWindowInLandscape() {
        XCTAssertEqual(PlayerVideoGeometry.container(afterTransitionTo: canvas, aspect: 4.0 / 3.0), canvas)
        XCTAssertEqual(PlayerVideoGeometry.container(afterTransitionTo: portrait, aspect: 4.0 / 3.0), inlineBox(4.0 / 3.0))
        XCTAssertEqual(PlayerVideoGeometry.container(afterTransitionTo: portrait, aspect: nil), inlineBox(nil))
        // 已经是小窗大小（宽不小于高）时原样返回
        let box = inlineBox(16.0 / 9.0)
        XCTAssertEqual(PlayerVideoGeometry.container(afterTransitionTo: box, aspect: 16.0 / 9.0), box)
    }

    func testPictureSizeFollowsTheVideoAspect() {
        let wide = PlayerVideoGeometry.pictureSize(aspect: 16.0 / 9.0, in: canvas)
        XCTAssertEqual(wide.height, 393, accuracy: 0.001)
        XCTAssertEqual(wide.width, 393 * 16.0 / 9.0, accuracy: 0.001)
        let scope = PlayerVideoGeometry.pictureSize(aspect: 2.35, in: canvas)
        XCTAssertEqual(scope.width, 852, accuracy: 0.001)
        XCTAssertEqual(scope.height, 852 / 2.35, accuracy: 0.001)
    }
}
