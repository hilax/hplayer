import XCTest
@testable import HPlayer

final class Direct115QRLoginTests: XCTestCase {
    func testCookieHeaderPutsLoginFieldsFirstAndDropsUnsafeValues() {
        let header = Direct115QRLogin.cookieHeader([
            "SEID": "seid", "KID": "kid", "UID": "123_A1_1700000000", "CID": "cid",
            "acw": "x", "bad": "a;b", "": "empty",
        ])
        XCTAssertEqual(header, "UID=123_A1_1700000000; CID=cid; SEID=seid; KID=kid; acw=x")
        XCTAssertEqual(AppState.accountID(in: header), "device:123")
    }

    func testNumbersAndBooleansReadAsIntegers() {
        XCTAssertEqual(Direct115QRLogin.integer(NSNumber(value: true)), 1)
        XCTAssertEqual(Direct115QRLogin.integer(NSNumber(value: -2)), -2)
        XCTAssertEqual(Direct115QRLogin.integer("2"), 2)
        XCTAssertEqual(Direct115QRLogin.string(NSNumber(value: 1_700_000_000)), "1700000000")
    }
}
