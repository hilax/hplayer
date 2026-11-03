import XCTest
@testable import HPlayer

/// 快速滑动货架时卡片「消失又冒出来」的回归测试：
/// 懒加载容器会回收滑出屏幕的卡片，浮现状态必须记在视图外面。
final class RevealLedgerTests: XCTestCase {
    func testFirstScreenCardsStartHiddenSoTheyCanFadeInOneByOne() {
        let ledger = RevealLedger()
        for index in 0..<4 {
            XCTAssertTrue(ledger.startsHidden(id: "m\(index)", scope: "shelf", index: index, now: 10),
                          "The first screen plays the staggered reveal")
            ledger.markRevealed(id: "m\(index)", scope: "shelf", index: index, now: 10.02 * Double(index) + 10)
        }
    }

    func testRecycledCardComesBackFullyVisible() {
        let ledger = RevealLedger()
        ledger.markRevealed(id: "m1", scope: "shelf", index: 1, now: 10)
        // 即使还在头半秒里，浮现过的卡片被回收重建后也不能再藏起来。
        XCTAssertFalse(ledger.startsHidden(id: "m1", scope: "shelf", index: 1, now: 10.1))
        XCTAssertFalse(ledger.startsHidden(id: "m1", scope: "shelf", index: 1, now: 30))
        // 第 0 张也一样。
        ledger.markRevealed(id: "m0", scope: "shelf", index: 0, now: 10)
        XCTAssertFalse(ledger.startsHidden(id: "m0", scope: "shelf", index: 0, now: 40))
    }

    func testCardsScrolledInLaterAppearImmediately() {
        let ledger = RevealLedger()
        ledger.markRevealed(id: "m0", scope: "shelf", index: 0, now: 10)
        XCTAssertTrue(ledger.startsHidden(id: "m2", scope: "shelf", index: 2, now: 10.3),
                      "Still inside the first half second")
        XCTAssertFalse(ledger.startsHidden(id: "m3", scope: "shelf", index: 3, now: 10.6),
                       "A card that scrolls into view after the first screen must never be transparent")
        XCTAssertFalse(ledger.startsHidden(id: "m80", scope: "shelf", index: 80, now: 25))
    }

    func testShelvesAndGridsTrackTheirOwnWindows() {
        let ledger = RevealLedger()
        ledger.markRevealed(id: "a0", scope: "movies", index: 0, now: 10)
        XCTAssertFalse(ledger.startsHidden(id: "a3", scope: "movies", index: 3, now: 11))
        // 另一个货架这时才第一次出现，它的第一屏照样浮现。
        XCTAssertTrue(ledger.startsHidden(id: "b1", scope: "series", index: 1, now: 11))
        ledger.markRevealed(id: "b0", scope: "series", index: 0, now: 11)
        XCTAssertTrue(ledger.startsHidden(id: "b2", scope: "series", index: 2, now: 11.2))
        // 同一个 id 在不同货架里互不影响。
        XCTAssertTrue(ledger.startsHidden(id: "a0", scope: "series", index: 1, now: 11.2))
    }

    func testAFreshFirstCardStartsANewScreen() {
        let ledger = RevealLedger()
        ledger.markRevealed(id: "old0", scope: "grid", index: 0, now: 10)
        XCTAssertFalse(ledger.startsHidden(id: "old4", scope: "grid", index: 4, now: 20))

        // 换了筛选：新的第 0 张从没出现过，重新开始计时，它后面的几张照样依次浮现。
        XCTAssertTrue(ledger.startsHidden(id: "new0", scope: "grid", index: 0, now: 20))
        ledger.markRevealed(id: "new0", scope: "grid", index: 0, now: 20)
        XCTAssertTrue(ledger.startsHidden(id: "new1", scope: "grid", index: 1, now: 20.2))
        XCTAssertFalse(ledger.startsHidden(id: "new9", scope: "grid", index: 9, now: 20.7))
    }

    func testScrollingBackToTheFirstCardDoesNotRestartTheWindow() {
        let ledger = RevealLedger()
        ledger.markRevealed(id: "m0", scope: "shelf", index: 0, now: 10)
        // 很久以后滑回开头：第 0 张是浮现过的卡片，不会重新计时。
        ledger.markRevealed(id: "m0", scope: "shelf", index: 0, now: 20)
        XCTAssertFalse(ledger.startsHidden(id: "m4", scope: "shelf", index: 4, now: 20.1))
    }

    func testResetForgetsEverything() {
        let ledger = RevealLedger()
        ledger.markRevealed(id: "m0", scope: "shelf", index: 0, now: 10)
        ledger.reset()
        XCTAssertTrue(ledger.startsHidden(id: "m0", scope: "shelf", index: 0, now: 50))
    }
}
