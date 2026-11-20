import SwiftUI

// MARK: - 统一选集数据模型

/// 动漫详情页、片库详情页、竖屏播放器页共用的单集展示数据。
struct EpisodeShelfItem: Identifiable, Hashable {
    let id: String
    /// 格子中间显示的短文字（例如「01」「12」「特别篇」）
    let shortTitle: String
    /// 读屏朗读的完整标题（例如「第01集」「人生切割术 · 第 3 集」）
    let accessibilityTitle: String
    /// 0…1 观看进度（≥ 0.92 视为已看完）
    var progress: Double? = nil
    /// 读屏补充说明（例如「已看完」「看到 12:34」）
    var accessibilityValue: String = ""
    /// 可选的无障碍标识（如播放器使用 `playback.episode.<id>`）
    var accessibilityID: String? = nil

    var isFinished: Bool { (progress ?? 0) >= 0.92 }

    /// "第01集" -> "01"，"第1集" -> "01"，"第108集" -> "108"；非数字标题原样保留（「特别篇」「OVA」）。
    static func shortAnimeTitle(_ raw: String) -> String {
        var clean = raw
            .replacingOccurrences(of: "第", with: "")
            .replacingOccurrences(of: "集", with: "")
            .replacingOccurrences(of: "话", with: "")
            .trimmingCharacters(in: .whitespaces)
        if clean.count == 1 && clean.allSatisfy({ $0.isNumber }) {
            clean = "0" + clean
        }
        return clean.isEmpty ? raw : clean
    }

    /// 1 -> "01"，12 -> "12"，108 -> "108"
    static func numberedTitle(_ number: Int) -> String {
        number < 10 ? String(format: "%02d", max(number, 0)) : "\(number)"
    }
}

/// 三个页面各自的无障碍标识前缀，保持测试和自动化稳定。
struct EpisodeShelfIdentifiers: Hashable {
    let toggle: String
    let ascending: String
    let descending: String
    let rangePrefix: String
}

/// 选集分段和排布的纯计算辅助，便于单元测试验证。
enum EpisodeShelfLayout {
    static let rangeSize = 50
    static let columns = 5
    static let maxUnscrolledRows = 5
    static let tileHeight: CGFloat = 46
    static let stripTileMinWidth: CGFloat = 56
    static let gridSpacing: CGFloat = Theme.Space.sm
    static let cardPadding: CGFloat = Theme.Space.md
    static let stripVerticalPadding: CGFloat = 10
    /// 超过 5 行（25 集）时限制网格视口高度并露出第 6 行边缘，提示可在卡片内继续上下滑
    static let scrolledGridHeight: CGFloat = CGFloat(maxUnscrolledRows) * tileHeight
        + CGFloat(maxUnscrolledRows - 1) * gridSpacing
        + 14

    /// 按 50 集一段切分；倒序时段落顺序也倒过来。
    static func ranges(count: Int, descending: Bool) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let chunks = stride(from: 0, to: count, by: rangeSize).map { $0..<min($0 + rangeSize, count) }
        return descending ? chunks.reversed() : chunks
    }

    /// 某一段内按正序/倒序排好的元素下标。
    static func indices(in range: Range<Int>, descending: Bool) -> [Int] {
        descending ? Array(range.reversed()) : Array(range)
    }

    /// 当前集落在哪一段（找不到回落第 0 段）。
    static func rangeIndex(containing itemIndex: Int?, in ranges: [Range<Int>]) -> Int {
        guard let itemIndex else { return 0 }
        return ranges.firstIndex { $0.contains(itemIndex) } ?? 0
    }

    /// 把一组下标切成每行 5 个的二维数组，用于同步确定高度的网格排布。
    static func rows(from indices: [Int]) -> [[Int]] {
        guard !indices.isEmpty else { return [] }
        return stride(from: 0, to: indices.count, by: columns).map { start in
            Array(indices[start..<min(start + columns, indices.count)])
        }
    }
}

// MARK: - 选集高度测量 Preference

private struct EpisodeStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct EpisodeExpandedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - 统一选集容器 (UnifiedEpisodeShelf)

/// 动漫详情页、片库详情页、竖屏播放器页共用的选集组件。
///
/// 收起时是一张精致的单行横滑卡片（自动居中到当前集，右侧微渐隐提示可滑）；
/// 点「全部」后，卡片自身以柔和弹簧向下展开成完整抽屉（正序 / 倒序、超过 50 集分段、五列网格、
/// 可选底部附加行如「自动连播」），全过程按圆角边界严格裁切，绝不与下方评论 / 接下来 / 文件信息重叠。
struct UnifiedEpisodeShelf<TopAccessory: View, ExpandedFooter: View, TileMenu: View>: View {
    let items: [EpisodeShelfItem]
    let currentID: String?
    let summary: String
    @Binding var isExpanded: Bool
    @Binding var isDescending: Bool
    var showsNowPlayingOnCurrent: Bool = false
    var showsTileContextMenu: Bool = false
    let identifiers: EpisodeShelfIdentifiers
    var caption: String? = nil
    let onSelect: (EpisodeShelfItem) -> Void
    @ViewBuilder var topAccessory: () -> TopAccessory
    @ViewBuilder var expandedFooter: () -> ExpandedFooter
    @ViewBuilder var tileMenu: (EpisodeShelfItem) -> TileMenu

    @State private var rangeIndex = 0
    @State private var measuredStripHeight: CGFloat = EpisodeShelfLayout.tileHeight + EpisodeShelfLayout.stripVerticalPadding * 2
    @State private var measuredExpandedHeight: CGFloat? = nil
    @Namespace private var orderNamespace
    @Namespace private var rangeNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var expandAnimation: Animation {
        .spring(response: 0.36, dampingFraction: 0.86)
    }

    private static var collapseAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.90)
    }

    private var hasExpandedFooter: Bool {
        ExpandedFooter.self != EmptyView.self
    }

    private var ranges: [Range<Int>] {
        EpisodeShelfLayout.ranges(count: items.count, descending: isDescending)
    }

    private var activeRange: Range<Int> {
        let all = ranges
        guard !all.isEmpty else { return 0..<0 }
        return all.indices.contains(rangeIndex) ? all[rangeIndex] : all[0]
    }

    private var visibleIndices: [Int] {
        EpisodeShelfLayout.indices(in: activeRange, descending: isDescending)
    }

    private var gridRows: [[Int]] {
        EpisodeShelfLayout.rows(from: visibleIndices)
    }

    private var currentItemIndex: Int? {
        guard let currentID else { return nil }
        return items.firstIndex { $0.id == currentID }
    }

    private var rangeCaption: String {
        guard !activeRange.isEmpty else { return "" }
        let start = activeRange.lowerBound + 1
        let end = activeRange.upperBound
        return isDescending ? "第 \(end)–\(start) 集" : "第 \(start)–\(end) 集"
    }

    /// 展开前第 0 帧的精确高度估算，保证动画从第一帧就顺滑展开，首帧渲染后再由 Preference 锁定精确像素高度。
    private var estimatedExpandedHeight: CGFloat {
        let rowCount = max(1, gridRows.count)
        let gridHeight: CGFloat = rowCount > EpisodeShelfLayout.maxUnscrolledRows
            ? EpisodeShelfLayout.scrolledGridHeight
            : CGFloat(rowCount) * EpisodeShelfLayout.tileHeight
                + CGFloat(max(rowCount - 1, 0)) * EpisodeShelfLayout.gridSpacing
        let toolbarHeight: CGFloat = 30
        let rangeRowHeight: CGFloat = ranges.count > 1 ? 42 : 0
        let footerHeight: CGFloat = hasExpandedFooter ? 59 : 0
        let bottomPad: CGFloat = hasExpandedFooter ? 0 : EpisodeShelfLayout.cardPadding
        return EpisodeShelfLayout.cardPadding
            + toolbarHeight
            + 10
            + rangeRowHeight
            + gridHeight
            + footerHeight
            + bottomPad
    }

    private var targetCardHeight: CGFloat {
        isExpanded ? (measuredExpandedHeight ?? estimatedExpandedHeight) : measuredStripHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            headerRow
            topAccessory()

            if !items.isEmpty {
                morphingCard
            }

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
        .onAppear {
            rangeIndex = rangeContainingCurrent()
        }
        .onChange(of: isDescending) { _ in
            rangeIndex = rangeContainingCurrent()
        }
        .onChange(of: items.count) { count in
            rangeIndex = rangeContainingCurrent()
            if count <= 1 && isExpanded { isExpanded = false }
            if !isExpanded { measuredExpandedHeight = nil }
        }
    }

    // MARK: 标题与展开/收起按钮

    private var headerRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text("选集")
                    .font(Theme.Typo.section)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !summary.isEmpty {
                    Text(summary)
                        .font(Theme.Typo.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if items.count > 1 {
                expandToggleButton
            }
        }
    }

    private var expandToggleButton: some View {
        Button {
            Haptics.select()
            let opening = !isExpanded
            if opening {
                rangeIndex = rangeContainingCurrent()
            }
            let anim = reduceMotion ? nil : (opening ? Self.expandAnimation : Self.collapseAnimation)
            withAnimation(anim) {
                isExpanded = opening
            }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(isExpanded ? "收起" : "全部")
                    .font(Theme.Typo.caption.weight(.semibold))
                    .contentTransition(.opacity)
                Image(icon: .expand)
                    .font(.scaled(10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(isExpanded ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 30)
            .background(isExpanded ? Theme.surfaceHigh : Theme.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isExpanded ? Theme.rule : Theme.hairline, lineWidth: Theme.Stroke.hairline)
            }
            .contentShape(VerticalHitArea(extra: 7))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.94))
        .animation(reduceMotion ? nil : Motion.snappy, value: isExpanded)
        .accessibilityLabel(isExpanded ? "收起选集" : "展开全部选集")
        .accessibilityIdentifier(identifiers.toggle)
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }

    // MARK: 变形卡片容器（收起态横排 ↔ 展开态抽屉）

    private var morphingCard: some View {
        let cardShape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return ZStack(alignment: .top) {
            if isExpanded {
                expandedContent
                    .fixedSize(horizontal: false, vertical: true)
                    .background { heightSensor(EpisodeExpandedHeightKey.self) }
                    .transition(
                        reduceMotion
                            ? .identity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -8)),
                                removal: .opacity.combined(with: .offset(y: -4))
                            )
                    )
            } else {
                stripContent
                    .fixedSize(horizontal: false, vertical: true)
                    .background { heightSensor(EpisodeStripHeightKey.self) }
                    .transition(
                        reduceMotion
                            ? .identity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 4)),
                                removal: .opacity.combined(with: .offset(y: -4))
                            )
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: targetCardHeight, alignment: .top)
        .background(Theme.surface)
        .clipShape(cardShape)
        .overlay {
            cardShape.strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline)
        }
        .onPreferenceChange(EpisodeStripHeightKey.self) { height in
            guard height > 0, abs(measuredStripHeight - height) > 0.5 else { return }
            measuredStripHeight = height
        }
        .onPreferenceChange(EpisodeExpandedHeightKey.self) { height in
            guard height > 0 else { return }
            if let existing = measuredExpandedHeight {
                guard abs(existing - height) > 0.5 else { return }
                withAnimation(reduceMotion ? nil : Motion.snappy) {
                    measuredExpandedHeight = height
                }
            } else {
                measuredExpandedHeight = height
            }
        }
    }

    private func heightSensor<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        }
    }

    // MARK: 收起态 · 一行横排

    private var stripContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: EpisodeShelfLayout.gridSpacing) {
                    ForEach(items) { item in
                        tileView(item, fillWidth: false)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, EpisodeShelfLayout.cardPadding)
                .padding(.vertical, EpisodeShelfLayout.stripVerticalPadding)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) {
                if items.count > 5 {
                    LinearGradient(
                        colors: [Theme.surface.opacity(0), Theme.surface],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 18)
                    .allowsHitTesting(false)
                }
            }
            .onAppear { scrollStripToCurrent(proxy, animated: false) }
            .onChange(of: currentID) { _ in scrollStripToCurrent(proxy, animated: !reduceMotion) }
            .onChange(of: items.first?.id) { _ in scrollStripToCurrent(proxy, animated: false) }
        }
    }

    private func scrollStripToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let targetID = currentID ?? items.first?.id else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(Motion.resolved(Motion.smooth, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
    }

    // MARK: 展开态 · 分段 + 排序 + 五列网格

    private var expandedContent: some View {
        let allRanges = ranges
        let rows = gridRows
        return VStack(alignment: .leading, spacing: 10) {
            // 顶部工具栏：当前分段提示 + 正序/倒序滑块
            HStack(spacing: Theme.Space.sm) {
                Text(rangeCaption)
                    .font(Theme.Typo.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.opacity)
                Spacer(minLength: Theme.Space.sm)
                orderToggle
            }
            .padding(.horizontal, EpisodeShelfLayout.cardPadding)

            // 超过 50 集时展示分段胶囊
            if allRanges.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(allRanges.enumerated()), id: \.offset) { index, range in
                                SelectionPill(
                                    title: "\(range.lowerBound + 1)-\(range.upperBound)",
                                    selected: index == rangeIndex,
                                    namespace: rangeNamespace
                                ) {
                                    withAnimation(reduceMotion ? nil : Motion.snappy) { rangeIndex = index }
                                }
                                .id(index)
                                .accessibilityIdentifier("\(identifiers.rangePrefix).\(range.lowerBound + 1)")
                            }
                        }
                        .padding(.horizontal, EpisodeShelfLayout.cardPadding - 2)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(rangeIndex, anchor: .center) }
                    }
                    .onChange(of: rangeIndex) { index in
                        withAnimation(reduceMotion ? nil : Motion.smooth) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }

            // 五列网格：超过 25 集在卡片内部滚动，避免整页被几百集撑成高墙
            if rows.count > EpisodeShelfLayout.maxUnscrolledRows {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        episodeGridRows(rows)
                            .padding(.horizontal, EpisodeShelfLayout.cardPadding)
                            .padding(.bottom, Theme.Space.sm)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: EpisodeShelfLayout.scrolledGridHeight)
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [Theme.surface.opacity(0), Theme.surface],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 16)
                        .allowsHitTesting(false)
                    }
                    .onAppear {
                        if let rowIdx = rowContainingCurrent(in: rows) {
                            DispatchQueue.main.async {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    proxy.scrollTo(rowIdx, anchor: .center)
                                }
                            }
                        }
                    }
                }
            } else {
                episodeGridRows(rows)
                    .padding(.horizontal, EpisodeShelfLayout.cardPadding)
            }

            // 展开底部附加区（例如竖屏播放器的「自动连播」开关）
            if hasExpandedFooter {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: Theme.Stroke.hairline)
                        .padding(.horizontal, EpisodeShelfLayout.cardPadding)
                    expandedFooter()
                }
            }
        }
        .padding(.top, EpisodeShelfLayout.cardPadding)
        .padding(.bottom, hasExpandedFooter ? 0 : EpisodeShelfLayout.cardPadding)
    }

    /// 同步计算高度的五列网格；换段、正序/倒序时直接换格子内容，不做整块淡入淡出。
    private func episodeGridRows(_ rows: [[Int]]) -> some View {
        VStack(spacing: EpisodeShelfLayout.gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowOffset, row in
                HStack(spacing: EpisodeShelfLayout.gridSpacing) {
                    ForEach(row, id: \.self) { index in
                        if items.indices.contains(index) {
                            tileView(items[index], fillWidth: true)
                        }
                    }
                    if row.count < EpisodeShelfLayout.columns {
                        ForEach(0..<(EpisodeShelfLayout.columns - row.count), id: \.self) { _ in
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: EpisodeShelfLayout.tileHeight)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .id(rowOffset)
            }
        }
        .transaction { $0.animation = nil }
    }

    private func rowContainingCurrent(in rows: [[Int]]) -> Int? {
        guard let currentIdx = currentItemIndex else { return nil }
        return rows.firstIndex { $0.contains(currentIdx) }
    }

    private func rangeContainingCurrent() -> Int {
        EpisodeShelfLayout.rangeIndex(containing: currentItemIndex, in: ranges)
    }

    // MARK: 正序 / 倒序切换

    private var orderToggle: some View {
        HStack(spacing: 0) {
            orderPill("正序", icon: .sortAscending, selected: !isDescending, id: identifiers.ascending) {
                isDescending = false
            }
            orderPill("倒序", icon: .sortDescending, selected: isDescending, id: identifiers.descending) {
                isDescending = true
            }
        }
        .padding(Theme.Space.hair)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline)
        }
    }

    private func orderPill(_ title: String, icon: AppIcon, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.select()
            withAnimation(reduceMotion ? nil : Motion.snappy) { action() }
        } label: {
            HStack(spacing: 3) {
                Image(icon: icon)
                    .font(.scaled(11, weight: .medium))
                Text(title)
                    .font(.scaled(11, weight: selected ? .bold : .medium))
            }
            .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.sm)
            .frame(minHeight: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip - Theme.Space.hair, style: .continuous)
                        .fill(Theme.primaryAction)
                        .matchedGeometryEffect(id: "episode.order.thumb", in: orderNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.95))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: 单集格子

    @ViewBuilder
    private func tileView(_ item: EpisodeShelfItem, fillWidth: Bool) -> some View {
        let tile = UnifiedEpisodeTile(
            item: item,
            isCurrent: item.id == currentID,
            showsNowPlaying: showsNowPlayingOnCurrent,
            fillWidth: fillWidth
        ) {
            onSelect(item)
        }
        if showsTileContextMenu {
            tile.contextMenu { tileMenu(item) }
        } else {
            tile
        }
    }
}

// MARK: - 便捷初始化器（省去不用的槽位）

extension UnifiedEpisodeShelf where TopAccessory == EmptyView, ExpandedFooter == EmptyView, TileMenu == EmptyView {
    init(
        items: [EpisodeShelfItem],
        currentID: String?,
        summary: String,
        isExpanded: Binding<Bool>,
        isDescending: Binding<Bool>,
        showsNowPlayingOnCurrent: Bool = false,
        identifiers: EpisodeShelfIdentifiers,
        caption: String? = nil,
        onSelect: @escaping (EpisodeShelfItem) -> Void
    ) {
        self.init(
            items: items,
            currentID: currentID,
            summary: summary,
            isExpanded: isExpanded,
            isDescending: isDescending,
            showsNowPlayingOnCurrent: showsNowPlayingOnCurrent,
            showsTileContextMenu: false,
            identifiers: identifiers,
            caption: caption,
            onSelect: onSelect,
            topAccessory: { EmptyView() },
            expandedFooter: { EmptyView() },
            tileMenu: { _ in EmptyView() }
        )
    }
}

extension UnifiedEpisodeShelf where ExpandedFooter == EmptyView, TileMenu == EmptyView {
    init(
        items: [EpisodeShelfItem],
        currentID: String?,
        summary: String,
        isExpanded: Binding<Bool>,
        isDescending: Binding<Bool>,
        showsNowPlayingOnCurrent: Bool = false,
        identifiers: EpisodeShelfIdentifiers,
        caption: String? = nil,
        onSelect: @escaping (EpisodeShelfItem) -> Void,
        @ViewBuilder topAccessory: @escaping () -> TopAccessory
    ) {
        self.init(
            items: items,
            currentID: currentID,
            summary: summary,
            isExpanded: isExpanded,
            isDescending: isDescending,
            showsNowPlayingOnCurrent: showsNowPlayingOnCurrent,
            showsTileContextMenu: false,
            identifiers: identifiers,
            caption: caption,
            onSelect: onSelect,
            topAccessory: topAccessory,
            expandedFooter: { EmptyView() },
            tileMenu: { _ in EmptyView() }
        )
    }
}

extension UnifiedEpisodeShelf where TopAccessory == EmptyView, TileMenu == EmptyView {
    init(
        items: [EpisodeShelfItem],
        currentID: String?,
        summary: String,
        isExpanded: Binding<Bool>,
        isDescending: Binding<Bool>,
        showsNowPlayingOnCurrent: Bool = false,
        identifiers: EpisodeShelfIdentifiers,
        caption: String? = nil,
        onSelect: @escaping (EpisodeShelfItem) -> Void,
        @ViewBuilder expandedFooter: @escaping () -> ExpandedFooter
    ) {
        self.init(
            items: items,
            currentID: currentID,
            summary: summary,
            isExpanded: isExpanded,
            isDescending: isDescending,
            showsNowPlayingOnCurrent: showsNowPlayingOnCurrent,
            showsTileContextMenu: false,
            identifiers: identifiers,
            caption: caption,
            onSelect: onSelect,
            topAccessory: { EmptyView() },
            expandedFooter: expandedFooter,
            tileMenu: { _ in EmptyView() }
        )
    }
}

extension UnifiedEpisodeShelf where ExpandedFooter == EmptyView {
    init(
        items: [EpisodeShelfItem],
        currentID: String?,
        summary: String,
        isExpanded: Binding<Bool>,
        isDescending: Binding<Bool>,
        showsNowPlayingOnCurrent: Bool = false,
        identifiers: EpisodeShelfIdentifiers,
        caption: String? = nil,
        onSelect: @escaping (EpisodeShelfItem) -> Void,
        @ViewBuilder topAccessory: @escaping () -> TopAccessory,
        @ViewBuilder tileMenu: @escaping (EpisodeShelfItem) -> TileMenu
    ) {
        self.init(
            items: items,
            currentID: currentID,
            summary: summary,
            isExpanded: isExpanded,
            isDescending: isDescending,
            showsNowPlayingOnCurrent: showsNowPlayingOnCurrent,
            showsTileContextMenu: TileMenu.self != EmptyView.self,
            identifiers: identifiers,
            caption: caption,
            onSelect: onSelect,
            topAccessory: topAccessory,
            expandedFooter: { EmptyView() },
            tileMenu: tileMenu
        )
    }
}

// MARK: - 统一单集格子 (UnifiedEpisodeTile)

/// 统一规格的单集方块：46pt 高、10pt 圆角；
/// 当前集主操作色实心（播放器里附带正在播放微柱），未看完带底部琥珀进度线，已看完置灰并右上角打勾。
struct UnifiedEpisodeTile: View {
    let item: EpisodeShelfItem
    let isCurrent: Bool
    var showsNowPlaying: Bool = false
    var fillWidth: Bool = false
    let onTap: () -> Void

    private var progress: Double { item.progress ?? 0 }
    private var finished: Bool { item.isFinished }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
        let button = Button {
            Haptics.tap()
            onTap()
        } label: {
            ZStack {
                shape.fill(isCurrent ? Theme.primaryAction : Theme.surfaceRaised)

                VStack(spacing: Theme.Space.hair) {
                    Text(item.shortTitle)
                        .font(.scaled(15, weight: isCurrent ? .bold : .semibold).monospacedDigit())
                        .foregroundStyle(isCurrent ? Theme.onPrimary : (finished ? Theme.textTertiary : Theme.textPrimary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    if isCurrent && showsNowPlaying {
                        Image(icon: .nowPlaying)
                            .font(.scaled(8, weight: .semibold))
                            .foregroundStyle(Theme.onPrimary.opacity(0.85))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 6)

                if finished && !isCurrent {
                    Image(icon: .check)
                        .font(.scaled(8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: fillWidth ? nil : EpisodeShelfLayout.stripTileMinWidth, minHeight: EpisodeShelfLayout.tileHeight, maxHeight: EpisodeShelfLayout.tileHeight)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .overlay(alignment: .bottom) {
                if progress > 0.02 && !finished && !(isCurrent && showsNowPlaying) {
                    GeometryReader { proxy in
                        let railWidth = max(4, proxy.size.width - 16)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(isCurrent ? Theme.onPrimary.opacity(0.18) : Theme.track)
                            Capsule()
                                .fill(isCurrent ? Theme.onPrimary.opacity(0.6) : Theme.accent)
                                .frame(width: max(4, railWidth * min(progress, 1)))
                        }
                        .frame(width: railWidth, height: 2.5)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(height: 2.5)
                    .padding(.bottom, 5)
                }
            }
            .overlay {
                if !isCurrent {
                    shape.strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.pressable(scale: 0.94))
        .accessibilityLabel(item.accessibilityTitle)
        .accessibilityValue(item.accessibilityValue)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])

        if let id = item.accessibilityID {
            button.accessibilityIdentifier(id)
        } else {
            button
        }
    }
}
