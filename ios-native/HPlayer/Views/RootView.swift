import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HomeView()
            .task {
                await appState.checkAuth()
            }
    }
}
