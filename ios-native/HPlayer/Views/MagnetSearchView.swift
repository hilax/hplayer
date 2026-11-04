import SwiftUI
import UIKit

/// 磁力在线搜索与分类聚合页面（支持按番号/女优搜索、最新发布、无码专区与女优专属作品库）。
struct MagnetSearchView: View {
    var onSelectMagnet: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("hplayer.magnet.javbus_host") private var customHost = ""
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true

    @State private var keyword = ""
    @State private var selectedCategory: MagnetCategory = .latest
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var detectedClipboardCode: String?
    @State private var showingSettingsSheet = false
    @State private var toastMessage: String?
    @FocusState private var searchFocused: Bool

    // 分类浏览数据
    @State private var categoryMovies: [MagnetSearchItem] = []
    @State private var categoryStars: [MagnetStarItem] = []
    @State private var categoryPage = 1
    @State private var isLoadingMore = false

    // 搜索数据
    @State private var searchMovies: [MagnetSearchItem] = []
    @State private var matchedStars: [MagnetStarItem] = []

    // 详情选择
    @State private var selectedMovie: MagnetSearchItem?
    @State private var selectedStar: MagnetStarItem?

    private var inSearchMode: Bool {
        !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchHeaderCard

                if let clipboardCode = detectedClipboardCode, !clipboardCode.isEmpty, keyword != clipboardCode, !inSearchMode {
                    clipboardHint(code: clipboardCode)
                }

                if !inSearchMode {
                    categoryPickerSection
                }

                if isSearching {
                    loadingView
                } else if let error = searchError {
                    errorCard(message: error)
                } else if inSearchMode {
                    searchResultContent
                } else {
                    categoryBrowseContent
                }
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("磁力聚合与分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Image(systemName: AppIcon.settings.name)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .sheet(item: $selectedMovie) { item in
            MagnetDetailSheet(item: item, onSelectStar: { star in
                selectedMovie = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    selectedStar = star
                }
            }) { chosenMagnet in
                selectedMovie = nil
                dismiss()
                onSelectMagnet(chosenMagnet)
            }
        }
        .sheet(item: $selectedStar) { star in
            StarMoviesView(star: star, onSelectMovie: { movie in
                selectedStar = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    selectedMovie = movie
                }
            })
        }
        .sheet(isPresented: $showingSettingsSheet) {
            JavBusHostSettingsSheet()
        }
        .overlay(alignment: .bottom) {
            if let toast = toastMessage {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: inSearchMode)
        .animation(Motion.smooth, value: isSearching)
        .animation(Motion.smooth, value: selectedCategory)
        .animation(Motion.smooth, value: toastMessage)
        .task {
            checkClipboard()
            if categoryMovies.isEmpty && categoryStars.isEmpty {
                loadCurrentCategory()
            }
        }
        .onChange(of: selectedCategory) { _ in
            categoryPage = 1
            loadCurrentCategory()
        }
    }

    // MARK: - 搜索输入卡片

    private var searchHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: AppIcon.search.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("搜索番号（如 SSIS-888）或女优名字", text: $keyword)
                    .font(.body)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { triggerSearch() }

                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        searchMovies = []
                        matchedStars = []
                        searchError = nil
                    } label: {
                        Image(systemName: AppIcon.clear.name)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("搜索") {
                    searchFocused = false
                    triggerSearch()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(14)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(16)
        .surfaceCard(cornerRadius: 22)
    }

    // MARK: - 分类选择 Pills

    private var categoryPickerSection: some View {
        HStack(spacing: 8) {
            ForEach(MagnetCategory.allCases) { cat in
                let isSelected = selectedCategory == cat
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: cat == .actresses ? AppIcon.people.name : AppIcon.sparkles.name)
                            .font(.system(size: 12))
                        Text(cat.title)
                            .font(.subheadline.weight(isSelected ? .bold : .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .background(isSelected ? Theme.accent : Theme.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - 剪贴板快速提示

    private func clipboardHint(code: String) -> some View {
        Button {
            keyword = code
            triggerSearch()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AppIcon.copy.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("识别到剪贴板番号: \(code)，点击快速搜索")
                    .font(.footnote.weight(.medium))
                Spacer()
                Image(systemName: AppIcon.forward.name)
                    .font(.system(size: 14))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 搜索结果视图

    @ViewBuilder
    private var searchResultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !matchedStars.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("匹配女优")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(matchedStars) { star in
                                starBadge(star: star)
                                    .onTapGesture {
                                        selectedStar = star
                                    }
                            }
                        }
                    }
                }
            }

            if !searchMovies.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("相关影片 (\(searchMovies.count))")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("点击查看磁力")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(searchMovies) { movie in
                            movieCard(item: movie)
                                .onTapGesture {
                                    selectedMovie = movie
                                }
                        }
                    }
                }
            } else if matchedStars.isEmpty {
                emptyResultView
            }
        }
    }

    // MARK: - 分类浏览视图

    @ViewBuilder
    private var categoryBrowseContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedCategory == .actresses {
                Text("热门女优演员")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 16) {
                    ForEach(categoryStars) { star in
                        starGridCard(star: star)
                            .onTapGesture {
                                selectedStar = star
                            }
                    }
                }
            } else {
                HStack {
                    Text(selectedCategory == .latest ? "最新发布影片" : "无码最新影片")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("实时更新")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                LazyVStack(spacing: 12) {
                    ForEach(categoryMovies) { movie in
                        movieCard(item: movie)
                            .onTapGesture {
                                selectedMovie = movie
                            }
                    }
                }
            }
        }
    }

    // MARK: - 影片卡片组件

    private func movieCard(item: MagnetSearchItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: item.coverURL) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Theme.surfaceRaised)
                        .overlay { ProgressView().scaleEffect(0.8) }
                case let .success(image):
                    image.resizable().scaledToFill()
                case .failure:
                    Rectangle()
                        .fill(Theme.surfaceRaised)
                        .overlay { Image(systemName: AppIcon.poster.name).foregroundStyle(.secondary) }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 86, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                if !item.code.isEmpty {
                    Text(item.code)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }

                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let date = item.releaseDate {
                    HStack(spacing: 4) {
                        Image(systemName: AppIcon.clock.name)
                            .font(.system(size: 11))
                        Text(date)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                HStack {
                    Spacer()
                    Label("获取磁力", systemImage: AppIcon.download.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .surfaceCard(cornerRadius: 16)
    }

    // MARK: - 女优卡片组件

    private func starBadge(star: MagnetStarItem) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: star.avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(Theme.surfaceRaised)
                        .overlay { Image(systemName: AppIcon.mine.name).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(star.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("点击查看全部作品")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
            Image(systemName: AppIcon.forward.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .surfaceCard(cornerRadius: 14)
    }

    private func starGridCard(star: MagnetStarItem) -> some View {
        VStack(spacing: 8) {
            AsyncImage(url: star.avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.surfaceRaised)
                        .overlay { Image(systemName: AppIcon.mine.name).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())

            Text(star.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .surfaceCard(cornerRadius: 14)
    }

    // MARK: - 辅助状态视图

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Theme.accent)
            Text("正在实时获取资源...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: AppIcon.alert.name)
                .font(.system(size: 36))
                .foregroundStyle(Color.orange)

            Text("加载未完成")
                .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("更换镜像域名") {
                    showingSettingsSheet = true
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)

                Button("重新尝试") {
                    if inSearchMode {
                        triggerSearch()
                    } else {
                        loadCurrentCategory()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .surfaceCard(cornerRadius: 20)
    }

    private var emptyResultView: some View {
        VStack(spacing: 12) {
            Image(systemName: AppIcon.search.name)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("未找到相关资源")
                .font(.headline)
            Text("建议尝试直接输入标准番号（如 SSIS-888）或女优全名。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - 数据加载与网络交互

    private func loadCurrentCategory() {
        isSearching = true
        searchError = nil

        Task {
            do {
                if selectedCategory == .actresses {
                    let stars = try await JavBusSource.shared.fetchActresses(page: 1)
                    await MainActor.run {
                        self.categoryStars = stars
                        self.isSearching = false
                    }
                } else {
                    let movies = try await JavBusSource.shared.fetchCategory(selectedCategory, page: 1)
                    await MainActor.run {
                        self.categoryMovies = movies
                        self.isSearching = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.searchError = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }

    private func triggerSearch() {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        searchError = nil
        searchMovies = []
        matchedStars = []

        Task {
            do {
                // 并发搜索影片与女优
                async let movieSearch = JavBusSource.shared.search(keyword: q, page: 1)
                async let starSearch = JavBusSource.shared.searchActresses(name: q)

                let (movies, stars) = try await (movieSearch, starSearch)
                await MainActor.run {
                    self.searchMovies = movies
                    self.matchedStars = stars
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    self.searchError = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }

    private func checkClipboard() {
        guard let clip = UIPasteboard.general.string else { return }
        if let extracted = AVCatalogCode.extract(clip) {
            detectedClipboardCode = extracted
        }
    }
}

// MARK: - 女优作品列表页 (StarMoviesView)

struct StarMoviesView: View {
    let star: MagnetStarItem
    var onSelectMovie: (MagnetSearchItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var movies: [MagnetSearchItem] = []
    @State private var detailedStar: MagnetStarItem?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    starHeader

                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView().tint(Theme.accent)
                            Text("正在加载作品列表...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let error = errorText {
                        VStack(spacing: 12) {
                            Image(systemName: AppIcon.alert.name)
                                .font(.system(size: 32))
                                .foregroundStyle(Color.orange)
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("重试") { loadStarMovies() }
                                .buttonStyle(.bordered)
                                .tint(Theme.accent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else if movies.isEmpty {
                        Text("暂无参演作品")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("参演作品 (\(movies.count))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.contentInset)

                            LazyVStack(spacing: 12) {
                                ForEach(movies) { movie in
                                    movieRow(movie: movie)
                                        .onTapGesture {
                                            onSelectMovie(movie)
                                        }
                                }
                            }
                            .padding(.horizontal, Theme.contentInset)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle(star.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            loadStarMovies()
        }
    }

    private var starHeader: some View {
        VStack(spacing: 12) {
            AsyncImage(url: (detailedStar ?? star).avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(Theme.surfaceRaised)
                        .overlay { Image(systemName: AppIcon.mine.name).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.accent.opacity(0.3), lineWidth: 2))

            Text((detailedStar ?? star).name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)

            if let bio = (detailedStar ?? star).bio, !bio.isEmpty {
                Text(bio)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .surfaceCard(cornerRadius: 18)
        .padding(.horizontal, Theme.contentInset)
    }

    private func movieRow(movie: MagnetSearchItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: movie.coverURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.surfaceRaised)
                        .overlay { Image(systemName: AppIcon.poster.name).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 76, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                if !movie.code.isEmpty {
                    Text(movie.code)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }

                Text(movie.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let date = movie.releaseDate {
                    HStack(spacing: 4) {
                        Image(systemName: AppIcon.clock.name)
                            .font(.system(size: 10))
                        Text(date)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 2)

                HStack {
                    Spacer()
                    Label("查看磁力", systemImage: AppIcon.download.name)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .surfaceCard(cornerRadius: 14)
    }

    private func loadStarMovies() {
        isLoading = true
        errorText = nil
        Task {
            do {
                let (info, list) = try await JavBusSource.shared.fetchStarDetail(starPath: star.detailPath, page: 1)
                await MainActor.run {
                    self.detailedStar = info
                    self.movies = list
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - 磁力详情 Sheet (带女优下钻)

struct MagnetDetailSheet: View {
    let item: MagnetSearchItem
    var onSelectStar: (MagnetStarItem) -> Void = { _ in }
    var onSelectMagnet: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("hplayer.magnet.cloudRelay") private var cloudRelay = true
    @State private var magnets: [MagnetTorrentItem] = []
    @State private var stars: [MagnetStarItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var copiedMagnetID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerCard

                Divider()

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("正在拉取磁力链接与影片详情...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorText {
                    VStack(spacing: 12) {
                        Image(systemName: AppIcon.alert.name)
                            .font(.system(size: 32))
                            .foregroundStyle(Color.orange)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新获取") { fetchDetails() }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if magnets.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: AppIcon.archive.name)
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("该影片暂无可用的磁力链接")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    magnetListView
                }
            }
            .background(Theme.pageBackground.ignoresSafeArea())
            .navigationTitle("资源与磁力详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            fetchDetails()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AsyncImage(url: item.coverURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.surfaceRaised)
                    }
                }
                .frame(width: 58, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    if !item.code.isEmpty {
                        Text(item.code)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let date = item.releaseDate {
                        Text("发行日期: \(date)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if !stars.isEmpty {
                HStack(spacing: 6) {
                    Text("参演女优:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(stars) { star in
                                Button {
                                    onSelectStar(star)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: AppIcon.mine.name)
                                            .font(.system(size: 9))
                                        Text(star.name)
                                            .font(.caption2.weight(.medium))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(Theme.accent)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface)
    }

    private var magnetListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(magnets) { torrent in
                    magnetRow(torrent: torrent)
                }
            }
            .padding(16)
        }
    }

    private func magnetRow(torrent: MagnetTorrentItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if torrent.hasSubtitles {
                    Text("中文字幕")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                if torrent.isHD {
                    Text("1080P 高清")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                Text(torrent.size)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)

                if let date = torrent.date {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }

            Text(torrent.name)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 10) {
                Button {
                    onSelectMagnet(torrent.magnetURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: AppIcon.play.name)
                        Text(cloudRelay ? "115 云下载播放" : "磁力播放")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    UIPasteboard.general.string = torrent.magnetURL
                    copiedMagnetID = torrent.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedMagnetID == torrent.id { copiedMagnetID = nil }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedMagnetID == torrent.id ? AppIcon.check.name : AppIcon.copy.name)
                        Text(copiedMagnetID == torrent.id ? "已复制" : "复制磁力")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Spacer()
            }
        }
        .padding(14)
        .surfaceCard(cornerRadius: 14)
    }

    private func fetchDetails() {
        isLoading = true
        errorText = nil
        Task {
            do {
                let (actresses, torrents) = try await JavBusSource.shared.fetchDetailInfo(for: item)
                await MainActor.run {
                    self.stars = actresses
                    self.magnets = torrents
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - 镜像域名设置弹窗

struct JavBusHostSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hplayer.magnet.javbus_host") private var customHost = ""
    @State private var inputHost = ""

    private let presets = [
        "https://www.javbus.com",
        "https://www.busdmm.work",
        "https://www.dmmsee.art"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("JavBus 访问域名"), footer: Text("当默认域名 javbus.com 受到网络屏蔽或 Cloudflare 防护拦截时，可切换为官方备用或镜像域名。")) {
                    TextField("https://www.javbus.com", text: $inputHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("常用预设域名") {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            inputHost = preset
                        } label: {
                            HStack {
                                Text(preset)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if inputHost == preset {
                                    Image(systemName: AppIcon.check.name)
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("恢复默认域名") {
                        inputHost = "https://www.javbus.com"
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("镜像域名配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        customHost = inputHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .onAppear {
                inputHost = customHost.isEmpty ? "https://www.javbus.com" : customHost
            }
        }
    }
}
