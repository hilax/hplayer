import SwiftUI

// MARK: - 频道页顶部（推荐 / 动漫 / 片库共用）

/// 频道页顶部：第一行频道条（右边可放按钮），第二行搜索框（右侧「筛选」），再下面是轮播。
/// 整块铺着当前这张轮播图的氛围色，从屏幕顶端往下淡进页面底色，跟着页面一起滚走。
/// 放在一个忽略顶部安全区的 ScrollView 里用，`safeTop` 传状态栏高度。
struct ChannelHeroSection<Trailing: View, HitArea: View>: View {
    @Binding var channel: HomeChannel
    var searchPlaceholder: String
    var searchIdentifier: String
    var onSearch: () -> Void
    /// 搜索框右侧「筛选」；nil 时不显示
    var onFilter: (() -> Void)? = nil
    var filterIdentifier = ""
    let slides: [HomeSlide]
    /// 轮播还没有内容时也留出它的位置（灰色占位），数据到了再填，页面不跳
    var reservesCarousel = false
    var carouselLabel: String
    var carouselIdentifier: String
    let safeTop: CGFloat
    let width: CGFloat
    let trailing: () -> Trailing
    /// 点轮播空白处的那层（播放 / 进详情），可以挂长按菜单
    let hitArea: (HomeSlide) -> HitArea

    init(channel: Binding<HomeChannel>, searchPlaceholder: String, searchIdentifier: String, onSearch: @escaping () -> Void,
         onFilter: (() -> Void)? = nil, filterIdentifier: String = "", slides: [HomeSlide], reservesCarousel: Bool = false,
         carouselLabel: String, carouselIdentifier: String, safeTop: CGFloat, width: CGFloat,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder hitArea: @escaping (HomeSlide) -> HitArea) {
        _channel = channel
        self.searchPlaceholder = searchPlaceholder
        self.searchIdentifier = searchIdentifier
        self.onSearch = onSearch
        self.onFilter = onFilter
        self.filterIdentifier = filterIdentifier
        self.slides = slides
        self.reservesCarousel = reservesCarousel
        self.carouselLabel = carouselLabel
        self.carouselIdentifier = carouselIdentifier
        self.safeTop = safeTop
        self.width = width
        self.trailing = trailing
        self.hitArea = hitArea
    }

    var body: some View {
        AmbientHeroSection(slides: slides, reservesCarousel: reservesCarousel, carouselLabel: carouselLabel,
                           carouselIdentifier: carouselIdentifier, safeTop: safeTop, width: width) {
            HStack(spacing: 4) {
                HomeChannelBar(selection: $channel)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.leading, Theme.contentInset)
            .padding(.trailing, 6)
            .frame(minHeight: 44)

            ChannelSearchField(placeholder: searchPlaceholder, identifier: searchIdentifier, onSearch: onSearch,
                               onFilter: onFilter, filterIdentifier: filterIdentifier)
                .padding(.horizontal, Theme.contentInset)
        } hitArea: { slide in
            hitArea(slide)
        }
    }
}

/// 顶部的通用骨架：上面是调用方给的几行（频道条、搜索框…），下面是轮播；整块铺当前轮播图放大模糊后的氛围层。
/// 推荐 / 动漫 / 片库用 ChannelHeroSection 包一层；磁力页的顶部（分类条 + 可输入的搜索框）直接用它。
struct AmbientHeroSection<Top: View, HitArea: View>: View {
    let slides: [HomeSlide]
    var reservesCarousel = false
    var carouselLabel: String
    var carouselIdentifier: String
    let safeTop: CGFloat
    let width: CGFloat
    let top: () -> Top
    let hitArea: (HomeSlide) -> HitArea

    /// 取色和当前是哪一张：放在不被页面订阅的对象里，翻页时只有顶部氛围色重画。
    @State private var palette = HeroPalette.shared
    @State private var tint = CarouselTintState()

    init(slides: [HomeSlide], reservesCarousel: Bool = false, carouselLabel: String, carouselIdentifier: String,
         safeTop: CGFloat, width: CGFloat,
         @ViewBuilder top: @escaping () -> Top,
         @ViewBuilder hitArea: @escaping (HomeSlide) -> HitArea) {
        self.slides = slides
        self.reservesCarousel = reservesCarousel
        self.carouselLabel = carouselLabel
        self.carouselIdentifier = carouselIdentifier
        self.safeTop = safeTop
        self.width = width
        self.top = top
        self.hitArea = hitArea
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            top()
            if !slides.isEmpty {
                carousel
                    .padding(.top, 6)
            } else if reservesCarousel {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .frame(height: cardHeight)
                    .padding(.horizontal, Theme.contentInset)
                    .padding(.top, 6)
                    .accessibilityLabel("正在加载轮播")
            }
        }
        .padding(.top, safeTop)
        .padding(.bottom, 4)
        .background(alignment: .top) {
            // 当前轮播图放大模糊后铺在顶部，到卡片下沿前淡进页面底色；
            // 往上多铺一段实色：下拉回弹、下拉刷新时，轮播上方露出来的也是氛围色
            if hasHero {
                HomeAmbientBackdrop(state: tint, palette: palette, heroHeight: heroHeight,
                                    extensionHeight: Self.pullExtension)
                    .frame(height: Self.pullExtension + heroHeight)
                    .offset(y: -Self.pullExtension)
            }
        }
        // 告诉频道头部：这一页顶部有氛围层，频道条和搜索框换成白字 + 磨砂搜索框
        .preference(key: AmbientHeroPresenceKey.self, value: hasHero)
        .onAppear { palette.prepare(slides.map(\.palette)) }
        .onChange(of: slides.map(\.id)) { _ in palette.prepare(slides.map(\.palette)) }
    }

    private var hasHero: Bool { !slides.isEmpty || reservesCarousel }

    /// 屏幕顶端到轮播卡片下沿
    private var heroHeight: CGFloat { safeTop + 6 + cardHeight }

    /// 轮播氛围色往屏幕上方多铺的高度（下拉最多能拉出这么多）
    private static var pullExtension: CGFloat { 800 }

    private var cardHeight: CGFloat {
        (max(width - Theme.contentInset * 2, 1) * 9 / 16).rounded()
    }

    /// 圆角 16:9 卡片。卡片和图都不动，下一张图从右侧正中以弧形揭出来，文字一半时原地换（见 LoopingCarousel）。
    private var carousel: some View {
        let tint = tint
        let slides = slides
        return LoopingCarousel(items: slides, label: carouselLabel, positionIdentifier: carouselIdentifier,
                               onSelect: { index in
                                   if slides.indices.contains(index) { tint.key = slides[index].palette.key }
                               }) { slide in
            HomeSlideArtwork(slide: slide)
        } foreground: { slide in
            HomeSlideCaption(slide: slide)
        } hitArea: { slide in
            hitArea(slide)
        }
        .frame(height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.horizontal, Theme.contentInset)
    }
}

extension ChannelHeroSection where Trailing == EmptyView {
    init(channel: Binding<HomeChannel>, searchPlaceholder: String, searchIdentifier: String, onSearch: @escaping () -> Void,
         onFilter: (() -> Void)? = nil, filterIdentifier: String = "", slides: [HomeSlide], reservesCarousel: Bool = false,
         carouselLabel: String, carouselIdentifier: String, safeTop: CGFloat, width: CGFloat,
         @ViewBuilder hitArea: @escaping (HomeSlide) -> HitArea) {
        self.init(channel: channel, searchPlaceholder: searchPlaceholder, searchIdentifier: searchIdentifier,
                  onSearch: onSearch, onFilter: onFilter, filterIdentifier: filterIdentifier, slides: slides,
                  reservesCarousel: reservesCarousel, carouselLabel: carouselLabel, carouselIdentifier: carouselIdentifier, safeTop: safeTop, width: width,
                  trailing: { EmptyView() }, hitArea: hitArea)
    }
}

/// 轮播长按时的预览：就是这张卡片的画面和文字（点的那层本身是透明的）。
struct HomeSlidePreview: View {
    let slide: HomeSlide

    var body: some View {
        ZStack {
            HomeSlideArtwork(slide: slide)
            HomeSlideCaption(slide: slide)
        }
        .frame(width: 340, height: 191)
    }
}

// MARK: - 搜索框

/// 搜索框：点进全局搜索；右边「筛选」由各频道决定去哪。
struct ChannelSearchField: View {
    let placeholder: String
    let identifier: String
    let onSearch: () -> Void
    var onFilter: (() -> Void)? = nil
    var filterIdentifier = ""

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSearch) {
                HStack(spacing: 8) {
                    Image(systemName: AppIcon.search.name)
                        .font(.scaled(15, weight: Theme.iconWeight))
                    Text(placeholder)
                        .font(Theme.Typo.row)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, Theme.Space.md + 2)
                .padding(.trailing, onFilter == nil ? Theme.Space.md + 2 : 0)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.98))
            .accessibilityLabel("搜索")
            .accessibilityIdentifier(identifier)

            if let onFilter {
                Rectangle()
                    .fill(Theme.rule)
                    .frame(width: Theme.Stroke.rule, height: 16)
                    .accessibilityHidden(true)

                Button {
                    Haptics.select()
                    onFilter()
                } label: {
                    Text("筛选")
                        .font(Theme.Typo.meta.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.Space.md + 2)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.94))
                .accessibilityLabel("筛选")
                .accessibilityIdentifier(filterIdentifier)
            }
        }
        .heroFieldChrome()
    }
}

// MARK: - 快捷入口

/// 轮播下面一排圆形快捷入口（动漫：最新上架 / 最多播放 / 我的追番…；片库：全部 / 电影 / 剧集…）。
/// 单色：未选中是极淡的灰底 + 正文色线框图标，选中是主操作色（白 / 墨）实心 + 反色图标。
/// `tint` 参数保留只为了调用处不用改，3.0 起不再按入口上不同颜色。
struct ChannelShortcut: View {
    let title: String
    let icon: AppIcon
    var tint: Color = Theme.textPrimary
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChannelShortcutLabel(title: title, icon: icon, tint: tint, selected: selected)
        }
        .buttonStyle(.pressable(scale: 0.94))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChannelShortcutLabel: View {
    let title: String
    let icon: AppIcon
    var tint: Color = Theme.textPrimary
    var selected = false

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: icon.name)
                .font(.scaled(18, weight: Theme.iconWeight))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.textPrimary)
                .frame(width: 48, height: 48)
                .background(selected ? Theme.primaryAction : Theme.tileTint, in: Circle())
                .overlay { Circle().strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: Theme.Stroke.hairline) }
            Text(title)
                .font(Theme.Typo.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .animation(Motion.snappy, value: selected)
    }
}

/// 快捷入口原来的五种颜色。3.0 起快捷入口统一单色，这些名字保留只为了调用处不用改。
enum ShortcutTint {
    static let amber = Theme.textPrimary
    static let orange = Theme.textPrimary
    static let purple = Theme.textPrimary
    static let blue = Theme.textPrimary
    static let green = Theme.textPrimary
}

/// 下拉选择的筛选胶囊：「全部地区 ▾」。选了非默认值时实心高亮。
struct FilterMenuChip<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let defaultValue: Option
    let title: (Option) -> String
    let identifier: String

    var body: some View {
        let active = selection != defaultValue
        Menu {
            Picker(title(selection), selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title(selection))
                    .font(.scaled(13, weight: active ? .semibold : .medium))
                Image(systemName: AppIcon.expand.name)
                    .font(.scaled(9, weight: .bold))
            }
            .foregroundStyle(active ? Theme.onPrimary : Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(active ? Theme.gold : Theme.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityIdentifier(identifier)
    }
}
