import SwiftUI
import UIKit

// 磁力聚合的三个下钻页面：女优页、片商页、磁力详情页。
// 都是普通的逐层跳转（左上角返回上一层），版式见设计稿。

// MARK: - 女优作品列表页 (StarMoviesView)

/// 女优页的作品范围。
private enum StarWorksMode: String, CaseIterable, Identifiable {
    /// 她本人主演的片子（按名字搜索）。
    case lead
    /// 女优页列出的全部参演作品，包含她出镜的合集、BEST、多人作品。
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lead: return "主演作品"
        case .all: return "全部参演"
        }
    }

    var hint: String {
        switch self {
        case .lead: return "只列她本人主演的作品，新片在前。"
        case .all: return "站点收录的全部参演作品，包含她出镜的合集、BEST 与多人作品。"
        }
    }
}

/// 「主演作品 / 全部参演」切换：选中项是金底深字。
private struct StarModePicker: View {
    @Binding var mode: StarWorksMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StarWorksMode.allCases) { option in
                let selected = mode == option
                Button {
                    guard !selected else { return }
                    Haptics.select()
                    withAnimation(Motion.snappy) { mode = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.primaryAction)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("magnet.star.mode.\(option.rawValue)")
            }
        }
        .padding(3)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

struct StarMoviesView: View {
    let star: MagnetStarItem

    @State private var mode: StarWorksMode = .lead
    @State private var movies: [MagnetSearchItem] = []
    @State private var detailedStar: MagnetStarItem?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var paging = PagingState()

    private var shownStar: MagnetStarItem { detailedStar ?? star }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                starHeader

                VStack(alignment: .leading, spacing: 10) {
                    StarModePicker(mode: $mode)
                    Text(mode.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 20)

                MagnetMovieGridFeed(
                    emptyText: mode == .lead ? "没有找到她主演的作品，可以切换到「全部参演」查看" : "暂无参演作品",
                    movies: movies,
                    isLoading: isLoading,
                    errorText: errorText,
                    paging: paging,
                    retry: { Task { await loadFirstPage() } },
                    loadMore: { Task { await loadMore() } }
                )
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background {
            // 头像上方一团暖色光晕，让抬头有层次。
            ZStack(alignment: .top) {
                Theme.pageBackground
                RadialGradient(
                    colors: [Theme.accent.opacity(0.16), Color.clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 360
                )
                .frame(height: 360)
            }
            .ignoresSafeArea()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .onChange(of: mode) { _ in
            Task { await loadFirstPage() }
        }
        .task {
            // 从下一层返回时页面会再次出现，已经加载好的内容不重新加载。
            guard movies.isEmpty, errorText == nil else { return }
            async let header: Void = loadHeader()
            await loadFirstPage()
            await header
        }
    }

    private var starHeader: some View {
        VStack(spacing: 0) {
            MagnetStarAvatar(star: shownStar, size: 96, ringed: true)

            Text(shownStar.name)
                .font(.display(26))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            if let bio = shownStar.bio, !bio.isEmpty {
                Text(bio)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    /// 头部资料（身高、罩杯等）来自女优页；取不到不影响作品列表。
    @MainActor
    private func loadHeader() async {
        guard detailedStar == nil else { return }
        if let result = try? await JavBusSource.shared.fetchStarDetail(starPath: star.detailPath, page: 1) {
            detailedStar = result.star
        }
    }

    @MainActor
    private func loadFirstPage() async {
        let requested = mode
        isLoading = true
        errorText = nil
        paging = PagingState()
        movies = []
        do {
            let list = try await fetch(page: 1, mode: requested)
            // 加载期间切换了范围：结果作废，由新范围的加载来写。
            guard requested == mode else { return }
            movies = mergeUnique([], with: list).merged
            paging.hasMore = !list.isEmpty
            isLoading = false
        } catch {
            // 页面被关闭时任务会被取消，不用再更新界面。
            if error is CancellationError { return }
            guard requested == mode else { return }
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func loadMore() async {
        guard !isLoading, paging.hasMore, !paging.isLoadingMore else { return }
        let requested = mode
        paging.isLoadingMore = true
        paging.loadMoreFailed = false
        let nextPage = paging.page + 1
        do {
            let list = try await fetch(page: nextPage, mode: requested)
            guard requested == mode else { return }
            let result = mergeUnique(movies, with: list)
            movies = result.merged
            paging.hasMore = result.added > 0
            paging.page = nextPage
            paging.isLoadingMore = false
        } catch {
            if error is CancellationError { paging.isLoadingMore = false; return }
            guard requested == mode else { return }
            paging.isLoadingMore = false
            paging.loadMoreFailed = true
        }
    }

    @MainActor
    private func fetch(page: Int, mode: StarWorksMode) async throws -> [MagnetSearchItem] {
        switch mode {
        case .lead:
            return try await JavBusSource.shared.fetchLeadMovies(starName: star.name, page: page)
        case .all:
            let (info, list) = try await JavBusSource.shared.fetchStarDetail(starPath: star.detailPath, page: page)
            if detailedStar == nil, let info { detailedStar = info }
            return list
        }
    }
}

// MARK: - 片商作品列表页 (StudioMoviesView)

struct StudioMoviesView: View {
    let studio: MagnetStudio

    @State private var movies: [MagnetSearchItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var paging = PagingState()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                studioHeader
                    .padding(.horizontal, Theme.contentInset)
                    .padding(.top, 8)

                MagnetMovieGridFeed(
                    emptyText: "暂无作品",
                    movies: movies,
                    isLoading: isLoading,
                    errorText: errorText,
                    paging: paging,
                    retry: { Task { await loadFirstPage() } },
                    loadMore: { Task { await loadMore() } }
                )
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .task {
            guard movies.isEmpty, errorText == nil else { return }
            await loadFirstPage()
        }
    }

    private var studioHeader: some View {
        HStack(spacing: 16) {
            Text(studio.monogram)
                .font(.display(20))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(studio.title)
                    .font(.display(26))
                    .foregroundStyle(.primary)
                Text(studio.codeHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottomTrailing) {
            Text(studio.title)
                .font(.display(84))
                .foregroundStyle(Color.primary.opacity(0.05))
                .lineLimit(1)
                .fixedSize()
                .offset(x: 8, y: 22)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .surfaceCard()
    }

    @MainActor
    private func loadFirstPage() async {
        isLoading = true
        errorText = nil
        paging = PagingState()
        do {
            let list = try await JavBusSource.shared.fetchStudio(studio, page: 1)
            movies = mergeUnique([], with: list).merged
            paging.hasMore = !list.isEmpty
            isLoading = false
        } catch {
            if error is CancellationError { return }
            errorText = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func loadMore() async {
        guard !isLoading, paging.hasMore, !paging.isLoadingMore else { return }
        paging.isLoadingMore = true
        paging.loadMoreFailed = false
        let nextPage = paging.page + 1
        do {
            let list = try await JavBusSource.shared.fetchStudio(studio, page: nextPage)
            let result = mergeUnique(movies, with: list)
            movies = result.merged
            paging.hasMore = result.added > 0
            paging.page = nextPage
            paging.isLoadingMore = false
        } catch {
            paging.isLoadingMore = false
            if error is CancellationError { return }
            paging.loadMoreFailed = true
        }
    }
}

// MARK: - 磁力详情页 (MagnetDetailView，带女优下钻)

/// 一条磁力资源：标签、大小、日期、文件名，以及「播放」「复制」两个操作。
private struct MagnetTorrentCard: View {
    let torrent: MagnetTorrentItem
    let highlighted: Bool
    let playTitle: String
    let copied: Bool
    var saveState: Offline115SaveState = .idle
    let onPlay: () -> Void
    var onSave: () -> Void = {}
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if torrent.hasSubtitles {
                    Text("中文字幕")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.onPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.primaryAction, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if torrent.isHD {
                    Text("高清")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1)
                        }
                }

                Text(torrent.size)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if let date = torrent.date {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(torrent.name)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                Button(action: onPlay) {
                    HStack(spacing: 8) {
                        Image(systemName: AppIcon.play.name)
                            .font(.system(size: 12))
                        Text(playTitle)
                    }
                }
                .buttonStyle(MagnetActionStyle(prominent: true))
                .accessibilityIdentifier("magnet.play")

                Button(action: onSave) {
                    HStack(spacing: 6) {
                        if saveState == .saving {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: saveState == .saved ? AppIcon.check.name : AppIcon.cloudDownload.name)
                                .font(.system(size: 13))
                        }
                        Text(saveState.title)
                            .lineLimit(1)
                    }
                    .foregroundStyle(saveState == .saved ? Theme.success : Color.primary)
                }
                .buttonStyle(MagnetActionStyle(prominent: false))
                .frame(width: 112)
                .disabled(saveState == .saving || saveState == .saved)
                .accessibilityIdentifier("magnet.save115")

                Button(action: onCopy) {
                    Image(systemName: copied ? AppIcon.check.name : AppIcon.copy.name)
                        .font(.system(size: 14))
                        .foregroundStyle(copied ? Theme.accent : Color.primary)
                }
                .buttonStyle(MagnetActionStyle(prominent: false))
                .frame(width: 52)
                .accessibilityLabel(copied ? "已复制" : "复制磁力")
                .accessibilityIdentifier("magnet.copy")
            }
            if case .failed(let message) = saveState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(highlighted ? Theme.accent.opacity(0.4) : Theme.hairline, lineWidth: highlighted ? 1 : 0.5)
        }
    }
}

struct MagnetDetailView: View {
    let item: MagnetSearchItem

    @EnvironmentObject private var appState: AppState
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true
    @State private var magnets: [MagnetTorrentItem] = []
    @State private var stars: [MagnetStarItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var copiedMagnetID: String?
    /// 点了播放：播放页盖在详情页上面，关掉后仍停留在这一页。
    @State private var playLaunch: MagnetLaunch?
    @State private var saveStates: [String: Offline115SaveState] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                VStack(alignment: .leading, spacing: 0) {
                    if !stars.isEmpty {
                        starsSection
                            .padding(.bottom, 28)
                    }
                    magnetSection
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background {
            // 顶部一层暖色渐变，把封面和页面底色衔接起来。
            ZStack(alignment: .top) {
                Theme.pageBackground
                LinearGradient(
                    colors: [Theme.accent.opacity(0.28), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 360)
            }
            .ignoresSafeArea()
        }
        .navigationTitle(item.code)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .sheet(item: $playLaunch) { launch in
            NavigationStack { MagnetPlayerView(initialMagnet: launch.value, closesAfterPlayback: true) }
                .environmentObject(appState)
        }
        .task {
            // 从女优页返回时页面会再次出现，已经取到的磁力不重新拉取。
            guard magnets.isEmpty, stars.isEmpty, errorText == nil else { return }
            await fetchDetails()
        }
    }

    // MARK: 影片信息

    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            MagnetCover(url: item.coverURL, code: item.code)
                .frame(width: 120, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 10) {
                if !item.code.isEmpty {
                    Text(item.code)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                }

                Text(item.title)
                    .font(.display(17))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                if let date = item.releaseDate {
                    Text("发行 \(date)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, 8)
    }

    /// 参演女优：可点的胶囊，点进去看她的作品。
    private var starsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MagnetSectionHeader(title: "参演女优")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stars) { star in
                        NavigationLink {
                            StarMoviesView(star: star)
                        } label: {
                            HStack(spacing: 8) {
                                MagnetStarAvatar(star: star, size: 28)
                                Text(star.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Image(systemName: AppIcon.forward.name)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 12)
                            .frame(minHeight: 44)
                            .background(Theme.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                        }
                        .buttonStyle(.pressable(scale: 0.97))
                    }
                }
            }
        }
    }

    // MARK: 磁力资源

    @ViewBuilder
    private var magnetSection: some View {
        if isLoading {
            MagnetLoadingView(style: .list)
        } else if let error = errorText {
            MagnetErrorState(message: error) { Task { await fetchDetails() } }
        } else if magnets.isEmpty {
            MagnetEmptyState(icon: .archive, title: "该影片暂无可用的磁力链接")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("磁力资源")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text("\(magnets.count) 个")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }

                Text("已按中文字幕、高清优先排序")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.bottom, 14)

                LazyVStack(spacing: 12) {
                    ForEach(Array(magnets.enumerated()), id: \.element.id) { index, torrent in
                        MagnetTorrentCard(
                            torrent: torrent,
                            highlighted: index == 0,
                            playTitle: cloudRelay ? "115 云下载播放" : "磁力播放",
                            copied: copiedMagnetID == torrent.id,
                            saveState: saveStates[torrent.id] ?? .idle,
                            onPlay: { playLaunch = MagnetLaunch(value: torrent.magnetURL) },
                            onSave: { save(torrent) },
                            onCopy: { copy(torrent) }
                        )
                    }
                }
            }
        }
    }

    private func save(_ torrent: MagnetTorrentItem) {
        Haptics.tap()
        let id = torrent.id
        saveStates[id] = .saving
        Task { @MainActor in
            do {
                _ = try await Offline115Saver.save([torrent.magnetURL], appState: appState)
                Haptics.success()
                saveStates[id] = .saved
            } catch {
                Haptics.warning()
                saveStates[id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func copy(_ torrent: MagnetTorrentItem) {
        UIPasteboard.general.string = torrent.magnetURL
        Haptics.success()
        copiedMagnetID = torrent.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedMagnetID == torrent.id { copiedMagnetID = nil }
        }
    }

    @MainActor
    private func fetchDetails() async {
        isLoading = true
        errorText = nil
        do {
            let (actresses, torrents) = try await JavBusSource.shared.fetchDetailInfo(for: item)
            stars = actresses
            magnets = torrents
            isLoading = false
        } catch {
            // 页面被关闭时任务会被取消，不用再更新界面。
            if error is CancellationError { return }
            errorText = error.localizedDescription
            isLoading = false
        }
    }
}

