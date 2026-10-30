import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = PlaybackController()
    @State private var current: PlaybackSource
    private let playlist: [PlaybackSource]
    @State private var loading = true
    @State private var error = ""
    @State private var directQualities: [Direct115Stream] = []
    @State private var selectedQuality = ""
    @State private var visible = true
    @State private var lastSavedAt = Date.distantPast

    init(source: PlaybackSource, playlist: [PlaybackSource] = []) {
        _current = State(initialValue: source)
        self.playlist = playlist.contains(source) ? playlist : [source]
    }

    var body: some View {
        PlaybackControlsView(
            playback: playback,
            title: current.title,
            loading: loading,
            error: error,
            items: playlist.map { PlaybackListItem(id: $0.id, title: $0.title) },
            selectedID: current.id,
            qualities: qualityChoices,
            selectedQuality: selectedQuality,
            onSelect: { id in
                guard let selected = playlist.first(where: { $0.id == id }), selected != current else { return }
                saveProgress(force: true)
                if playback.playing { playback.toggle() }
                current = selected
            },
            onQuality: { id in Task { await switchQuality(id) } },
            onRetry: { Task { await load(current) } },
            onClose: { dismiss() }
        )
        .task(id: current.id) { await load(current) }
        .onChange(of: playback.currentTime) { _ in saveProgress(force: false) }
        .onDisappear { saveProgress(force: true); visible = false; playback.stop() }
    }

    /// UI 测试不写播放记录，免得下次启动从中间开始
    private var tracksHistory: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_URL"] == nil
        #else
        return true
        #endif
    }

    /// 每 10 秒记一次看到的位置；切集和退出时立即记
    private func saveProgress(force: Bool) {
        guard tracksHistory, playback.duration > 0, playback.currentTime > 0 else { return }
        guard force || Date().timeIntervalSince(lastSavedAt) >= 10 else { return }
        lastSavedAt = Date()
        RecentStore.shared.savePosition(for: current, seconds: playback.currentTime, duration: playback.duration)
    }

    private var qualityChoices: [PlaybackChoice] {
        guard case .p115 = current else { return [] }
        // 原画直接播放原文件，不依赖 115 的转码
        return [PlaybackChoice(id: "direct-original", title: "原画")]
            + directQualities.enumerated().map { PlaybackChoice(id: "direct-\($0.offset)", title: $0.element.title) }
    }

    private func load(_ source: PlaybackSource) async {
        loading = true; error = ""; directQualities = []; selectedQuality = ""
        let resume = tracksHistory ? RecentStore.shared.position(for: source) : nil
        if tracksHistory { RecentStore.shared.record(source) }
        lastSavedAt = Date()
        do {
            switch source {
            case .direct(_, let url):
                guard visible && !Task.isCancelled && current == source else { return }
                #if DEBUG
                let use115Headers = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_115_HEADERS"] == "1"
                let testCookie = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_115_COOKIE"] ?? ""
                #else
                let use115Headers = false
                let testCookie = ""
                #endif
                playback.open(url, direct115: use115Headers, directCookie: testCookie, startTime: resume)
            case .p115(_, let pickCode):
                do {
                    guard let client = appState.directClient() else { throw APIError.server("请先登录 115") }
                    // 默认播原画：直接读原文件，不经过 115 转码，画质和音轨都是原样
                    var originalError: Error?
                    do {
                        let original = try await client.originalURL(pickCode: pickCode)
                        guard visible && !Task.isCancelled && current == source else { return }
                        selectedQuality = "原画"
                        playback.open(original, direct115: true, directCookie: client.cookie, startTime: resume,
                                      refreshURL: Self.originalRefresher(client, pickCode: pickCode))
                        loading = false
                    } catch {
                        originalError = error
                    }
                    // 转码画质放进画质菜单备选；原文件拿不到时（例如文件被限制下载）才用转码播放
                    var streams: [Direct115Stream] = []
                    do { streams = try await client.streams(pickCode: pickCode) } catch {
                        if let originalError { throw originalError }
                    }
                    guard visible && !Task.isCancelled && current == source else { return }
                    directQualities = streams
                    if let originalError {
                        guard let first = streams.first else { throw originalError }
                        selectedQuality = first.title
                        playback.open(first.url, direct115: true, directCookie: client.cookie, startTime: resume,
                                      refreshURL: Self.streamRefresher(client, pickCode: pickCode, title: first.title))
                    }
                }
            }
        } catch { if visible && !Task.isCancelled && current == source { self.error = error.localizedDescription } }
        if visible && !Task.isCancelled && current == source { loading = false }
    }

    /// 自动重连时换新的 115 原画地址：旧地址可能已过期，或者连接被 115 限制
    private static func originalRefresher(_ client: Direct115Client, pickCode: String) -> () async throws -> URL {
        { try await client.originalURL(pickCode: pickCode) }
    }

    /// 自动重连时换新的 115 转码地址，按画质名称找回同一档
    private static func streamRefresher(_ client: Direct115Client, pickCode: String, title: String) -> () async throws -> URL {
        {
            let streams = try await client.streams(pickCode: pickCode)
            guard let match = streams.first(where: { $0.title == title }) ?? streams.first else {
                throw APIError.server("该画质暂不可用")
            }
            return match.url
        }
    }

    private func switchQuality(_ id: String) async {
        guard case .p115(_, let pickCode) = current else { return }
        let source = current
        loading = true; error = ""
        defer { loading = false }
        do {
            if id == "direct-original", let client = appState.directClient() {
                let original = try await client.originalURL(pickCode: pickCode)
                guard visible && !Task.isCancelled && current == source else { return }
                selectedQuality = "原画"
                playback.open(original, direct115: true, directCookie: client.cookie, preservingPosition: true,
                              refreshURL: Self.originalRefresher(client, pickCode: pickCode))
            } else if id.hasPrefix("direct-"), let index = Int(id.dropFirst(7)), directQualities.indices.contains(index), let client = appState.directClient() {
                let old = directQualities[index]
                let refreshed = try await client.streams(pickCode: pickCode)
                guard visible && !Task.isCancelled && current == source else { return }
                guard let fresh = refreshed.first(where: { $0.title == old.title }) else { throw APIError.server("该画质暂不可用") }
                directQualities = refreshed; selectedQuality = fresh.title
                playback.open(fresh.url, direct115: true, directCookie: client.cookie, preservingPosition: true,
                              refreshURL: Self.streamRefresher(client, pickCode: pickCode, title: fresh.title))
            }
        } catch { if visible && current == source { self.error = error.localizedDescription } }
    }
}
