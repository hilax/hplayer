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
    @State private var requestID = UUID()
    @State private var lastSavedAt = Date.distantPast
    /// 这一集已经自动从原画换到转码过，不再反复换
    @State private var fellBack = false

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
                requestID = UUID()
                current = selected
            },
            onQuality: { id in requestQuality(id) },
            onRetry: {
                let source = current
                Task { await load(source) }
            },
            onClose: { dismiss() }
        )
        .task(id: current.id) { await load(current) }
        .onChange(of: playback.currentTime) { _ in saveProgress(force: false) }
        .onChange(of: playback.error) { _ in fallBackIfOriginalFails() }
        .onChange(of: appState.sessionID) { _ in
            guard case .p115 = current else { return }
            requestID = UUID()
            playback.stop()
            loading = false
            error = "115 登录已变更，请重新打开视频"
        }
        .onDisappear { saveProgress(force: true); visible = false; requestID = UUID(); playback.stop() }
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

    /// 原画一次都没播出来就失败了（有些文件 115 不让直接读原文件）：自动换成 115 转码画质
    private func fallBackIfOriginalFails() {
        guard !fellBack, selectedQuality == "原画", playback.failedBeforePlaying, !directQualities.isEmpty else { return }
        fellBack = true
        let title = directQualities[0].title
        let source = current
        let failedRequest = requestID
        Task {
            guard visible, current == source, requestID == failedRequest else { return }
            if let completedRequest = await switchQuality("direct-0", source: source),
               requestID == completedRequest, current == source, selectedQuality == title {
                playback.notice = "原画打不开，已自动换成「\(title)」"
            }
        }
    }

    /// 记播放历史会让首页「继续观看」重新排一遍；放到播放页进场动画走完之后再记，
    /// 免得首页在后面整页重算，和打开播放页抢主线程。
    private func recordWhenPresented(_ source: PlaybackSource) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard visible, current == source else { return }
            RecentStore.shared.record(source)
        }
    }

    private func load(_ source: PlaybackSource) async {
        guard visible, !Task.isCancelled, current == source else { return }
        let request = UUID()
        requestID = request
        let session = appState.sessionID
        loading = true; error = ""; directQualities = []; selectedQuality = ""; fellBack = false
        defer { if isCurrentRequest(request, source: source, session: session) { loading = false } }
        let resume = tracksHistory ? RecentStore.shared.position(for: source) : nil
        if tracksHistory { recordWhenPresented(source) }
        lastSavedAt = Date()
        do {
            switch source {
            case .direct(_, let url):
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
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
                        guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                        selectedQuality = "原画"
                        playback.open(original, direct115: true, directCookie: client.cookie, startTime: resume,
                                      refreshURL: Self.originalRefresher(client, pickCode: pickCode))
                        loading = false
                    } catch {
                        guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                        originalError = error
                    }
                    // 转码画质放进画质菜单备选；原文件拿不到时（例如文件被限制下载）才用转码播放
                    var streams: [Direct115Stream] = []
                    do { streams = try await client.streams(pickCode: pickCode) } catch {
                        if let originalError { throw originalError }
                    }
                    guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                    directQualities = streams
                    if let originalError {
                        guard let first = streams.first else { throw originalError }
                        selectedQuality = first.title
                        playback.open(first.url, direct115: true, directCookie: client.cookie, startTime: resume,
                                      refreshURL: Self.streamRefresher(client, pickCode: pickCode, title: first.title))
                    }
                }
            }
        } catch {
            if isCurrentRequest(request, source: source, session: session), !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    /// 旧的同集加载、重试或画质请求也可能晚到；只有当前请求可以更新播放器。
    private func isCurrentRequest(_ request: UUID, source: PlaybackSource, session: UUID) -> Bool {
        guard visible, requestID == request, current == source else { return false }
        if case .p115 = source { return appState.sessionID == session }
        return true
    }

    private func requestQuality(_ id: String) {
        let source = current
        Task { _ = await switchQuality(id, source: source) }
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

    private func switchQuality(_ id: String, source: PlaybackSource) async -> UUID? {
        guard visible, !Task.isCancelled, current == source,
              case .p115(_, let pickCode) = source,
              let client = appState.directClient() else { return nil }
        // 原画已经打开时无需重新发请求，也让尚在获取的转码菜单继续完成。
        if id == "direct-original", selectedQuality == "原画", !loading { return nil }
        let requestedStream: Direct115Stream?
        if id == "direct-original" {
            requestedStream = nil
        } else {
            guard id.hasPrefix("direct-"), let index = Int(id.dropFirst(7)),
                  directQualities.indices.contains(index) else { return nil }
            requestedStream = directQualities[index]
        }
        let request = UUID()
        requestID = request
        let session = appState.sessionID
        loading = true; error = ""
        defer { if isCurrentRequest(request, source: source, session: session) { loading = false } }
        do {
            if let requestedStream {
                let refreshed = try await client.streams(pickCode: pickCode)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return nil }
                guard let fresh = refreshed.first(where: { $0.title == requestedStream.title }) else { throw APIError.server("该画质暂不可用") }
                directQualities = refreshed; selectedQuality = fresh.title
                playback.open(fresh.url, direct115: true, directCookie: client.cookie, preservingPosition: true,
                              refreshURL: Self.streamRefresher(client, pickCode: pickCode, title: fresh.title))
            } else {
                let original = try await client.originalURL(pickCode: pickCode)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return nil }
                selectedQuality = "原画"
                playback.open(original, direct115: true, directCookie: client.cookie, preservingPosition: true,
                              refreshURL: Self.originalRefresher(client, pickCode: pickCode))
            }
            return request
        } catch {
            if isCurrentRequest(request, source: source, session: session), !Task.isCancelled {
                self.error = error.localizedDescription
            }
            return nil
        }
    }
}
