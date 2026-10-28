import AVKit
import SwiftUI

private struct Open115Playback: Decodable {
    let qualities: [Open115Quality]
}

private struct Open115Quality: Decodable {
    let url: String
    let title: String
    let definition: String
    let width: Int
    let height: Int

    var label: String {
        if !title.isEmpty { return title }
        if height > 0 { return "\(height)P" }
        return "清晰度 \(definition)"
    }
}

struct PlayerView: View {
    let source: PlaybackSource

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var media: MediaInfo?
    @State private var error = ""
    @State private var loading = true
    @State private var originalURL: URL?
    @State private var qualities: [Open115Quality] = []
    @State private var directQualities: [Direct115Stream] = []
    @State private var selectedQuality = "原画"
    @State private var isOfficialQuality = false
    @State private var switchingQuality = false
    @State private var qualityError = ""
    @State private var visible = true
    @State private var playerObservation: NSKeyValueObservation?

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
                        Text(isOfficialQuality ? "115 官方转码 · \(selectedQuality)" : (media.directPlay ? "直连 115 CDN" : "服务端转封装"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                if !qualities.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("播放画质").font(.headline)
                            Text("115 官方转码画质与会员权益相关")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if switchingQuality { ProgressView().padding(.trailing, 4) }
                        Menu {
                            if originalURL != nil {
                                Button("原画（原有播放方式）") { selectOriginal() }
                            }
                            ForEach(Array(qualities.enumerated()), id: \.offset) { _, quality in
                                Button(quality.label) {
                                    Task { await selectQuality(quality) }
                                }
                            }
                        } label: {
                            Label(selectedQuality, systemImage: "chevron.up.chevron.down")
                                .font(.subheadline.weight(.medium))
                        }
                        .disabled(switchingQuality)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                if !directQualities.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("115 在线画质").font(.headline)
                            Text("手机直连，画质与账号及片源有关")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if switchingQuality { ProgressView().padding(.trailing, 4) }
                        Menu {
                            ForEach(directQualities) { quality in
                                Button(quality.title) { Task { await selectDirect(quality) } }
                            }
                        } label: {
                            Label(selectedQuality, systemImage: "chevron.up.chevron.down")
                                .font(.subheadline.weight(.medium))
                        }
                        .disabled(switchingQuality)
                    }
                    .padding(.horizontal).padding(.vertical, 12)
                }
                if !qualityError.isEmpty {
                    Text(qualityError)
                        .font(.caption).foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle(source.title)
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
                visible = false
                playerObservation = nil
                player?.currentItem?.cancelPendingSeeks()
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
        loading = true
        error = ""

        if appState.isDirect, case .p115(_, let pickCode) = source {
            await loadDirect(pickCode)
            loading = false
            return
        }

        await loadOriginal()
        loading = false
        if case .p115(_, let pickCode) = source, !Task.isCancelled {
            // A failure here (for example, Cookie mode) must not interrupt original playback.
            await loadQualities(pickCode)
        }
    }

    private func loadDirect(_ pickCode: String) async {
        guard let client = appState.directClient() else { error = "请先登录 115"; return }
        do {
            let streams = try await client.streams(pickCode: pickCode)
            guard visible && !Task.isCancelled, let first = streams.first else { return }
            directQualities = streams
            selectedQuality = first.title
            play(first.url, preservingPosition: false, directHeaders: true)
        } catch { self.error = error.localizedDescription }
    }

    private func selectDirect(_ quality: Direct115Stream) async {
        guard case .p115(_, let pickCode) = source, let client = appState.directClient() else { return }
        switchingQuality = true
        qualityError = ""
        defer { switchingQuality = false }
        do {
            let streams = try await client.streams(pickCode: pickCode)
            guard visible && !Task.isCancelled else { return }
            guard let fresh = streams.first(where: { $0.title == quality.title }) else { throw APIError.server("该画质暂不可用") }
            directQualities = streams
            selectedQuality = fresh.title
            play(fresh.url, preservingPosition: true, directHeaders: true)
        } catch { qualityError = error.localizedDescription }
    }

    private func loadOriginal() async {
        do {
            let url: URL

            switch source {
            case .direct(_, let directURL):
                url = directURL

            case .p115(_, let pickCode):
                guard let client = appState.client() else {
                    throw APIError.server("未连接服务器")
                }
                let info: MediaInfo = try await client.get("/api/probe?pickcode=\(pickCode)")
                media = info

                let path = info.directPlay
                    ? "/api/play/\(pickCode)"
                    : "/api/hls/\(pickCode)/index.m3u8"

                guard let mediaURL = appState.mediaURL(path) else {
                    throw APIError.badURL
                }
                url = mediaURL
            }

            originalURL = url
            guard !Task.isCancelled && visible else { return }
            play(url, preservingPosition: false)
        } catch let err {
            error = err.localizedDescription
        }
    }

    private func fetchQualities(_ pickCode: String) async throws -> [Open115Quality] {
        guard let client = appState.client(),
              let encoded = pickCode.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw APIError.badURL
        }
        let result: Open115Playback = try await client.get("/api/115/open/play?pickCode=\(encoded)")
        return result.qualities
    }

    private func loadQualities(_ pickCode: String) async {
        guard let result = try? await fetchQualities(pickCode), !Task.isCancelled else { return }
        qualities = result
        if originalURL == nil && !result.isEmpty {
            error = "原画暂时无法播放，可选择 115 官方转码画质。"
            selectedQuality = "选择画质"
        }
    }

    private func selectOriginal() {
        guard let originalURL else { return }
        qualityError = ""
        selectedQuality = "原画"
        isOfficialQuality = false
        play(originalURL, preservingPosition: true)
    }

    private func selectQuality(_ quality: Open115Quality) async {
        guard case .p115(_, let pickCode) = source else { return }
        switchingQuality = true
        qualityError = ""
        defer { switchingQuality = false }
        do {
            // Playback URLs expire, so resolve a fresh URL each time a quality is selected.
            let refreshed = try await fetchQualities(pickCode)
            guard visible && !Task.isCancelled else { return }
            guard let current = refreshed.first(where: { $0.definition == quality.definition && $0.title == quality.title }),
                  let url = URL(string: current.url),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
                throw APIError.server("该画质暂不可用，请重新选择")
            }
            qualities = refreshed
            selectedQuality = current.label
            isOfficialQuality = true
            play(url, preservingPosition: true)
        } catch {
            qualityError = error.localizedDescription
        }
    }

    private func play(_ url: URL, preservingPosition: Bool, directHeaders: Bool = false) {
        let position = preservingPosition ? player?.currentTime() : nil
        let shouldPlay = player?.timeControlStatus != .paused || player == nil
        let asset: AVURLAsset
        if directHeaders {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Direct115Client.userAgent, "Referer": "https://115.com/"]])
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        playerObservation = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard visible, player?.currentItem === item else { return }
                qualityError = "播放失败，请尝试其他画质或检查 115 账号权益。"
            }
        }
        let currentPlayer = player ?? AVPlayer()
        currentPlayer.replaceCurrentItem(with: item)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = currentPlayer
        if let position, position.isNumeric, position.seconds > 0 {
            currentPlayer.seek(to: position) { finished in
                if finished && shouldPlay { currentPlayer.play() }
            }
        } else if shouldPlay {
            currentPlayer.play()
        }
    }
}
