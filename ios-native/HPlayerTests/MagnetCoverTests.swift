import XCTest
@testable import HPlayer

final class MagnetCoverTests: XCTestCase {
    func testHighResURLSwapsThumbForCover() {
        let thumb = URL(string: "https://www.javbus.com/pics/thumb/cnbl.jpg")
        XCTAssertEqual(MagnetCover.highResURL(for: thumb)?.absoluteString, "https://www.javbus.com/pics/cover/cnbl_b.jpg")
        let cdn = URL(string: "https://pics.example.com/pics/thumb/9jsw.jpg")
        XCTAssertEqual(MagnetCover.highResURL(for: cdn)?.absoluteString, "https://pics.example.com/pics/cover/9jsw_b.jpg")
    }

    func testHighResURLLeavesOtherAddressesAlone() {
        XCTAssertNil(MagnetCover.highResURL(for: nil))
        XCTAssertNil(MagnetCover.highResURL(for: URL(string: "https://www.javbus.com/pics/cover/cnbl_b.jpg")))
        XCTAssertNil(MagnetCover.highResURL(for: URL(string: "https://example.com/a.jpg")))
        XCTAssertNil(MagnetCover.highResURL(for: URL(string: "https://www.javbus.com/pics/thumb/cnbl.png")))
    }

    func testCropFollowsTheCoverLayout() {
        // 左背右正的横版封面（800×538）：取右边
        XCTAssertEqual(MagnetCover.crop(for: CGSize(width: 800, height: 538)), .trailing)
        XCTAssertEqual(MagnetCover.crop(for: CGSize(width: 800, height: 536)), .trailing)
        // 竖版单封面（565×800）：整张
        XCTAssertEqual(MagnetCover.crop(for: CGSize(width: 565, height: 800)), .full)
        // 正面位置不固定的版式不裁，回退小图
        XCTAssertNil(MagnetCover.crop(for: CGSize(width: 800, height: 600)))
        XCTAssertNil(MagnetCover.crop(for: CGSize(width: 840, height: 472)))
        XCTAssertNil(MagnetCover.crop(for: CGSize(width: 800, height: 516)))
        XCTAssertNil(MagnetCover.crop(for: .zero))
    }
}
