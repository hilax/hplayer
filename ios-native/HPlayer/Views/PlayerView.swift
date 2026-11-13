import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissPlayerWindow) private var dismissPlayerWindow
    @StateObject private var playback = PlaybackController()
    @StateObject private var danmaku = DanmakuStore()
    @State private var current: PlaybackSource
    private let playlist: [PlaybackSource]
    @State private var loading = true
    @State private var error = ""
    @State private var directQualities: [Direct115Stream] = []
    /// 动漫这一集解析出的画质档位和请求头。current 始终保持集数引用不变，
    /// 换画质只重开流，不改 current——改了 id 就变，选集会认不出当前集，还会再触发一次加载。
    @State private var animeQualities: [PlaybackQualityItem] = []
    @State private var animeHeaders: [String: String] = [:]
    @State private var selectedQuality = ""
    @State private var visible = true
    @State private var requestID = UUID()
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
            loadingText: loadingText,
            error: error,
            items: playlist.map { PlaybackListItem(id: $0.id, title: $0.title, progress: RecentStore.shared.progress(for: $0)) },
            selectedID: current.id,
            qualities: qualityChoices,
            selectedQuality: selectedQuality,
            danmaku: animeRef == nil ? nil : danmaku,
            commentsVid: animeRef?.animeId,
            onSelect: { id in
                guard let selected = playlist.first(where: { $0.id == id }), selected != current else { return }
                saveProgress(force: true)
                playback.stop()
                requestID = UUID()
                current = selected
            },
            onQuality: { id in requestQuality(id) },
            onRetry: {
                let source = current
                Task { await load(source) }
            },
            onClose: { if let dismissPlayerWindow { dismissPlayerWindow() } else { dismiss() } }
        )
        .task(id: current.id) {
            // 不等转屏：要播放地址是网络请求，不占主线程，和转屏同时进行；
            // load 里只有真正打开视频那一步才等转屏结束。
            danmaku.configure(animeRef)
            // 暂停、换集、退出时截下的画面，存成这一集在「继续观看」里的封面（UI 测试不记）
            playback.resumeFrameKey = tracksHistory ? PlaybackFrameStore.key(for: current) : nil
            await load(current)
        }
        .onChange(of: playback.currentTime) { time in
            saveProgress(force: false)
            if animeRef != nil { danmaku.update(time: time) }
        }
        .onChange(of: appState.sessionID) { _ in
            guard case .p115 = current else { return }
            requestID = UUID()
            playback.stop()
            loading = false
            error = "115 登录已变更，请重新打开视频"
        }
        .onDisappear { saveProgress(force: true); visible = false; requestID = UUID(); playback.stop() }
    }

    private var animeRef: AnimeEpisodeRef? {
        if case .anime(let ref) = current { return ref }
        return nil
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
        guard tracksHistory, playback.duration > 0, let position = playback.confirmedTime else { return }
        guard force || Date().timeIntervalSince(lastSavedAt) >= 10 else { return }
        lastSavedAt = Date()
        RecentStore.shared.savePosition(for: current, seconds: position, duration: playback.duration)
    }

    private var loadingText: String {
        if case .anime = current { return "正在解析播放地址…" }
        if case .drama = current { return "正在获取播放地址…" }
        return "正在准备播放…"
    }

    private var qualityChoices: [PlaybackChoice] {
        switch current {
        case .anime:
            if !animeQualities.isEmpty {
                return animeQualities.map { PlaybackChoice(id: "online-\($0.id)", title: $0.title) }
            }
            return selectedQuality.isEmpty ? [] : [PlaybackChoice(id: "online-default", title: selectedQuality)]
        case .p115:
            // 原画直接播放原文件，不依赖 115 的转码
            return [PlaybackChoice(id: "direct-original", title: "原画")]
                + directQualities.enumerated().map { PlaybackChoice(id: "direct-\($0.offset)", title: $0.element.title) }
        case .online(_, _, _, let qualities, _):
            if !qualities.isEmpty {
                return qualities.map { PlaybackChoice(id: "online-\($0.id)", title: $0.title) }
            } else if !selectedQuality.isEmpty {
                return [PlaybackChoice(id: "online-default", title: selectedQuality)]
            } else {
                return [PlaybackChoice(id: "online-default", title: "1080P 高清")]
            }
        case .direct, .drama:
            return []
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
        loading = true; error = ""; directQualities = []; animeQualities = []; animeHeaders = [:]; selectedQuality = ""
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
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(url, direct115: use115Headers, directCookie: testCookie, startTime: resume)
            case .online(_, let url, let headers, let qualities, let currentQuality):
                selectedQuality = !currentQuality.isEmpty ? currentQuality : (qualities.first?.title ?? "1080P 高清")
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(url, customHeaders: headers, startTime: resume)
            case .anime(let ref):
                // 详情页记住最后看的一集：在播放器里切集、连播也算数
                ref.rememberAsLastWatched()
                let resolved = try await AnimePlaybackResolver.shared.resolve(episode: ref)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                animeQualities = resolved.qualities
                animeHeaders = resolved.headers
                selectedQuality = resolved.qualityTitle
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(resolved.url, customHeaders: resolved.headers, startTime: resume)
            case .drama(let ref):
                ref.rememberAsLastWatched()
                let dramaPlayback = try await DramaClient.shared.playback(videoId: ref.videoId, episode: ref.episode)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(dramaPlayback.url, customHeaders: dramaPlayback.headers, startTime: resume)
            case .p115(_, let pickCode):
                do {
                    guard let client = appState.directClient() else { throw APIError.server("请先登录 115") }
                    selectedQuality = "原画"
                    // 默认播原画：直接读原文件，不经过 115 转码，画质和音轨都是原样
                    var originalError: Error?
                    do {
                        let original = try await client.originalURL(pickCode: pickCode)
                        PlayerWindowController.shared.note("拿到原画地址")
                        guard await openAfterReveal(request, source: source, session: session) else { return }
                        playback.open(original, direct115: true, directCookie: client.cookie, startTime: resume,
                                      refreshURL: Self.originalRefresher(client, pickCode: pickCode))
                        loading = false
                    } catch {
                        guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                        originalError = error
                    }
                    // 转码画质只作为手动选项，原画失败时不要悄悄切换画质。
                    var streams: [Direct115Stream] = []
                    do { streams = try await client.streams(pickCode: pickCode) } catch {
                        if let originalError { throw originalError }
                    }
                    guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                    directQualities = streams
                    if let originalError {
                        throw APIError.server("原画无法打开：\(originalError.localizedDescription)。请重试或手动选择其他画质")
                    }
                }
            }
        } catch {
            if isCurrentRequest(request, source: source, session: session), !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    /// 打开视频前等播放器窗口转好屏：转屏期间主线程不被解码、建连接占住，转得更干净。
    /// 已经转好（或者是重试、没有播放器窗口）时立即返回。等待期间切了集、关了页面就不再打开。
    private func openAfterReveal(_ request: UUID, source: PlaybackSource, session: UUID) async -> Bool {
        await PlayerWindowController.shared.waitUntilRevealed()
        return isCurrentRequest(request, source: source, session: session) && !Task.isCancelled
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
            return try Direct115Stream.url(forQuality: title, in: streams)
        }
    }

    private func switchQuality(_ id: String, source: PlaybackSource) async -> UUID? {
        guard visible, !Task.isCancelled, current == source else { return nil }

        // 动漫画质切换：档位是这一集解析出来的，直接换地址重开，不用再解析一次。
        // current 不动，所以不会触发 .task(id:) 再加载一遍。
        if case .anime = source {
            guard let chosen = animeQualities.first(where: { "online-\($0.id)" == id }),
                  chosen.title != selectedQuality else { return nil }
            let request = UUID()
            requestID = request
            let session = appState.sessionID
            let preservePosition = playback.canRetryInPlace
            let savedPosition = preservePosition || !tracksHistory ? nil : RecentStore.shared.position(for: source)
            loading = true; error = ""
            defer { if isCurrentRequest(request, source: source, session: session) { loading = false } }
            selectedQuality = chosen.title
            playback.open(chosen.url, customHeaders: animeHeaders, preservingPosition: preservePosition, startTime: savedPosition)
            return request
        }

        // 在线动漫画质切换
        if case .online(let title, _, let headers, let qualities, _) = source {
            guard let chosen = qualities.first(where: { "online-\($0.id)" == id }),
                  chosen.title != selectedQuality else { return nil }
            let request = UUID()
            requestID = request
            let session = appState.sessionID
            let preservePosition = playback.canRetryInPlace
            let savedPosition = preservePosition || !tracksHistory ? nil : RecentStore.shared.position(for: source)
            loading = true; error = ""
            defer { if isCurrentRequest(request, source: source, session: session) { loading = false } }
            selectedQuality = chosen.title
            let updatedSource = PlaybackSource.online(
                title: title,
                url: chosen.url,
                headers: headers,
                qualities: qualities,
                currentQuality: chosen.title
            )
            current = updatedSource
            playback.open(chosen.url, customHeaders: headers, preservingPosition: preservePosition, startTime: savedPosition)
            return request
        }

        guard case .p115(_, let pickCode) = source,
              let client = appState.directClient() else { return nil }
        // 原画已经打开时无需重新发请求，也让尚在获取的转码菜单继续完成。
        if id == "direct-original", selectedQuality == "原画", !loading,
           error.isEmpty, playback.error.isEmpty, playback.canRetryInPlace { return nil }
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
        let preservePosition = playback.canRetryInPlace
        let savedPosition = preservePosition || !tracksHistory ? nil : RecentStore.shared.position(for: source)
        loading = true; error = ""
        defer { if isCurrentRequest(request, source: source, session: session) { loading = false } }
        do {
            if let requestedStream {
                let refreshed = try await client.streams(pickCode: pickCode)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return nil }
                guard let fresh = refreshed.first(where: { $0.title == requestedStream.title }) else { throw APIError.server("该画质暂不可用") }
                directQualities = refreshed; selectedQuality = fresh.title
                playback.open(fresh.url, direct115: true, directCookie: client.cookie, preservingPosition: preservePosition, startTime: savedPosition,
                              refreshURL: Self.streamRefresher(client, pickCode: pickCode, title: fresh.title))
            } else {
                let original = try await client.originalURL(pickCode: pickCode)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return nil }
                selectedQuality = "原画"
                playback.open(original, direct115: true, directCookie: client.cookie, preservingPosition: preservePosition, startTime: savedPosition,
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
