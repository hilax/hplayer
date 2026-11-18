import XCTest
@testable import HPlayer

@MainActor
final class AnimeBrowseFilterTests: XCTestCase {
    private func item(_ id: Int, year: String? = nil, type: String? = nil, area: String? = nil,
                      isend: Int? = nil, continu: String? = nil) -> AnimeVideoItem {
        AnimeVideoItem(id: id, name: "番剧\(id)", year: year, area: area, continu: continu, isend: isend, type: type)
    }

    func testMatchesEachField() {
        let filter = AnimeBrowseFilter(type: "热血", year: "2025", area: "日本", status: .ongoing)
        let hit = item(1, year: "2025", type: "热血,冒险", area: "日本", isend: 0)
        XCTAssertEqual(filter.matches(hit, field: .type, knownYears: []), true)
        XCTAssertEqual(filter.matches(hit, field: .year, knownYears: []), true)
        XCTAssertEqual(filter.matches(hit, field: .area, knownYears: []), true)
        XCTAssertEqual(filter.matches(hit, field: .status, knownYears: []), true)
        XCTAssertTrue(filter.admits(hit, knownYears: []))

        let miss = item(2, year: "2024", type: "恋爱", area: "日本", isend: 1)
        XCTAssertEqual(filter.matches(miss, field: .type, knownYears: []), false)
        XCTAssertEqual(filter.matches(miss, field: .year, knownYears: []), false)
        XCTAssertEqual(filter.matches(miss, field: .status, knownYears: []), false)
        XCTAssertFalse(filter.admits(miss, knownYears: []))
    }

    func testMissingFieldsAreNotExcluded() {
        let filter = AnimeBrowseFilter(type: "热血", year: "2025", status: .ended)
        let unknown = item(3)
        XCTAssertNil(filter.matches(unknown, field: .type, knownYears: []))
        XCTAssertNil(filter.matches(unknown, field: .year, knownYears: []))
        XCTAssertNil(filter.matches(unknown, field: .status, knownYears: []))
        XCTAssertTrue(filter.admits(unknown, knownYears: []))
    }

    func testStatusFallsBackToEpisodeText() {
        let filter = AnimeBrowseFilter(status: .ended)
        XCTAssertEqual(filter.matches(item(4, continu: "全12集"), field: .status, knownYears: []), true)
        XCTAssertEqual(filter.matches(item(5, continu: "更新至08集"), field: .status, knownYears: []), false)
    }

    func testEarlierYearOptionComparesAgainstEarliestKnownYear() {
        let filter = AnimeBrowseFilter(year: "更早")
        let years = ["2026", "2025", "2020", "更早"]
        XCTAssertEqual(filter.matches(item(6, year: "2018"), field: .year, knownYears: years), true)
        XCTAssertEqual(filter.matches(item(7, year: "2021"), field: .year, knownYears: years), false)
    }

    func testServerParametersAndActiveFields() {
        let filter = AnimeBrowseFilter(channelId: 3, type: "校园", status: .ended)
        XCTAssertEqual(filter.activeFields, [.channel, .type, .status])
        XCTAssertEqual(filter.checkableFields, [.type, .status])
        let params = Dictionary(uniqueKeysWithValues: filter.serverParameters.map { ($0.name, $0.value) })
        XCTAssertEqual(params, ["type": "校园", "isend": "1"])
    }

    func testOptionsDropAllEntriesAndMergeChannels() {
        let channels = [
            AnimeChannel(id: 1, name: "日漫", types: ["全部", "热血", "恋爱"], years: ["全部", "2025", "2026"], areas: ["日本"], oid: nil, pid: nil),
            AnimeChannel(id: 2, name: "国漫", types: ["热血", "玄幻"], years: ["2024"], areas: ["大陆"], oid: nil, pid: nil)
        ]
        let all = AnimeFilterOptions.make(channels: channels, baseChannelId: nil, selectedChannelId: nil)
        XCTAssertEqual(all.channels.map(\.id), [1, 2])
        XCTAssertEqual(all.types, ["热血", "恋爱", "玄幻"])
        XCTAssertEqual(all.years, ["2026", "2025", "2024"])
        XCTAssertEqual(all.areas, ["日本", "大陆"])

        let japan = AnimeFilterOptions.make(channels: channels, baseChannelId: 1, selectedChannelId: nil)
        XCTAssertTrue(japan.channels.isEmpty)
        XCTAssertEqual(japan.types, ["热血", "恋爱"])
        XCTAssertEqual(japan.areas, ["日本"])
    }

    func testSettingAndClearingFields() {
        var filter = AnimeBrowseFilter.newRelease
        XCTAssertNotNil(filter.year)
        XCTAssertEqual(filter.status, .ongoing)
        filter = filter.setting(.status, to: AnimeEndState.ended.rawValue).setting(.channel, to: "7")
        XCTAssertEqual(filter.status, .ended)
        XCTAssertEqual(filter.channelId, 7)
        filter.clear(.year)
        XCTAssertNil(filter.year)
        XCTAssertEqual(filter.value(for: .channel), "7")
    }
}
