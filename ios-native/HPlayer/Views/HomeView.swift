import SwiftUI

struct HomeView: View {
    @StateObject private var recents = RecentStore()

    var body: some View {
        TabView {
            PlayTab()
                .tabItem {
                    Label("播放", systemImage: "play.circle.fill")
                }

            LibraryTab()
                .tabItem {
                    Label("115", systemImage: "cloud.fill")
                }

            SettingsTab()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .environmentObject(recents)
    }
}
