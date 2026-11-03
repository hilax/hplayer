import SwiftUI

/// 首页和片库共用的片库分组结果。
///
/// 以前首页和片库各算一份：片库第一次打开时在主线程把整个片库重新分组、再生成网格条目，
/// 切换标签的动画被卡住（底部液态玻璃停在半路），网格也要过一会儿才出来。
/// 现在由 HomeView 在后台算一次，两个页面直接读；片库的网格条目在首页显示后顺手在后台算好，
/// 第一次切到片库时已经准备好了。
@MainActor
final class LibrarySnapshotStore: ObservableObject {
    @Published private(set) var home = HomeSnapshot(items: [])
    /// 第一份分组算好之前首页不显示内容（也不先闪空状态），算好后淡入。
    @Published private(set) var ready = false
    @Published private(set) var catalogEntries: [CatalogEntry] = []
    @Published private(set) var catalogReady = false
    /// 每换一次分组加一：片库条目、首页预取都跟着它刷新。
    @Published private(set) var revision = 0

    /// 片库不大时直接在主线程算，第一帧就有内容；再大就放到后台，主线程不被卡住。
    static let inlineLimit = 400

    func rebuild(files: [LibraryMedia], matches: [String: MediaMetadata]) async {
        let snapshot: HomeSnapshot
        if ready {
            // 匹配、扫描期间结果一批批到，攒 0.3 秒再算一次
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            snapshot = await Task.detached(priority: .userInitiated) {
                LibrarySnapshotStore.make(files, matches)
            }.value
        } else if files.count > Self.inlineLimit {
            snapshot = await Task.detached(priority: .userInitiated) {
                LibrarySnapshotStore.make(files, matches)
            }.value
        } else {
            snapshot = Self.make(files, matches)
        }
        guard !Task.isCancelled else { return }
        home = snapshot
        revision += 1
        if !ready {
            withAnimation(Motion.fade) { ready = true }
        }
    }

    /// 片库网格的条目：分类、地区、年份、最近播放的排序信息。
    func rebuildEntries(recents: [RecentItem]) async {
        guard ready else { return }
        let snapshot = home
        let entries: [CatalogEntry]
        if snapshot.items.count > Self.inlineLimit {
            entries = await Task.detached(priority: .utility) {
                CatalogTab.makeEntries(snapshot, recents: recents)
            }.value
        } else {
            entries = CatalogTab.makeEntries(snapshot, recents: recents)
        }
        guard !Task.isCancelled else { return }
        catalogEntries = entries
        catalogReady = true
    }

    nonisolated static func make(_ files: [LibraryMedia], _ matches: [String: MediaMetadata]) -> HomeSnapshot {
        HomeSnapshot(items: files.map { HomeMediaItem(media: $0, metadata: matches[$0.id]) })
    }
}
