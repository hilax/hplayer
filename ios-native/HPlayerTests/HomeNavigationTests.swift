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
            try await assertStablePush(from: section, in: scene)
        }
    }

    /// 对照实验：复现 Pass 1 修复前（外层 NavigationStack + TabView 未锁定 .inline 与 prefersLargeTitles = false）推入二级页的原始帧时间线，供 CI 日志对比。
    @MainActor
    func testBaselineUnstabilizedNavigationBarReport() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else {
            throw XCTSkip("No UIWindowScene available")
        }

        let navPath = BindingBox()
        let host = BaselineUnfixedHost(box: navPath)

        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: host)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        let navController = try XCTUnwrap(findNavigationController(in: window.rootViewController))
        print("BASELINE prefersLargeTitles before push = \(navController.navigationBar.prefersLargeTitles)")

        let samples = await capturePushFrames(navController: navController, frameLimit: 55) {
            navPath.push?()
        }
        let timeline = formatTimeline(samples.filter { !$0.barHidden && $0.barFrame.height > 1 }, limit: 35)
        let settledDump = describeSubviews(of: navController.navigationBar, in: navController.navigationBar, depth: 0)
        print("=== BASELINE UNFIXED Timeline ===\n\(timeline)\n=== BASELINE Settled Subviews ===\n\(settledDump)\n=== End BASELINE ===")
    }

    @MainActor
    private func assertStablePush(from section: HomeSection, in scene: UIWindowScene) async throws {
        let suite = "hplayer.nav-test.\(section.identifier)"
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

        // 先等首屏（含 HomeTab / MagnetTab 初始渲染与后台任务触发）完全稳定，避免主线程忙碌吞掉动画前段帧
        try await Task.sleep(nanoseconds: 850_000_000)

        let navController = try XCTUnwrap(findNavigationController(in: window.rootViewController),
                                          "\(section.title): expected UINavigationController")
        XCTAssertFalse(navController.navigationBar.prefersLargeTitles,
                       "\(section.title): prefersLargeTitles must stay disabled")

        let samples = await capturePushFrames(navController: navController, frameLimit: 55) {
            switch section {
            case .home:
                navigation.path.append(AnimeBrowseRoute(channelId: nil, title: "热门新番", sort: "hits"))
            case .magnet:
                navigation.path.append(MineRoute.page(.downloads))
            case .cloud:
                navigation.path.append(CloudRoute.page(.offline))
            case .mine, .search:
                navigation.path.append(MineRoute.page(.localVideos))
            }
        }

        let settled = try XCTUnwrap(samples.last)
        XCTAssertFalse(settled.barHidden, "\(section.title): bar should be visible on secondary page")
        XCTAssertFalse(navController.navigationBar.prefersLargeTitles,
                       "\(section.title): prefersLargeTitles must remain disabled after push")

        let visibleSamples = samples.filter { !$0.barHidden && $0.barFrame.height > 1 }
        XCTAssertFalse(visibleSamples.isEmpty, "\(section.title): expected visible navigation bar frames")
        XCTAssertFalse(settled.elements.isEmpty, "\(section.title): expected tracked navigation bar elements")

        let timeline = formatTimeline(visibleSamples, limit: 35)
        let firstDump = describeSubviews(of: navController.navigationBar, in: navController.navigationBar, depth: 0)
        print("=== NavBar Timeline [\(section.title)] (visible=\(visibleSamples.count)/\(samples.count)) ===\n\(timeline)\n=== Settled Subviews ===\n\(firstDump)\n=== End [\(section.title)] ===")

        for s in visibleSamples {
            XCTAssertEqual(s.barCount, 1, "\(section.title): expected single UINavigationBar.\n\(timeline)")
            XCTAssertEqual(s.barFrame.minY, settled.barFrame.minY, accuracy: 1.5,
                           "\(section.title): barFrame.minY jumped during push.\n\(timeline)")
            XCTAssertEqual(s.barFrame.height, settled.barFrame.height, accuracy: 1.5,
                           "\(section.title): barFrame.height jumped during push.\n\(timeline)")
            if let pres = s.barPres {
                XCTAssertEqual(pres.minY, settled.barFrame.minY, accuracy: 1.5,
                               "\(section.title): bar presentation minY jumped during push.\n\(timeline)")
                XCTAssertEqual(pres.height, settled.barFrame.height, accuracy: 1.5,
                               "\(section.title): bar presentation height jumped during push.\n\(timeline)")
            }

            for target in settled.elements {
                guard let current = s.elements.first(where: { $0.key == target.key }) else { continue }
                XCTAssertEqual(current.model.minY, target.model.minY, accuracy: 1.5,
                               "\(section.title): \(target.key) model minY shifted at t=\(String(format: "%.3f", s.t)).\n\(timeline)")
                XCTAssertEqual(current.model.minX, target.model.minX, accuracy: 1.5,
                               "\(section.title): \(target.key) model minX shifted at t=\(String(format: "%.3f", s.t)).\n\(timeline)")
                if let presRect = current.pres {
                    XCTAssertEqual(presRect.minY, target.model.minY, accuracy: 1.5,
                                   "\(section.title): \(target.key) pres minY shifted at t=\(String(format: "%.3f", s.t)).\n\(timeline)")
                    XCTAssertEqual(presRect.minX, target.model.minX, accuracy: 1.5,
                                   "\(section.title): \(target.key) pres minX shifted at t=\(String(format: "%.3f", s.t)).\n\(timeline)")
                }
            }
        }
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
                if count >= frameLimit {
                    link?.invalidate()
                    link = nil
                    target.onTick = nil
                    continuation.resume(returning: samples)
                }
            }
            linkObj.add(to: .main, forMode: .common)
            withAnimation {
                action()
            }
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

private final class BindingBox {
    var push: (() -> Void)?
}

private struct BaselineUnfixedHost: View {
    let box: BindingBox
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TabView {
                ScrollView {
                    VStack {
                        Text("Baseline Root")
                            .padding(.top, 20)
                    }
                    .frame(maxWidth: .infinity)
                }
                .toolbar(.hidden, for: .navigationBar)
                .tabItem { Text("Tab") }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Int.self) { _ in
                List {
                    Text("Secondary Item")
                }
                .navigationTitle("离线下载")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("添加") {}
                    }
                }
            }
        }
        .onAppear {
            box.push = { path.append(1) }
        }
    }
}
