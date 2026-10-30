import SwiftUI

struct HomeView: View {
    @StateObject private var recents = RecentStore.shared
    @StateObject private var mediaLibrary = MediaLibraryStore()
    @StateObject private var localStore = LocalMediaStore()
    @StateObject private var metadataStore = MediaMetadataStore()
    @StateObject private var scanner = CloudLibraryScanner()
    @State private var selection: HomeSection = .home
    @State private var restored = false
    private let appState: AppState

    /// init 会在上层页面每次刷新时被重新调用，这里不做任何读盘或联网，
    /// 恢复工作放到 restoreOnce，只执行一次。
    init(appState: AppState) {
        self.appState = appState
    }

    private func restoreOnce() {
        guard !restored else { return }
        restored = true
        scanner.selectAccount(appState.libraryAccountID)
        // 扫描检查点先于首页恢复，避免上次退出时的最后一批文件遗漏。
        mediaLibrary.add(scanner.discoveredFiles, for: appState)
        metadataStore.hydrate(files: HomeLibrary.media(local: localStore, cloud: mediaLibrary, appState: appState))
    }

    var body: some View {
        tabs
            .onAppear(perform: restoreOnce)
            .environmentObject(recents)
            .environmentObject(mediaLibrary)
            .environmentObject(localStore)
            .environmentObject(metadataStore)
            .environmentObject(scanner)
            .tint(Theme.accent)
    }

    /// iOS 18 起用新的 Tab 写法，搜索标签带上 search 角色：iOS 26 上它会变成标签栏右侧单独的玻璃圆钮。
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selection) {
                Tab("首页", systemImage: "play.rectangle.on.rectangle.fill", value: HomeSection.home) {
                    HomeTab()
                }
                Tab("资源库", systemImage: "square.stack.3d.up.fill", value: HomeSection.library) {
                    LibraryTab()
                }
                Tab("设置", systemImage: "gearshape.fill", value: HomeSection.settings) {
                    SettingsTab()
                }
                Tab("搜索", systemImage: "magnifyingglass", value: HomeSection.search, role: .search) {
                    SearchTab()
                }
            }
        } else {
            TabView {
                HomeTab()
                    .tabItem {
                        Label("首页", systemImage: "play.rectangle.on.rectangle.fill")
                    }

                LibraryTab()
                    .tabItem {
                        Label("资源库", systemImage: "square.stack.3d.up.fill")
                    }

                SearchTab()
                    .tabItem {
                        Label("搜索", systemImage: "magnifyingglass")
                    }

                SettingsTab()
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
            }
        }
    }
}

/// 底部标签
enum HomeSection: Hashable {
    case home, library, settings, search
}
