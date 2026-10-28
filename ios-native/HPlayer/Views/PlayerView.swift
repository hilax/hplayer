import AVKit
import SwiftUI

struct PlayerView: View {
    let file: P115File

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var media: MediaInfo?
    @State private var error = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                } else {
                    ZStack {
                        Color.black
                        if loading {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("正在准备播放…")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(error)
                                .foregroundColor(.red)
                                .padding()
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                }

                if let media {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(codecLine(media))
                            .font(.subheadline)
                        Text(media.directPlay ? "直连 115 CDN" : "服务端转封装")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                Spacer()
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                await load()
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private func codecLine(_ media: MediaInfo) -> String {
        var parts = ["\(media.width)×\(media.height)"]
        if !media.videoCodec.isEmpty {
            parts.append(media.videoCodec.uppercased())
        }
        if !media.audioCodec.isEmpty {
            parts.append(media.audioCodec.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = appState.client() else {
            error = "未连接服务器"
            loading = false
            return
        }

        loading = true
        error = ""

        do {
            let info: MediaInfo = try await client.get("/api/probe?pickcode=\(file.pickCode)")
            media = info

            let path = info.directPlay
                ? "/api/play/\(file.pickCode)"
                : "/api/hls/\(file.pickCode)/index.m3u8"

            guard let url = appState.mediaURL(path) else {
                throw APIError.badURL
            }

            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item)

            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)

            player = newPlayer
            newPlayer.play()
        } catch let err {
            error = err.localizedDescription
        }

        loading = false
    }
}
