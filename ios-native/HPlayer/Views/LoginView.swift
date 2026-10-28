import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var password = ""
    @State private var error = ""
    @State private var loading = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            BrandLogo()

            Text("HPlayer").font(.largeTitle).bold()
            Text("115 网盘在线播放")
                .font(.subheadline)
                .foregroundColor(.secondary)

            SecureField("访问密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)

            if !error.isEmpty {
                Text(error).font(.footnote).foregroundColor(.red)
            }

            Button(loading ? "登录中…" : "进入") {
                Task {
                    loading = true
                    error = ""
                    do {
                        try await appState.login(password: password)
                    } catch let err {
                        error = err.localizedDescription
                    }
                    loading = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || loading)

            Spacer()
        }
        .padding(28)
    }
}
