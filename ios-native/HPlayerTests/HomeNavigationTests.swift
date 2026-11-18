import SwiftUI
import UIKit
import XCTest
@testable import HPlayer

final class HomeNavigationTests: XCTestCase {
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

        try await Task.sleep(nanoseconds: 350_000_000)

        let navController = try XCTUnwrap(findNavigationController(in: window.rootViewController),
                                          "\(section.title): expected UINavigationController")
        XCTAssertFalse(navController.navigationBar.prefersLargeTitles,
                       "\(section.title): prefersLargeTitles must stay disabled")

        struct Snapshot {
            let t: TimeInterval
            let barHidden: Bool
            let barFrame: CGRect
            let barPres: CGRect?
            let controls: [(String, CGRect, CGRect?)]
            let labels: [(String, CGRect, CGRect?)]
        }

        var samples: [Snapshot] = []
        let start = ProcessInfo.processInfo.systemUptime

        withAnimation {
            navigation.path.append(MineRoute.page(.localVideos))
        }

        for _ in 0..<45 {
            try await Task.sleep(nanoseconds: 16_000_000)
            let bar = navController.navigationBar
            let controls = collectViews(of: UIControl.self, in: bar).map { view in
                let model = bar.convert(view.bounds, from: view)
                let pres = presentationRect(for: view, in: bar)
                return (String(describing: type(of: view)), model, pres)
            }
            let labels = collectViews(of: UILabel.self, in: bar)
                .filter { !($0.text ?? "").isEmpty }
                .map { view in
                    let model = bar.convert(view.bounds, from: view)
                    let pres = presentationRect(for: view, in: bar)
                    return ($0.text ?? "", model, pres)
                }
            samples.append(Snapshot(
                t: ProcessInfo.processInfo.systemUptime - start,
                barHidden: bar.isHidden || bar.alpha < 0.01,
                barFrame: bar.frame,
                barPres: bar.layer.presentation()?.frame,
                controls: controls,
                labels: labels
            ))
        }

        let settled = try XCTUnwrap(samples.last)
        XCTAssertFalse(settled.barHidden, "\(section.title): bar should be visible on secondary page")

        let visibleSamples = samples.filter { !$0.barHidden && $0.barFrame.height > 1 }
        XCTAssertFalse(visibleSamples.isEmpty, "\(section.title): expected visible navigation bar frames")

        let timeline = visibleSamples.prefix(25).map { s -> String in
            let ctrls = s.controls.map { "\($0.0):m=\(fmt($0.1))/p=\($0.2.map(fmt) ?? "nil")" }.joined(separator: ",")
            let lbls = s.labels.map { "\($0.0):m=\(fmt($0.1))/p=\($0.2.map(fmt) ?? "nil")" }.joined(separator: ",")
            return String(format: "t=%.3f bar=%@ pres=%@ ctrls=[%@] lbls=[%@]",
                          s.t, fmt(s.barFrame), s.barPres.map(fmt) ?? "nil", ctrls, lbls)
        }.joined(separator: "\n")
        let firstDump = describeSubviews(of: navController.navigationBar, in: navController.navigationBar, depth: 0)
        print("=== NavBar Timeline [\(section.title)] ===\n\(timeline)\n=== Settled Subviews ===\n\(firstDump)\n=== End [\(section.title)] ===")

        let halfWidth = settled.barFrame.width / 2
        for s in visibleSamples {
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

            for (name, settledRect, _) in settled.controls {
                let isLeading = settledRect.midX < halfWidth
                if let (_, modelRect, presRect) = s.controls.first(where: { $0.0 == name && ($0.1.midX < halfWidth) == isLeading }) {
                    XCTAssertEqual(modelRect.minY, settledRect.minY, accuracy: 1.5,
                                   "\(section.title): control \(name) model minY shifted.\n\(timeline)")
                    XCTAssertEqual(modelRect.minX, settledRect.minX, accuracy: 1.5,
                                   "\(section.title): control \(name) model minX shifted.\n\(timeline)")
                    if let presRect {
                        XCTAssertEqual(presRect.minY, settledRect.minY, accuracy: 1.5,
                                       "\(section.title): control \(name) presentation minY shifted.\n\(timeline)")
                    }
                }
            }

            for (text, settledRect, _) in settled.labels {
                if let (_, modelRect, presRect) = s.labels.first(where: { $0.0 == text }) {
                    XCTAssertEqual(modelRect.minY, settledRect.minY, accuracy: 1.5,
                                   "\(section.title): label '\(text)' model minY shifted.\n\(timeline)")
                    XCTAssertEqual(modelRect.minX, settledRect.minX, accuracy: 1.5,
                                   "\(section.title): label '\(text)' model minX shifted.\n\(timeline)")
                    if let presRect {
                        XCTAssertEqual(presRect.minY, settledRect.minY, accuracy: 1.5,
                                       "\(section.title): label '\(text)' presentation minY shifted.\n\(timeline)")
                    }
                }
            }
        }
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
    private func collectViews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var result: [T] = []
        for sub in root.subviews {
            if let matched = sub as? T, !matched.isHidden, matched.alpha > 0.01 {
                result.append(matched)
            }
            result.append(contentsOf: collectViews(of: type, in: sub))
        }
        return result
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
        guard depth <= 4 else { return "" }
        let indent = String(repeating: "  ", count: depth)
        let rect = bar.convert(view.bounds, from: view)
        let cls = String(describing: type(of: view))
        var lines = ["\(indent)\(cls) \(fmt(rect)) hidden=\(view.isHidden) alpha=\(String(format: "%.2f", view.alpha))"]
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
