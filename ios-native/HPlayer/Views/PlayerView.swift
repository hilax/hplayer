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
    @State private var directQualitiesFetchedAt: TimeInterval?
    @State private var directQualityListTask: Task<Void, Never>?
    @State private var directQualityListError: String?
    @State private var directQualityListID = UUID()
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
            qualityStatus: directQualityStatus,
            danmaku: animeRef == nil ? nil : danmaku,
            commentsVid: animeRef?.animeId,
            onSelect: { id in
                guard let selected = playlist.first(where: { $0.id == id }), selected != current else { return }
                saveProgress(force: true)
                playback.stop()
                resetDirectQualities()
                requestID = UUID()
                current = selected
            },
            onOpenQuality: { loadDirectQualities() },
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
        .onChange(of: playback.hasPlayed) { started in
            if started, !loading, selectedQuality == "原画", directQualitiesFetchedAt == nil {
                loadDirectQualities()
            }
        }
        .onChange(of: appState.sessionID) { _ in
            guard case .p115 = current else { return }
            requestID = UUID()
            playback.stop()
            resetDirectQualities()
            loading = false
            error = "115 登录已变更，请重新打开视频"
        }
        .onDisappear {
            saveProgress(force: true)
            visible = false
            requestID = UUID()
            resetDirectQualities()
            playback.stop()
        }
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
        if case .jable = current { return "正在解析 Jable 视频…" }
        if case .missav = current { return "正在解析 MissAV 视频…" }
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
        case .direct, .drama, .jable, .missav:
            return []
        }
    }

    private var directQualityStatus: String? {
        guard case .p115 = current else { return nil }
        if directQualityListTask != nil { return "正在获取转码画质…" }
        if directQualityListError != nil { return "暂时无法获取转码画质" }
        return nil
    }

    private var directQualitiesAreFresh: Bool {
        // 签名地址只在同一部视频、同一次登录里短时复用。上游拒绝时中转仍会自动刷新。
        guard let fetched = directQualitiesFetchedAt else { return false }
        return ProcessInfo.processInfo.systemUptime - fetched < 45
    }

    private func resetDirectQualities() {
        directQualityListID = UUID()
        directQualityListTask?.cancel()
        directQualityListTask = nil
        directQualityListError = nil
        directQualitiesFetchedAt = nil
        directQualities = []
    }

    @discardableResult
    private func loadDirectQualities() -> Task<Void, Never>? {
        guard visible, !directQualitiesAreFresh, case .p115(_, let pickCode) = current,
              let client = appState.directClient() else { return nil }
        if let directQualityListTask { return directQualityListTask }
        let request = directQualityListID
        let source = current
        let session = appState.sessionID
        directQualityListError = nil
        let task = Task { @MainActor in
            let result: Result<[Direct115Stream], Error>
            do { result = .success(try await client.streams(pickCode: pickCode)) }
            catch { result = .failure(error) }
            guard visible, !Task.isCancelled, directQualityListID == request,
                  current == source, appState.sessionID == session else { return }
            directQualityListTask = nil
            switch result {
            case .success(let streams):
                directQualities = streams
                directQualitiesFetchedAt = ProcessInfo.processInfo.systemUptime
            case .failure(let error):
                directQualityListError = error.localizedDescription
            }
        }
        directQualityListTask = task
        return task
    }

    /// 记播放历史会让首页「继续观看」重新排一遍；放到播放页进场动画走完之后再记，
    /// 免得首页在后面整页重算，和打开播放页抢主线程。
    private func recordWhenPresented(_ source: PlaybackSource) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard visible, current == source else { return }
            RecentStore.shared.record(source)
            // 连同这一集所在的整份列表一起记下：从「继续观看」打开时选集里还有上一集、下一集
            RecentPlaylistStore.shared.remember(playlist, current: source,
                                                keep: Set(RecentStore.shared.items.map(RecentStore.key(of:))))
        }
    }

    private func load(_ source: PlaybackSource) async {
        guard visible, !Task.isCancelled, current == source else { return }
        let request = UUID()
        requestID = request
        let session = appState.sessionID
        resetDirectQualities()
        loading = true; error = ""; animeQualities = []; animeHeaders = [:]; selectedQuality = ""
        defer { if isCurrentRequest(request, source: source, session: session) { loading = false } }
        let resume = tracksHistory ? RecentStore.shared.position(for: source) : nil
        if tracksHistory { recordWhenPresented(source) }
        lastSavedAt = Date()
        do {
            switch source {
            case .direct(let title, let url):
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                #if DEBUG
                let use115Headers = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_115_HEADERS"] == "1"
                let testCookie = ProcessInfo.processInfo.environment["HPLAYER_UI_TEST_115_COOKIE"] ?? ""
                #else
                let use115Headers = false
                let testCookie = ""
                #endif
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(url, direct115: use115Headers, directCookie: testCookie, startTime: resume, title: title)
            case .online(let title, let url, let headers, let qualities, let currentQuality):
                selectedQuality = !currentQuality.isEmpty ? currentQuality : (qualities.first?.title ?? "1080P 高清")
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(url, customHeaders: headers, startTime: resume, title: title)
            case .anime(let ref):
                // 详情页记住最后看的一集：在播放器里切集、连播也算数
                ref.rememberAsLastWatched()
                let resolved = try await AnimePlaybackResolver.shared.resolve(episode: ref)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                animeQualities = resolved.qualities
                animeHeaders = resolved.headers
                selectedQuality = resolved.qualityTitle
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(resolved.url, customHeaders: resolved.headers, startTime: resume, title: ref.episodeTitle)
            case .drama(let ref):
                ref.rememberAsLastWatched()
                let dramaPlayback = try await DramaClient.shared.playback(videoId: ref.videoId, episode: ref.episode)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(dramaPlayback.url, customHeaders: dramaPlayback.headers, startTime: resume, title: ref.episodeTitle)
            case .jable(let ref):
                ref.rememberAsLastWatched()
                let jablePlayback = try await JableClient.shared.resolvePlayback(videoId: ref.videoId)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(jablePlayback.url, customHeaders: jablePlayback.headers, startTime: resume,
                              title: ref.title, subtitleIdentifier: ref.videoId, isAdultVideo: true)
            case .missav(let ref):
                ref.rememberAsLastWatched()
                let missavPlayback = try await MissAVClient.shared.resolvePlayback(videoId: ref.videoId)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                guard await openAfterReveal(request, source: source, session: session) else { return }
                playback.open(missavPlayback.url, customHeaders: missavPlayback.headers, startTime: resume,
                              title: ref.title, subtitleIdentifier: ref.videoId, isAdultVideo: true)
            case .p115(let title, let pickCode):
                guard let client = appState.directClient() else { throw APIError.server("请先登录 115") }
                selectedQuality = "原画"
                do {
                    let original = try await client.originalURL(pickCode: pickCode)
                    PlayerWindowController.shared.note("拿到原画地址")
                    guard await openAfterReveal(request, source: source, session: session) else { return }
                    playback.open(original, direct115: true, directCookie: client.cookie, startTime: resume,
                                  refreshURL: Self.originalRefresher(client, pickCode: pickCode),
                                  streamID: "p115:\(pickCode)", title: title, subtitleIdentifier: pickCode)
                    // 转码列表由首次播放事件或用户打开菜单触发。
                } catch {
                    guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return }
                    loadDirectQualities()
                    throw APIError.server("原画无法打开：\(error.localizedDescription)。请重试或手动选择其他画质")
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
        { try await client.originalURL(pickCode: pickCode, useCache: false) }
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

        guard case .p115(let title, let pickCode) = source,
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
                if let task = loadDirectQualities() { await task.value }
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return nil }
                guard directQualitiesAreFresh else { throw APIError.server(directQualityListError ?? "该画质暂不可用") }
                let url = try Direct115Stream.url(forQuality: requestedStream.title, in: directQualities)
                selectedQuality = requestedStream.title
                let refresher = Self.streamRefresher(client, pickCode: pickCode, title: requestedStream.title)
                playback.open(url, direct115: true, directCookie: client.cookie, preservingPosition: preservePosition, startTime: savedPosition,
                              refreshURL: refresher, streamID: "p115:\(pickCode):hls:\(requestedStream.title)", playlistRenew: refresher,
                              title: title, subtitleIdentifier: pickCode)
            } else {
                let original = try await client.originalURL(pickCode: pickCode)
                guard isCurrentRequest(request, source: source, session: session), !Task.isCancelled else { return nil }
                selectedQuality = "原画"
                playback.open(original, direct115: true, directCookie: client.cookie, preservingPosition: preservePosition, startTime: savedPosition,
                              refreshURL: Self.originalRefresher(client, pickCode: pickCode),
                              streamID: "p115:\(pickCode)", title: title, subtitleIdentifier: pickCode)
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
