import SwiftUI
import UIKit
import XCTest
@testable import HPlayer

private final class DisplayLinkTarget: NSObject {
    var onTick: (() -> Void)?

    @objc func step(_ link: CADisplayLink) {
        onTick?()
    }
}

final class HomeNavigationTests: XCTestCase {
    private struct TrackedElement {
        let key: String
        let tag: String
        let model: CGRect
        let pres: CGRect?
    }

    private struct FrameSnapshot {
        let index: Int
        let t: TimeInterval
        let barCount: Int
        let barHidden: Bool
        let barFrame: CGRect
        let barPres: CGRect?
        let elements: [TrackedElement]
    }

    @MainActor
    func testNavigationBarGeometryDoesNotJumpWhenPushingFromPrimaryTabs() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else {
            throw XCTSkip("No UIWindowScene available")
        }

        for section in HomeSection.tabs {
            try await assertStablePush(from: section, useOfflineRoute: true, in: scene)
        }
        try await assertStablePush(from: .home, useOfflineRoute: false, in: scene)
        try await assertStablePush(from: .magnet, useOfflineRoute: false, in: scene)
    }

    @MainActor
    private func assertStablePush(from section: HomeSection, useOfflineRoute: Bool, in scene: UIWindowScene) async throws {
        let suite = "hplayer.nav-test.\(section.identifier).\(useOfflineRoute)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("NavTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appState = AppState(cookieLoader: { nil }, cookieValidator: { _ in }, cookieSaver: { _ in }, cookieRemover: {})
        let library = MediaLibraryStore(defaults: defaults)
        let local = LocalMediaStore(directory: tempDir)
        let metadata = MediaMetadataStore(defaults: defaults, lookup: { _ in nil })
        let recents = RecentStore(defaults: defaults)
        let accountInfo = P115AccountInfoStore(
            fetchStatus: { _ in throw APIError.server("test") },
            fetchQuota: { _ in throw APIError.server("test") }
        )
        let navigation = HomeNavigation()

        let root = HomeView(
            appState: appState,
            initialSection: section,
            library: library,
            local: local,
            metadata: metadata,
            recents: recents,
            accountInfo: accountInfo,
            navigation: navigation
        ).environmentObject(appState)

        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // 先等首屏（含 HomeTab / MagnetTab 初始渲染与后台任务）完全稳定，避免主线程忙碌吞掉动画前段帧
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let navController = try XCTUnwrap(findNavigationController(in: window.rootViewController),
                                          "\(section.title): expected UINavigationController")
        let bar = navController.navigationBar
        let rootPage = try XCTUnwrap(navController.viewControllers.first, "\(section.title): expected root page")

        // 一级页面：系统导航栏一直显示但隐形——不拦截点击、安全区和「隐藏导航栏」时一样、没有大标题
        XCTAssertFalse(navController.isNavigationBarHidden,
                       "\(section.title): root keeps the system bar shown (transparent) so pushes don't slide it in")
        XCTAssertFalse(bar.isUserInteractionEnabled,
                       "\(section.title): transparent root bar must let taps through to the page")
        XCTAssertEqual(rootPage.view.safeAreaInsets.top, window.safeAreaInsets.top, accuracy: 1,
                       "\(section.title): root layout must not shift down by the bar height")
        XCTAssertFalse(bar.prefersLargeTitles, "\(section.title): prefersLargeTitles must stay disabled")
        XCTAssertEqual(rootPage.navigationItem.largeTitleDisplayMode, .never,
                       "\(section.title): root navigationItem must lock .never largeTitleDisplayMode")

        let label = useOfflineRoute ? "\(section.title)/offline" : "\(section.title)/native"
        let settledBefore = bar.frame
        let samples = await capturePushFrames(navController: navController, frameLimit: 55) {
            if useOfflineRoute {
                navigation.path.append(CloudRoute.page(.offline))
            } else {
                switch section {
                case .home:
                    navigation.path.append(AnimeBrowseRoute.newReleases)
                case .magnet:
                    navigation.path.append(MineRoute.page(.downloads))
                case .cloud:
                    navigation.path.append(CloudRoute.page(.offline))
                case .mine, .search:
                    navigation.path.append(MineRoute.page(.localVideos))
                }
            }
        }

        let settled = try XCTUnwrap(samples.last)
        XCTAssertFalse(settled.barHidden, "\(label): bar should be visible on secondary page")
        XCTAssertTrue(bar.isUserInteractionEnabled, "\(label): bar must be tappable on secondary page (back button)")
        XCTAssertFalse(bar.prefersLargeTitles, "\(label): prefersLargeTitles must remain disabled after push")
        XCTAssertFalse(settled.elements.isEmpty, "\(label): expected tracked navigation bar elements")

        let timeline = formatTimeline(samples, limit: 35)
        let firstDump = describeSubviews(of: bar, in: bar, depth: 0)
        print("=== NavBar Timeline [\(label)] (frames=\(samples.count)) ===\n\(timeline)\n=== Settled Subviews ===\n\(firstDump)\n=== End [\(label)] ===")

        // 真机录屏里的问题：导航栏整条跟着新页面滑进来，而且只走页面的约 88%，先偏出去再回正。
        // 导航栏一直显示后，推入过程中它不应该被隐藏，也不应该横向 / 纵向移动或变高。
        for s in samples {
            XCTAssertFalse(s.barHidden, "\(label): bar must stay shown during the push (frame #\(s.index)).\n\(timeline)")
            XCTAssertEqual(s.barCount, 1, "\(label): expected single UINavigationBar.\n\(timeline)")
            XCTAssertEqual(s.barFrame.minX, settledBefore.minX, accuracy: 1,
                           "\(label): bar slid horizontally during push (frame #\(s.index)).\n\(timeline)")
            XCTAssertEqual(s.barFrame.minY, settledBefore.minY, accuracy: 1.5,
                           "\(label): barFrame.minY jumped during push.\n\(timeline)")
            XCTAssertEqual(s.barFrame.height, settledBefore.height, accuracy: 1.5,
                           "\(label): barFrame.height jumped during push.\n\(timeline)")
            if let pres = s.barPres {
                XCTAssertEqual(pres.minX, settledBefore.minX, accuracy: 1,
                               "\(label): bar presentation slid horizontally during push (frame #\(s.index)).\n\(timeline)")
                XCTAssertEqual(pres.minY, settledBefore.minY, accuracy: 1.5,
                               "\(label): bar presentation minY jumped during push.\n\(timeline)")
                XCTAssertEqual(pres.height, settledBefore.height, accuracy: 1.5,
                               "\(label): bar presentation height jumped during push.\n\(timeline)")
            }
        }

        // 返回一级页面后：导航栏又变回不接收点击，根页安全区不变
        navigation.path.removeAll()
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertFalse(bar.isUserInteractionEnabled, "\(label): bar must stop taking taps after popping back to root")
        XCTAssertEqual(rootPage.view.safeAreaInsets.top, window.safeAreaInsets.top, accuracy: 1,
                       "\(label): root layout must be unchanged after popping back")
    }

    @MainActor
    private func capturePushFrames(
        navController: UINavigationController,
        frameLimit: Int,
        action: @escaping () -> Void
    ) async -> [FrameSnapshot] {
        await withCheckedContinuation { continuation in
            let target = DisplayLinkTarget()
            var link: CADisplayLink?
            var samples: [FrameSnapshot] = []
            var count = 0
            let start = ProcessInfo.processInfo.systemUptime

            let linkObj = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.step(_:)))
            link = linkObj
            target.onTick = { [weak self, weak navController] in
                guard let self, let navController else {
                    link?.invalidate()
                    link = nil
                    target.onTick = nil
                    continuation.resume(returning: samples)
                    return
                }
                let bar = navController.navigationBar
                let elements = self.collectTrackedElements(in: bar)
                samples.append(FrameSnapshot(
                    index: count,
                    t: ProcessInfo.processInfo.systemUptime - start,
                    barCount: self.countAllNavigationBars(in: navController.view),
                    barHidden: bar.isHidden || bar.alpha < 0.01,
                    barFrame: bar.frame,
                    barPres: bar.layer.presentation()?.frame,
                    elements: elements
                ))
                count += 1
                // 模拟器不刷新时也要结束，不让测试一直挂着
                if count >= frameLimit || ProcessInfo.processInfo.systemUptime - start > 3 {
                    link?.invalidate()
                    link = nil
                    target.onTick = nil
                    continuation.resume(returning: samples)
                }
            }
            linkObj.add(to: .main, forMode: .common)
            action()
        }
    }

    @MainActor
    private func collectTrackedElements(in bar: UIView) -> [TrackedElement] {
        var collected: [(tag: String, view: UIView, model: CGRect, pres: CGRect?)] = []
        collectMatchingViews(in: bar, rootBar: bar, into: &collected)
        let width = max(bar.bounds.width, 1)
        var bucketCounts: [String: Int] = [:]
        return collected.map { item in
            let side = item.model.midX < width * 0.35 ? "L" : item.model.midX > width * 0.65 ? "R" : "C"
            let base = "\(item.tag)[\(side)]"
            let idx = bucketCounts[base, default: 0]
            bucketCounts[base] = idx + 1
            return TrackedElement(key: "\(base)#\(idx)", tag: item.tag, model: item.model, pres: item.pres)
        }
    }

    @MainActor
    private func collectMatchingViews(
        in view: UIView,
        rootBar bar: UIView,
        into result: inout [(tag: String, view: UIView, model: CGRect, pres: CGRect?)]
    ) {
        for sub in view.subviews {
            guard !sub.isHidden, sub.alpha > 0.01, sub.bounds.width > 0.5, sub.bounds.height > 0.5 else {
                continue
            }
            let cls = String(describing: type(of: sub))
            let tag: String?
            if cls.contains("PlatterView") {
                tag = "Platter"
            } else if cls.contains("HostedViewWrapper") {
                tag = "HostedTitle"
            } else if cls.contains("NavigationBarTitleControl") {
                tag = "TitleCtrl"
            } else if cls.contains("ButtonBarButton") {
                tag = "BarBtn"
            } else if let label = sub as? UILabel, let text = label.text, !text.isEmpty {
                tag = "Lbl(\(text))"
            } else if sub is UIControl {
                tag = cls
            } else {
                tag = nil
            }
            if let tag {
                let model = bar.convert(sub.bounds, from: sub)
                let pres = presentationRect(for: sub, in: bar)
                result.append((tag, sub, model, pres))
            }
            collectMatchingViews(in: sub, rootBar: bar, into: &result)
        }
    }

    @MainActor
    private func countAllNavigationBars(in root: UIView?) -> Int {
        guard let root else { return 0 }
        var total = (root is UINavigationBar && !root.isHidden && root.alpha > 0.01) ? 1 : 0
        for sub in root.subviews {
            total += countAllNavigationBars(in: sub)
        }
        return total
    }

    private func formatTimeline(_ samples: [FrameSnapshot], limit: Int) -> String {
        samples.prefix(limit).map { s -> String in
            let elems = s.elements.map {
                "\($0.key):m=\(fmt($0.model))/p=\($0.pres.map(fmt) ?? "nil")"
            }.joined(separator: ",")
            return String(format: "#%02d t=%.3f bars=%d bar=%@ pres=%@ [%@]",
                          s.index, s.t, s.barCount, fmt(s.barFrame), s.barPres.map(fmt) ?? "nil", elems)
        }.joined(separator: "\n")
    }

    @MainActor
    private func findNavigationController(in vc: UIViewController?) -> UINavigationController? {
        guard let vc else { return nil }
        if let nav = vc as? UINavigationController { return nav }
        for child in vc.children {
            if let found = findNavigationController(in: child) { return found }
        }
        return nil
    }

    @MainActor
    private func presentationRect(for view: UIView, in container: UIView) -> CGRect? {
        guard let layer = view.layer.presentation(), let containerLayer = container.layer.presentation() else {
            return nil
        }
        return containerLayer.convert(layer.bounds, from: layer)
    }

    private func fmt(_ r: CGRect) -> String {
        String(format: "(%.1f,%.1f,%.1fx%.1f)", r.minX, r.minY, r.width, r.height)
    }

    @MainActor
    private func describeSubviews(of view: UIView, in bar: UIView, depth: Int) -> String {
        guard depth <= 8 else { return "" }
        let indent = String(repeating: "  ", count: depth)
        let rect = bar.convert(view.bounds, from: view)
        let cls = String(describing: type(of: view))
        let extra = (view as? UILabel)?.text.map { " text=\"\($0)\"" } ?? ""
        var lines = ["\(indent)\(cls) \(fmt(rect)) hidden=\(view.isHidden) alpha=\(String(format: "%.2f", view.alpha))\(extra)"]
        for sub in view.subviews {
            let child = describeSubviews(of: sub, in: bar, depth: depth + 1)
            if !child.isEmpty { lines.append(child) }
        }
        return lines.joined(separator: "\n")
    }

    func testSystemPopUpdatesCloudBreadcrumbsBeforeOpeningAnotherFolder() {
        let navigation = HomeNavigation()
        let root = CloudRoute.folder(Crumb(cid: "0", name: "115 网盘"))
        let first = CloudRoute.folder(Crumb(cid: "1", name: "电影"))
        let second = CloudRoute.folder(Crumb(cid: "2", name: "剧集"))
        navigation.setCloudRoutes([root, first])

        navigation.path.removeLast()
        XCTAssertEqual(navigation.cloudRoutes, [root])

        navigation.setCloudRoutes(navigation.cloudRoutes + [second])
        XCTAssertEqual(navigation.cloudRoutes, [root, second])
        XCTAssertEqual(navigation.path.count, 2)
    }

    func testCancelledPopCanRestoreTheWholeCloudPath() {
        let navigation = HomeNavigation()
        let routes: [CloudRoute] = [
            .folder(Crumb(cid: "0", name: "115 网盘")),
            .folder(Crumb(cid: "1", name: "电影")),
            .page(.offline)
        ]
        navigation.setCloudRoutes(routes)
        let beforePop = navigation.path

        navigation.path.removeLast(navigation.path.count)
        XCTAssertTrue(navigation.cloudRoutes.isEmpty)
        navigation.path = beforePop
        XCTAssertEqual(navigation.cloudRoutes, routes)
    }

    func testChangingTabsDoesNotReuseCloudBreadcrumbsForOtherRoutes() {
        let navigation = HomeNavigation()
        navigation.setCloudRoutes([.folder(Crumb(cid: "0", name: "115 网盘"))])
        navigation.path.removeLast()

        // HomeView 切换标签时清空上一标签的路径，再接受演员或动漫等其他路由。
        navigation.setCloudRoutes([])
        navigation.path.append(PerformerRoute(id: "actor", name: "演员"))
        XCTAssertTrue(navigation.cloudRoutes.isEmpty)
        XCTAssertEqual(navigation.path.count, 1)
    }
}
