import SwiftUI

struct ServerSetupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var url = ""
    @State private var error = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            BrandLogo()

            Text("连接服务器").font(.title2).bold()
            Text("填写 HPlayer 后端地址")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("https://hplayer.example.com", text: $url)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !error.isEmpty {
                Text(error).font(.footnote).foregroundColor(.red)
            }

            Button("保存") {
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = trimmed.lowercased()
                guard !trimmed.isEmpty else {
                    error = "请填写服务器地址"
                    return
                }
                guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
                    error = "地址需要以 http:// 或 https:// 开头"
                    return
                }
                error = ""
                appState.setServer(trimmed)
                Task { await appState.checkAuth() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .padding(28)
    }
}

struct BrandLogo: View {
    var body: some View {
        Text("H")
            .font(.system(size: 46, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 88, height: 88)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.31, green: 0.55, blue: 1.0),
                        Color(red: 0.48, green: 0.36, blue: 1.0),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
