import SwiftUI

struct HomeView: View {
    @StateObject private var recents = RecentStore()
    @StateObject private var mediaLibrary = MediaLibraryStore()

    var body: some View {
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
        .environmentObject(recents)
        .environmentObject(mediaLibrary)
        .tint(Theme.accent)
    }
}
