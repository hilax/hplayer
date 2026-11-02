import XCTest
@testable import HPlayer

final class QuotaFormatTests: XCTestCase {
    func testTerabytesAreConvertedAndRatioIsAvailable() {
        let used = 14 * 1_099_511_627_776 + 300_000_000_000
        let total = 15 * 1_099_511_627_776
        let quota = Direct115Client.parseQuota([
            "all_use": ["size": used, "size_format": "14.27TB"],
            "all_total": ["size": total, "size_format": "15TB"],
        ])
        XCTAssertEqual(quota.usedBytes, used)
        XCTAssertEqual(quota.totalBytes, total)
        XCTAssertEqual(quota.usedText, "14.27 TB")
        XCTAssertEqual(quota.totalText, "15.00 TB")
        XCTAssertGreaterThan(Double(quota.usedBytes) / Double(quota.totalBytes), 0.9)
    }

    func testStringSizesAndFallbackText() {
        let quota = Direct115Client.parseQuota([
            "all_use": ["size": "5368709120", "size_format": "5GB"],
            "all_total": ["size_format": "2TB"],
        ])
        XCTAssertEqual(quota.usedText, "5.0 GB")
        XCTAssertEqual(quota.totalBytes, 0)
        XCTAssertEqual(quota.totalText, "2TB")
    }

    func testCapacityUnits() {
        XCTAssertEqual(formatCapacity(0), "0 B")
        XCTAssertEqual(formatCapacity(512), "512 B")
        XCTAssertEqual(formatCapacity(1_073_741_824), "1.0 GB")
    }
}
