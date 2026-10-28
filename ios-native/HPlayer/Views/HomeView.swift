import SwiftUI

struct HomeView: View {
    @StateObject private var recents = RecentStore()
    @StateObject private var mediaLibrary = MediaLibraryStore()

    var body: some View {
        TabView {
            HomeTab()
                .tabItem {
                    Label("首页", systemImage: "play.rectangle.fill")
                }

            LibraryTab()
                .tabItem {
                    Label("资源库", systemImage: "externaldrive.fill")
                }

            SettingsTab()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }

            SearchTab()
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
        }
        .environmentObject(recents)
        .environmentObject(mediaLibrary)
        .tint(Theme.accent)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Theme.pageBackground.opacity(0.96), for: .tabBar)
    }
}
