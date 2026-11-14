import XCTest
@testable import HPlayer

/// 从「继续观看」打开时要还原当时的整份列表，选集里才看得到上一集、下一集。
@MainActor
final class RecentPlaylistStoreTests: XCTestCase {
    private func cloudFolder() -> [PlaybackSource] {
        (1...3).map { .p115(title: "第\($0)集.mp4", pickCode: "pc\($0)") }
    }

    func testRestoresWholeFolderForCloudFile() {
        let store = RecentPlaylistStore(fileURL: nil)
        let playlist = cloudFolder()
        store.remember(playlist, current: playlist[1], keep: [])

        let recent = RecentItem(id: "r", title: "第2集.mp4", url: "", playedAt: Date(), pickCode: "pc2")
        let queue = store.queue(for: recent)
        XCTAssertEqual(queue?.items, playlist)
        XCTAssertEqual(queue?.source, playlist[1])
    }

    func testSingleItemListIsNotStored() {
        let store = RecentPlaylistStore(fileURL: nil)
        let only: PlaybackSource = .p115(title: "a.mp4", pickCode: "solo")
        store.remember([only], current: only, keep: [])
        let recent = RecentItem(id: "r", title: "a.mp4", url: "", playedAt: Date(), pickCode: "solo")
        XCTAssertNil(store.queue(for: recent))
    }

    func testDropsListsForRecordsNoLongerInHistory() {
        let store = RecentPlaylistStore(fileURL: nil)
        let first = cloudFolder()
        store.remember(first, current: first[0], keep: [])
        let other: [PlaybackSource] = [.p115(title: "x", pickCode: "x1"), .p115(title: "y", pickCode: "x2")]
        // 第一份列表的那条记录已经从观看记录里删掉了
        store.remember(other, current: other[0], keep: ["p115|x1"])

        let gone = RecentItem(id: "r", title: "第1集.mp4", url: "", playedAt: Date(), pickCode: "pc1")
        XCTAssertNil(store.queue(for: gone))
        let kept = RecentItem(id: "r2", title: "x", url: "", playedAt: Date(), pickCode: "x1")
        XCTAssertEqual(store.queue(for: kept)?.items.count, 2)
    }

    func testRemapsLocalFilesToCurrentSandbox() {
        let store = RecentPlaylistStore(fileURL: nil)
        let old = URL(fileURLWithPath: "/old/container/Media")
        let playlist: [PlaybackSource] = ["a.mp4", "b.mp4"].map {
            .direct(title: $0, url: old.appendingPathComponent($0))
        }
        store.remember(playlist, current: playlist[0], keep: [])
        let recent = RecentItem(id: "r", title: "a.mp4", url: old.appendingPathComponent("a.mp4").absoluteString, playedAt: Date())
        let now = URL(fileURLWithPath: "/new/container/Media")
        let queue = store.queue(for: recent, localDirectory: now)
        XCTAssertEqual(queue?.items.last, .direct(title: "b.mp4", url: now.appendingPathComponent("b.mp4")))
    }
}
