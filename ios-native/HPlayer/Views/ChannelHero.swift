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

    /// 取色和当前是哪一张：放在不被页面订阅的对象里，翻页时只有顶部氛围色重画。
    @State private var palette = HeroPalette.shared
    @State private var tint = CarouselTintState()

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                HomeChannelBar(selection: $channel)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.leading, Theme.contentInset)
            .padding(.trailing, 6)
            .frame(minHeight: 44)
            .padding(.top, safeTop)

            ChannelSearchField(placeholder: searchPlaceholder, identifier: searchIdentifier, onSearch: onSearch,
                               onFilter: onFilter, filterIdentifier: filterIdentifier)
                .padding(.horizontal, Theme.contentInset)

            if !slides.isEmpty {
                carousel
                    .padding(.top, 6)
            } else if reservesCarousel {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .frame(height: (max(width - Theme.contentInset * 2, 1) * 9 / 16).rounded())
                    .padding(.horizontal, Theme.contentInset)
                    .padding(.top, 6)
                    .accessibilityLabel("正在加载轮播")
            }
        }
        .padding(.bottom, 4)
        .background(alignment: .top) {
            HomeAmbientBackdrop(state: tint, palette: palette)
                .frame(height: safeTop + 440)
        }
        .onAppear { palette.prepare(slides.map(\.palette)) }
        .onChange(of: slides.map(\.id)) { _ in palette.prepare(slides.map(\.palette)) }
    }

    /// 圆角 16:9 卡片。卡片和图都不动，下一张图从右侧正中以弧形揭出来，文字一半时原地换（见 LoopingCarousel）。
    private var carousel: some View {
        let cardWidth = max(width - Theme.contentInset * 2, 1)
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
        .frame(height: (cardWidth * 9 / 16).rounded())
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
                        .font(.system(size: 15, weight: Theme.iconWeight))
                    Text(placeholder)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 14)
                .padding(.trailing, onFilter == nil ? 14 : 0)
                .frame(maxWidth: .infinity, minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.98))
            .accessibilityLabel("搜索")
            .accessibilityIdentifier(identifier)

            if let onFilter {
                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.4))
                    .frame(width: 1, height: 14)
                    .accessibilityHidden(true)

                Button {
                    Haptics.select()
                    onFilter()
                } label: {
                    Text("筛选")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.94))
                .accessibilityLabel("筛选")
                .accessibilityIdentifier(filterIdentifier)
            }
        }
        .background(Theme.track, in: Capsule())
    }
}

// MARK: - 快捷入口

/// 轮播下面一排圆形快捷入口（动漫：最新上架 / 最多播放 / 我的追番…；片库：全部 / 电影 / 剧集…）。
/// 选中的那个实心底，其余是同色浅底。
struct ChannelShortcut: View {
    let title: String
    let icon: AppIcon
    var tint: Color = Theme.accentFill
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChannelShortcutLabel(title: title, icon: icon, tint: tint, selected: selected)
        }
        .buttonStyle(.pressable(scale: 0.92))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChannelShortcutLabel: View {
    let title: String
    let icon: AppIcon
    var tint: Color = Theme.accentFill
    var selected = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon.name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? Color.white : tint)
                .frame(width: 46, height: 46)
                .background(selected ? tint : tint.opacity(0.14), in: Circle())
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// 快捷入口的几种颜色（和原型一致：玫红、橙、紫、蓝、绿）
enum ShortcutTint {
    static let pink = Color(uiColor: UIColor(hex: 0xFF4D8D))
    static let orange = Color(uiColor: UIColor(hex: 0xE08A1E))
    static let purple = Color(uiColor: UIColor(hex: 0x7A5AF0))
    static let blue = Color(uiColor: UIColor(hex: 0x1F9BC7))
    static let green = Color(uiColor: UIColor(hex: 0x2CA67E))
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
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                Image(systemName: AppIcon.expand.name)
                    .font(.system(size: 9, weight: .bold))
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
