import XCTest
@testable import HPlayer

final class EpisodeShelfTests: XCTestCase {

    func testShortAnimeTitleFormatsNumbersAndPreservesSpecialLabels() {
        XCTAssertEqual(EpisodeShelfItem.shortAnimeTitle("第1集"), "01")
        XCTAssertEqual(EpisodeShelfItem.shortAnimeTitle("第01集"), "01")
        XCTAssertEqual(EpisodeShelfItem.shortAnimeTitle("第9话"), "09")
        XCTAssertEqual(EpisodeShelfItem.shortAnimeTitle("第12集"), "12")
        XCTAssertEqual(EpisodeShelfItem.shortAnimeTitle("第108集"), "108")
        XCTAssertEqual(EpisodeShelfItem.shortAnimeTitle("特别篇"), "特别篇")
        XCTAssertEqual(EpisodeShelfItem.shortAnimeTitle("OVA"), "OVA")
    }

    func testNumberedTitlePadsSingleDigits() {
        XCTAssertEqual(EpisodeShelfItem.numberedTitle(1), "01")
        XCTAssertEqual(EpisodeShelfItem.numberedTitle(9), "09")
        XCTAssertEqual(EpisodeShelfItem.numberedTitle(10), "10")
        XCTAssertEqual(EpisodeShelfItem.numberedTitle(128), "128")
    }

    func testRangesChunkByFiftyAndReverseWhenDescending() {
        XCTAssertEqual(EpisodeShelfLayout.ranges(count: 0, descending: false), [])
        XCTAssertEqual(EpisodeShelfLayout.ranges(count: 12, descending: false), [0..<12])
        XCTAssertEqual(EpisodeShelfLayout.ranges(count: 120, descending: false), [0..<50, 50..<100, 100..<120])
        XCTAssertEqual(EpisodeShelfLayout.ranges(count: 120, descending: true), [100..<120, 50..<100, 0..<50])
    }

    func testIndicesAndRangeLookupTrackCurrentEpisode() {
        let ascRanges = EpisodeShelfLayout.ranges(count: 120, descending: false)
        XCTAssertEqual(EpisodeShelfLayout.rangeIndex(containing: 0, in: ascRanges), 0)
        XCTAssertEqual(EpisodeShelfLayout.rangeIndex(containing: 55, in: ascRanges), 1)
        XCTAssertEqual(EpisodeShelfLayout.rangeIndex(containing: 119, in: ascRanges), 2)
        XCTAssertEqual(EpisodeShelfLayout.rangeIndex(containing: nil, in: ascRanges), 0)

        let descRanges = EpisodeShelfLayout.ranges(count: 120, descending: true)
        XCTAssertEqual(EpisodeShelfLayout.rangeIndex(containing: 119, in: descRanges), 0)
        XCTAssertEqual(EpisodeShelfLayout.rangeIndex(containing: 55, in: descRanges), 1)
        XCTAssertEqual(EpisodeShelfLayout.rangeIndex(containing: 0, in: descRanges), 2)

        XCTAssertEqual(EpisodeShelfLayout.indices(in: 0..<5, descending: false), [0, 1, 2, 3, 4])
        XCTAssertEqual(EpisodeShelfLayout.indices(in: 0..<5, descending: true), [4, 3, 2, 1, 0])
    }

    func testRowsSplitIntoFiveColumnChunks() {
        XCTAssertEqual(EpisodeShelfLayout.rows(from: []), [])
        XCTAssertEqual(EpisodeShelfLayout.rows(from: Array(0..<5)), [[0, 1, 2, 3, 4]])
        XCTAssertEqual(EpisodeShelfLayout.rows(from: Array(0..<12)), [[0, 1, 2, 3, 4], [5, 6, 7, 8, 9], [10, 11]])
    }
}
