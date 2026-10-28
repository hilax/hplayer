import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if !appState.hasServer {
                ServerSetupView()
            } else if appState.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("连接中…").foregroundColor(.secondary)
                }
            } else if !appState.isAuthenticated {
                LoginView()
            } else {
                LibraryView()
            }
        }
        .task {
            await appState.checkAuth()
        }
    }
}
