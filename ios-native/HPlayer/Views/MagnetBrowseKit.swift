import SwiftUI

// 磁力聚合各页面共用的组件：封面、海报卡片、影片行、分类标签、搜索框、状态页。
// 版式和设计稿一致：深色底 + 琥珀金强调，封面用 3:4 海报，番号浮在封面左上角。

// MARK: - 版式常量

enum MagnetLayout {
    /// 两列海报网格（最新、女优页、片商页）。
    static let posterColumns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    /// 三列头像网格（女优分类）。
    static let avatarColumns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    static let posterRatio: CGFloat = 3.0 / 4.0
}

// MARK: - 封面 / 头像

/// 封面/头像：走 ImagePipeline（带防盗链请求头、磁盘缓存、后台缩小解码）。
/// 加载中只显示底色，加载失败才显示占位图标。
struct MagnetArtwork: View {
    let url: URL?
    let maxPixel: Int
    let placeholder: String

    var body: some View {
        PipelineImage(url: url, maxPixel: maxPixel) { phase in
            switch phase {
            case let .loaded(image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .loading:
                Rectangle().fill(Theme.surfaceRaised)
            case .failed:
                Rectangle()
                    .fill(Theme.surfaceRaised)
                    .overlay { Image(systemName: placeholder).foregroundStyle(.secondary) }
            }
        }
    }
}

/// 浮在封面上的番号小标签。
struct MagnetCodeChip: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Theme.goldLight)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.brandNight.opacity(0.72), in: Capsule())
    }
}

/// 圆形头像。`ringed` 用在女优页抬头：一圈金色描边。
struct MagnetStarAvatar: View {
    let star: MagnetStarItem
    var size: CGFloat = 84
    var ringed = false

    var body: some View {
        MagnetArtwork(url: star.avatarURL, maxPixel: Int(size * 3), placeholder: AppIcon.mine.name)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(
                    ringed ? Theme.accent.opacity(0.7) : Theme.hairline,
                    lineWidth: ringed ? 2 : 0.5
                )
            }
    }
}

// MARK: - 影片：海报卡片与行

/// 海报卡片：3:4 封面（左上角番号）、两行标题、发行日期。点击进入磁力详情。
struct MagnetPosterCard: View {
    let movie: MagnetSearchItem

    var body: some View {
        NavigationLink {
            MagnetDetailView(item: movie)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(MagnetLayout.posterRatio, contentMode: .fit)
                    .overlay {
                        MagnetArtwork(url: movie.coverURL, maxPixel: 420, placeholder: AppIcon.poster.name)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
                    .overlay(alignment: .topLeading) {
                        if !movie.code.isEmpty {
                            MagnetCodeChip(code: movie.code).padding(8)
                        }
                    }

                Text(movie.title)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let date = movie.releaseDate {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.pressable(scale: 0.97))
    }
}

/// 两列海报网格，滑到最后一项时触发翻页。
struct MagnetPosterGrid: View {
    let movies: [MagnetSearchItem]
    let loadMore: () -> Void

    var body: some View {
        LazyVGrid(columns: MagnetLayout.posterColumns, alignment: .leading, spacing: 20) {
            ForEach(movies) { movie in
                MagnetPosterCard(movie: movie)
                    .onAppear {
                        if movie.id == movies.last?.id { loadMore() }
                    }
            }
        }
    }
}

/// 影片行：左边封面，右边番号、标题、女优与日期。最热榜带序号，搜索结果不带。
struct MagnetListRow: View {
    let movie: MagnetSearchItem
    var rank: Int?

    var body: some View {
        NavigationLink {
            MagnetDetailView(item: movie)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if let rank {
                    Text("\(rank)")
                        .font(.display(20))
                        .foregroundStyle(rank <= 3 ? Theme.accent : Color.secondary)
                        .frame(width: 24)
                        .padding(.top, 2)
                        .accessibilityLabel("第 \(rank) 名")
                }

                MagnetArtwork(url: movie.coverURL, maxPixel: 288, placeholder: AppIcon.poster.name)
                    .frame(width: 72, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    if !movie.code.isEmpty {
                        Text(movie.code)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }

                    Text(movie.title)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        if let star = movie.stars.first {
                            Text(star.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                        if let date = movie.releaseDate {
                            Text(date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
    }
}

// MARK: - 分类标签、搜索框

/// 浏览分类：四等分文字标签，选中项下面一条金色滑条。
struct MagnetCategoryTabs: View {
    @Binding var selection: MagnetCategory
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MagnetCategory.allCases) { category in
                let selected = selection == category
                Button {
                    guard !selected else { return }
                    Haptics.select()
                    withAnimation(Motion.snappy) { selection = category }
                } label: {
                    Text(category.title)
                        .font(.subheadline.weight(selected ? .bold : .medium))
                        .foregroundStyle(selected ? Color.primary : Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule()
                                    .fill(Theme.accent)
                                    .frame(height: 2)
                                    .padding(.horizontal, 24)
                                    .matchedGeometryEffect(id: "magnet.category.underline", in: underline)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("magnet.category.\(category.rawValue)")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}

/// 搜索框：一条输入框，键盘上的「搜索」键提交；有内容时右边出现清除按钮。
struct MagnetSearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onClear: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AppIcon.search.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            TextField("番号或女优名，例如 SSIS-888", text: $text)
                .font(.body)
                .submitLabel(.search)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("magnet.search")

            if !text.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: AppIcon.clear.name)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 2)
        .frame(minHeight: 46)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Theme.hairline, lineWidth: focused ? 1 : 0.5)
        }
    }
}

// MARK: - 专题与女优

/// 专题里的片商卡片：片商缩写、名称、常见番号前缀，右边淡淡的片商名水印。
struct MagnetStudioCard: View {
    let studio: MagnetStudio

    var body: some View {
        HStack(spacing: 14) {
            Text(studio.monogram)
                .font(.display(17))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(studio.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(studio.codeHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)

            Image(systemName: AppIcon.forward.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(alignment: .bottomTrailing) {
            Text(studio.title)
                .font(.display(64))
                .foregroundStyle(Color.primary.opacity(0.05))
                .lineLimit(1)
                .fixedSize()
                .offset(x: 6, y: 18)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .surfaceCard()
    }
}

/// 女优分类里的一格：圆头像加姓名。
struct MagnetStarGridCell: View {
    let star: MagnetStarItem

    var body: some View {
        VStack(spacing: 8) {
            MagnetStarAvatar(star: star, size: 84)
            Text(star.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 搜索结果里「匹配女优」的横向卡片。
struct MagnetStarChip: View {
    let star: MagnetStarItem

    var body: some View {
        HStack(spacing: 10) {
            MagnetStarAvatar(star: star, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(star.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("查看她的作品")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }

            Image(systemName: AppIcon.forward.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(minHeight: 56)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
    }
}

// MARK: - 栏目标题

struct MagnetSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 按钮样式

/// 圆角矩形按钮：实心金色（主操作）或描边（次操作），高 44。
struct MagnetActionStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: prominent ? .bold : .semibold))
            .foregroundStyle(prominent ? Theme.onPrimary : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(prominent ? Theme.primaryAction : Color.clear)
            }
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.4)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - 状态：加载中、出错、为空

/// 加载中：用占位块撑出版面，不再只放一个转圈。占位块不做循环动画。
struct MagnetLoadingView: View {
    enum Style { case grid, list, avatars }

    let style: Style

    var body: some View {
        Group {
            switch style {
            case .grid:
                LazyVGrid(columns: MagnetLayout.posterColumns, spacing: 20) {
                    ForEach(0 ..< 4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                .fill(Theme.surfaceRaised)
                                .aspectRatio(MagnetLayout.posterRatio, contentMode: .fit)
                            bar(widthFactor: 0.92)
                            bar(widthFactor: 0.6)
                        }
                    }
                }
            case .list:
                VStack(spacing: 14) {
                    ForEach(0 ..< 4, id: \.self) { _ in
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                .fill(Theme.surfaceRaised)
                                .frame(width: 72, height: 96)
                            VStack(alignment: .leading, spacing: 8) {
                                bar(widthFactor: 0.3)
                                bar(widthFactor: 0.95)
                                bar(widthFactor: 0.7)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            case .avatars:
                LazyVGrid(columns: MagnetLayout.avatarColumns, spacing: 20) {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        VStack(spacing: 8) {
                            Circle().fill(Theme.surfaceRaised).frame(width: 84, height: 84)
                            bar(widthFactor: 0.6)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载")
    }

    private func bar(widthFactor: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.surfaceRaised)
                .frame(width: proxy.size.width * widthFactor)
        }
        .frame(height: 10)
    }
}

/// 加载失败：说明原因，给出「重新加载」和「更换镜像域名」两条出路。
struct MagnetErrorState: View {
    let message: String
    let retry: () -> Void
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: AppIcon.alert.name)
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)

            Text("加载未完成")
                .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button("重新加载", action: retry)
                    .buttonStyle(MagnetActionStyle(prominent: true))
                Button("更换镜像域名") { showingSettings = true }
                    .buttonStyle(MagnetActionStyle(prominent: false))
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .surfaceCard()
        .sheet(isPresented: $showingSettings) {
            JavBusHostSettingsSheet()
        }
    }
}

/// 为空：一个图标加一两句话。
struct MagnetEmptyState: View {
    let icon: AppIcon
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon.name)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 分页影片网格（女优页、片商页共用）

/// 一页页加载的海报网格：加载中、失败重试、空列表、网格加底部翻页提示。
struct MagnetMovieGridFeed: View {
    let emptyText: String
    let movies: [MagnetSearchItem]
    let isLoading: Bool
    let errorText: String?
    let paging: PagingState
    let retry: () -> Void
    let loadMore: () -> Void

    var body: some View {
        if isLoading {
            MagnetLoadingView(style: .grid)
        } else if let errorText {
            MagnetErrorState(message: errorText, retry: retry)
        } else if movies.isEmpty {
            MagnetEmptyState(icon: .archive, title: emptyText)
        } else {
            VStack(spacing: 8) {
                MagnetPosterGrid(movies: movies, loadMore: loadMore)
                PagingFooter(
                    isLoading: paging.isLoadingMore,
                    failed: paging.loadMoreFailed,
                    retry: loadMore
                )
            }
        }
    }
}
