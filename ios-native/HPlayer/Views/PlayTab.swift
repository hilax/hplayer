import SwiftUI

struct PlayTab: View {
    @EnvironmentObject private var recents: RecentStore

    @State private var urlText = ""
    @State private var playing: PlaybackSource?
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://example.com/video.mp4", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("播放") {
                        start()
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("打开链接")
                } footer: {
                    Text("支持 mp4、m3u8 等 AVPlayer 可播放的地址")
                }

                if !recents.items.isEmpty {
                    Section("最近播放") {
                        ForEach(recents.items) { item in
                            Button {
                                if let url = URL(string: item.url) {
                                    playing = .direct(title: item.title, url: url)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .lineLimit(1)
                                        .foregroundColor(.primary)
                                    Text(item.url)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete { offsets in
                            recents.remove(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle("播放")
            .fullScreenCover(item: $playing) { source in
                PlayerView(source: source)
                    .environmentObject(recents)
            }
        }
    }

    private func start() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            error = "请输入有效的视频链接"
            return
        }

        error = ""
        let title = url.lastPathComponent.isEmpty ? trimmed : url.lastPathComponent
        recents.add(title: title, url: url)
        playing = .direct(title: title, url: url)
    }
}
