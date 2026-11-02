import XCTest
@testable import HPlayer

final class PlaybackQualityTests: XCTestCase {
    func testRefreshKeepsTheSelectedQuality() throws {
        let highURL = try XCTUnwrap(URL(string: "https://example.com/4k.m3u8"))
        let lowURL = try XCTUnwrap(URL(string: "https://example.com/1080.m3u8"))
        let streams = [
            Direct115Stream(id: "1080", title: "1080P", url: lowURL),
            Direct115Stream(id: "4k", title: "4K", url: highURL),
        ]
        XCTAssertEqual(try Direct115Stream.url(forQuality: "4K", in: streams), highURL)
        XCTAssertThrowsError(try Direct115Stream.url(forQuality: "720P", in: streams),
                             "A missing quality must not silently switch to the first available stream")
    }
}
