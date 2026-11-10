import SwiftUI

// 磁力聚合各页面共用的组件：封面、海报卡片、影片行、分类标签、搜索框、状态页。
// 版式和设计稿一致：深色底 + 琥珀金强调，封面用 3:4 海报，番号浮在封面左上角。

// MARK: - 版式常量

enum MagnetLayout {
    /// 三列海报网格（最新、女优页、片商页）。
    static let posterColumns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
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

/// 影片封面。JavBus 列表页给的是 147×200 的小图，放大到两列海报里会很糊；
/// 这里换成同一部片的大封面（`pics/cover/xxx_b.jpg`，800 像素宽），按版式裁出正面：
/// - 竖版单封面（宽高比 < 0.9）：整张显示；
/// - 左背右正的横版封面（宽高比约 1.49）：取右边 47.5%，和站点自己做小图的取法一致；
/// - 其他版式（正面的位置不固定）：不冒险裁剪，继续用小图。
/// 大图加载期间和加载失败时都先显示小图，大图到了再换上。
struct MagnetCover: View {
    /// 列表页里的封面地址（小图）。
    let url: URL?

    enum Crop: Equatable {
        case full
        case trailing
    }

    /// 横版封面里「正面」占的宽度比例。
    static let frontFraction: CGFloat = 0.475

    /// 小图地址 → 同一部片的大封面地址；不是 JavBus 小图的地址返回 nil。
    static func highResURL(for url: URL?) -> URL? {
        guard let url else { return nil }
        let text = url.absoluteString
        guard text.contains("/pics/thumb/"), text.hasSuffix(".jpg") else { return nil }
        let cover = text.replacingOccurrences(of: "/pics/thumb/", with: "/pics/cover/")
        return URL(string: String(cover.dropLast(".jpg".count)) + "_b.jpg")
    }

    /// 按大图的宽高比决定怎么取正面；nil 表示不裁，回退到小图。
    static func crop(for size: CGSize) -> Crop? {
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        if ratio < 0.9 { return .full }
        if ratio >= 1.45, ratio <= 1.52 { return .trailing }
        return nil
    }

    /// 大图超过这个时间还没到，才开始加载小图垫底。大多数封面一两秒内就到了，
    /// 这样不会给每张封面同时发两个请求（一屏九张封面时，请求翻倍容易被图床限流，表现就是封面空着）。
    static let thumbnailDelay: UInt64 = 1_200_000_000

    @State private var thumbnailWanted = false

    var body: some View {
        if let hires = Self.highResURL(for: url) {
            PipelineImage(url: hires, maxPixel: 800) { phase in
                switch phase {
                case let .loaded(image):
                    if let crop = Self.crop(for: image.size) {
                        front(of: image, crop: crop)
                    } else {
                        thumbnail
                    }
                case .loading:
                    if thumbnailWanted { thumbnail } else { Rectangle().fill(Theme.surfaceRaised) }
                case .failed:
                    thumbnail
                }
            }
            .task(id: url) {
                thumbnailWanted = false
                try? await Task.sleep(nanoseconds: Self.thumbnailDelay)
                guard !Task.isCancelled else { return }
                thumbnailWanted = true
            }
        } else {
            thumbnail
        }
    }

    private var thumbnail: some View {
        MagnetArtwork(url: url, maxPixel: 420, placeholder: AppIcon.poster.name)
    }

    private func front(of image: UIImage, crop: Crop) -> some View {
        GeometryReader { proxy in
            let aspect = image.size.width / image.size.height
            let width: CGFloat = {
                switch crop {
                case .full:
                    return max(proxy.size.width, proxy.size.height * aspect)
                case .trailing:
                    return max(proxy.size.width / Self.frontFraction, proxy.size.height * aspect)
                }
            }()
            Image(uiImage: image)
                .resizable()
                .frame(width: width, height: width / aspect)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: crop == .trailing ? .trailing : .center
                )
                .clipped()
        }
    }
}

/// 浮在封面上的番号小标签。
struct MagnetCodeChip: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 10, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Theme.goldLight)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
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
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(MagnetLayout.posterRatio, contentMode: .fit)
                    .overlay {
                        MagnetCover(url: movie.coverURL)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
                    .overlay(alignment: .topLeading) {
                        if !movie.code.isEmpty {
                            MagnetCodeChip(code: movie.code).padding(5)
                        }
                    }

                Text(movie.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let date = movie.releaseDate {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.pressable(scale: 0.97))
    }
}

/// 三列海报网格，滑到最后一项时触发翻页。
struct MagnetPosterGrid: View {
    let movies: [MagnetSearchItem]
    let loadMore: () -> Void

    var body: some View {
        LazyVGrid(columns: MagnetLayout.posterColumns, alignment: .leading, spacing: 16) {
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

                MagnetCover(url: movie.coverURL)
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

            TextField("番号、女优，或粘贴磁力链接", text: $text)
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
            } else {
                // 系统粘贴按钮：不会弹「允许粘贴」的询问
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { @MainActor in text = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .tint(Theme.surfaceHigh)
                .foregroundStyle(Theme.textPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("magnet.paste")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 8 : 2)
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
                LazyVGrid(columns: MagnetLayout.posterColumns, spacing: 16) {
                    ForEach(0 ..< 6, id: \.self) { _ in
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
