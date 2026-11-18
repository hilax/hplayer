import SwiftUI

// MARK: - 动漫列表页

/// 一个频道（或全部）的完整列表：顶部是排序（最新上架 / 最多播放）和「筛选」按钮，
/// 下面几行横滑的筛选条（频道 / 类型 / 年份 / 地区 / 状态，单选），再下面是至少三列的海报网格，滑到底自动翻页。
/// 往下滑过筛选区后，顶部收成一条摘要栏，点它回到顶部；「筛选」打开面板，可以一次改完。
/// 从动漫频道货架的「全部」、快捷入口，首页热门新番的「全部」推进来。
struct AnimeBrowseView: View {
    let route: AnimeBrowseRoute

    @StateObject private var model: AnimeBrowseModel
    @ObservedObject private var store = AnimeHomeStore.shared
    @State private var headerHidden = false
    @State private var showsSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let topID = "anime.browse.top"
    private static let space = "anime.browse.scroll"

    init(route: AnimeBrowseRoute) {
        self.route = route
        _model = StateObject(wrappedValue: AnimeBrowseModel(route: route))
    }

    private var options: AnimeFilterOptions {
        AnimeFilterOptions.make(channels: store.channels, baseChannelId: model.baseChannelId,
                                selectedChannelId: model.filter.channelId)
    }

    var body: some View {
        let options = self.options
        let rows = AnimeBrowseRows.make(options: options, filter: model.filter)
        GeometryReader { proxy in
            let metrics = Self.metrics(width: proxy.size.width)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(rows: rows, options: options)
                            .id(Self.topID)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: BrowseHeaderBottomKey.self,
                                                           value: geometry.frame(in: .named(Self.space)).maxY)
                                }
                            }
                        content(metrics)
                    }
                    .padding(.bottom, 40)
                }
                .coordinateSpace(name: Self.space)
                .scrollIndicators(.hidden)
                .refreshable { await model.reload() }
                .onPreferenceChange(BrowseHeaderBottomKey.self) { bottom in
                    let hidden = bottom < 8
                    guard hidden != headerHidden else { return }
                    withAnimation(reduceMotion ? nil : Motion.quick) { headerHidden = hidden }
                }
                .overlay(alignment: .top) {
                    if headerHidden {
                        compactBar(options: options) {
                            withAnimation(reduceMotion ? nil : Motion.snappy) {
                                reader.scrollTo(Self.topID, anchor: .top)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsSheet) {
            AnimeFilterSheet(model: model, channels: store.channels, title: route.title)
                .presentationDetents([.large])
                .designSheet()
        }
        .task { await store.loadIfNeeded() }
        .task(id: options.years) { model.knownYears = options.years }
        .task { await model.loadIfNeeded() }
    }

    // MARK: 顶部：排序 + 筛选条 + 摘要

    private func header(rows: [AnimeBrowseRow], options: AnimeFilterOptions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 20) {
                    ForEach(AnimeBrowseRows.sorts, id: \.self) { sort in
                        sortTab(title: sort.title, value: sort.value)
                    }
                }
                Spacer(minLength: 8)
                filterButton(compact: false)
            }
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 4)
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    BrowseChipRow(row: row) { value in
                        model.set(row.field) { $0 = $0.setting(row.field, to: value) }
                    }
                }
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                Text(summaryText(options: options))
                    .font(.scaled(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.hasPreset && !model.isAtPreset {
                    textAction("恢复默认", identifier: "anime.filter.restore") { model.restorePreset() }
                } else if !model.filter.isEmpty && !model.hasPreset {
                    textAction("清除筛选", identifier: "anime.filter.clear") { model.clearAll() }
                }
            }
            .frame(minHeight: 32)
            .padding(.horizontal, Theme.contentInset)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    private func sortTab(title: String, value: String) -> some View {
        let selected = model.sort == value
        return Button {
            guard !selected else { return }
            Haptics.select()
            model.setSort(value)
        } label: {
            Text(title)
                .font(.scaled(15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("anime.sort.\(value)")
    }

    /// 「筛选」按钮：右上角的数字是改了几项
    private func filterButton(compact: Bool) -> some View {
        let count = model.filter.activeFields.count
        return Button {
            Haptics.tap()
            showsSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(icon: .tune).iconStyle(size: 15, color: Theme.textPrimary)
                if !compact {
                    Text("筛选")
                        .font(.scaled(14))
                        .foregroundStyle(Theme.textPrimary)
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.scaled(11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.onAccentFill)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accentFill, in: Capsule())
                }
            }
            .padding(.horizontal, compact ? 12 : 12)
            .frame(height: compact ? 40 : 34)
            .background(compact ? Theme.surface : Theme.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.94))
        .accessibilityLabel(count > 0 ? "筛选，已选 \(count) 项" : "筛选")
        .accessibilityIdentifier("anime.filter.open")
    }

    private func textAction(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Text(title)
                .font(.scaled(12))
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 32)
                .padding(.leading, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .accessibilityIdentifier(identifier)
    }

    /// 下滑后顶部的摘要栏：「最多播放 · 热血 · 连载中  49 部 ⌄」，点它回到顶部
    private func compactBar(options: AnimeFilterOptions, scrollToTop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: scrollToTop) {
                HStack(spacing: 8) {
                    Text(compactSummary(options: options))
                        .font(.scaled(14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let count = countText {
                        Text(count)
                            .font(.scaled(12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    Image(icon: .expand).iconStyle(size: 13, color: Theme.textSecondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Theme.surface, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable(scale: 0.98))
            .accessibilityLabel("当前条件：\(compactSummary(options: options))，点按展开筛选")
            .accessibilityIdentifier("anime.filter.summary")

            filterButton(compact: true)
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.vertical, 8)
        .background(Theme.pageBackground.shadow(.drop(color: .black.opacity(0.35), radius: 10, y: 6)))
    }

    // MARK: 文案

    private var countText: String? {
        if let total = model.trustedTotal { return "共 \(total.formatted()) 部" }
        guard !model.items.isEmpty else { return nil }
        return model.hasMore ? "已找到 \(model.items.count) 部" : "共 \(model.items.count) 部"
    }

    private func summaryText(options: AnimeFilterOptions) -> String {
        let parts = model.filter.activeFields.map { AnimeBrowseRows.title(of: $0, in: model.filter, options: options) }
        if model.isReloading && model.items.isEmpty {
            return parts.isEmpty ? "正在加载…" : parts.joined(separator: " · ")
        }
        return (parts + [countText].compactMap { $0 }).joined(separator: " · ")
    }

    private func compactSummary(options: AnimeFilterOptions) -> String {
        let sortTitle = AnimeBrowseRows.sorts.first { $0.value == model.sort }?.title ?? ""
        let parts = model.filter.activeFields.map { AnimeBrowseRows.title(of: $0, in: model.filter, options: options) }
        return ([sortTitle] + parts).joined(separator: " · ")
    }

    // MARK: 网格

    @ViewBuilder
    private func content(_ metrics: Metrics) -> some View {
        if model.isReloading && model.items.isEmpty {
            LazyVGrid(columns: columns(metrics), alignment: .leading, spacing: 16) {
                ForEach(0..<9, id: \.self) { _ in AnimePosterSkeleton(width: metrics.cell) }
            }
            .padding(.horizontal, Theme.contentInset)
            .accessibilityLabel("正在加载")
        } else if model.items.isEmpty {
            emptyOrError
        } else {
            LazyVGrid(columns: columns(metrics), alignment: .leading, spacing: 16) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    AnimeDetailLink(animeId: item.id) {
                        AnimePosterCard(item: item, width: metrics.cell)
                    }
                    .prefetchArtwork(after: index, in: model.items, count: metrics.columns * 3) { $0.safePicURLString }
                    .gridCardEntrance()
                    .onAppear {
                        if item.id == model.items.last?.id { Task { await model.loadMore() } }
                    }
                }
            }
            .padding(.horizontal, Theme.contentInset)
            // 不对整组 id 做插入动画：会和分页加载叠在一起，行会跳
            .transaction { $0.animation = nil }
            .id("anime-browse-\(model.sort)-\(model.filter.hashValue)")

            footer
        }
    }

    @ViewBuilder private var emptyOrError: some View {
        Group {
            if let errorMessage = model.errorMessage {
                EmptyStateView(icon: AppIcon.alert.name, title: "没有加载出来", message: errorMessage,
                               actionTitle: "重新加载") {
                    Task { await model.reload() }
                }
            } else if model.hasMore {
                // 服务端不认筛选参数时在 App 里筛，翻了几页还没凑到
                EmptyStateView(icon: AppIcon.search.name, title: "还没找到",
                               message: "已经翻了 \(model.scannedPages) 页，暂时没有符合条件的番剧。",
                               actionTitle: "继续查找") {
                    Task { await model.loadMore() }
                }
            } else if !model.filter.isEmpty {
                VStack(spacing: 0) {
                    if let field = model.suggestedRelax {
                        let title = AnimeBrowseRows.title(of: field, in: model.filter, options: options)
                        EmptyStateView(icon: AppIcon.tune.name, title: "没有符合条件的番剧",
                                       message: "条件可能叠得太多了，试试去掉一项。",
                                       actionTitle: "去掉「\(title)」") {
                            model.relax(field)
                        }
                    }
                    if model.filter.activeFields.count > 1 {
                        Button("清除全部筛选") { model.clearAll() }
                            .buttonStyle(SecondaryActionStyle())
                            .frame(maxWidth: 220)
                            .padding(.top, -20)
                            .accessibilityIdentifier("anime.filter.clearAll")
                    }
                }
            } else {
                EmptyStateView(icon: AppIcon.video.name, title: "暂时没有番剧",
                               message: "这里还没有内容，换个分类看看。")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    @ViewBuilder private var footer: some View {
        Group {
            if model.isLoadingMore {
                ProgressView().tint(Theme.textSecondary)
            } else if model.hasMore && model.lastRoundEmpty {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Text("这几页没有符合条件的，继续查找")
                        .font(.scaled(13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.pressable(scale: 0.97))
            } else if !model.hasMore {
                Text("已经到底了")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }

    // MARK: 网格尺寸

    private struct Metrics {
        let columns: Int
        let cell: CGFloat
        let spacing: CGFloat
    }

    /// 和片库同一套算法：至少三列、按屏宽算出固定列宽（flexible 列在外层 ScrollView 里会被图片撑得忽宽忽窄）
    private static func metrics(width: CGFloat) -> Metrics {
        let spacing: CGFloat = 10
        let available = max(width - Theme.contentInset * 2, 200)
        let columns = max(3, Int((available + spacing) / (118 + spacing)))
        let cell = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return Metrics(columns: columns, cell: cell, spacing: spacing)
    }

    private func columns(_ metrics: Metrics) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cell), spacing: metrics.spacing, alignment: .top), count: metrics.columns)
    }
}

/// 筛选区底边在滚动视图里的位置：滑出顶部后显示摘要栏
private struct BrowseHeaderBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 筛选行

struct AnimeBrowseOption: Hashable {
    let value: String
    let title: String
}

/// 一行筛选：「全部 X」+ 若干选项，单选
struct AnimeBrowseRow: Identifiable {
    let field: AnimeFilterField
    let label: String
    let allTitle: String
    let options: [AnimeBrowseOption]
    /// nil = 全部
    let selected: String?

    var id: AnimeFilterField { field }
}

struct AnimeBrowseSort: Hashable {
    let value: String
    let title: String
}

@MainActor
enum AnimeBrowseRows {
    /// 接口实测 addtime 与 weight 顺序一样，所以第二个排序用 hits（按播放量）
    static let sorts = [AnimeBrowseSort(value: "addtime", title: "最新上架"),
                        AnimeBrowseSort(value: "hits", title: "最多播放")]

    static func make(options: AnimeFilterOptions, filter: AnimeBrowseFilter) -> [AnimeBrowseRow] {
        var rows: [AnimeBrowseRow] = []
        func add(_ field: AnimeFilterField, _ label: String, _ all: String, _ values: [AnimeBrowseOption]) {
            var values = values
            // 当前选中的值不在选项里（比如换了频道、或预设的年份接口没给）也要显示出来
            if let selected = filter.value(for: field), !values.contains(where: { $0.value == selected }) {
                values.insert(AnimeBrowseOption(value: selected, title: title(of: field, in: filter, options: options)), at: 0)
            }
            guard !values.isEmpty else { return }
            rows.append(AnimeBrowseRow(field: field, label: label, allTitle: all, options: values,
                                       selected: filter.value(for: field)))
        }
        if !options.channels.isEmpty {
            add(.channel, "频道", "全部频道", options.channels.map { AnimeBrowseOption(value: String($0.id), title: $0.name) })
        }
        add(.type, "类型", "全部类型", options.types.map { AnimeBrowseOption(value: $0, title: $0) })
        add(.year, "年份", "全部年份", options.years.map { AnimeBrowseOption(value: $0, title: $0) })
        if options.areas.count > 1 || filter.area != nil {
            add(.area, "地区", "全部地区", options.areas.map { AnimeBrowseOption(value: $0, title: $0) })
        }
        add(.status, "状态", "全部状态", AnimeEndState.allCases.map { AnimeBrowseOption(value: $0.rawValue, title: $0.title) })
        return rows
    }

    /// 某一项当前值的显示文字
    static func title(of field: AnimeFilterField, in filter: AnimeBrowseFilter, options: AnimeFilterOptions) -> String {
        switch field {
        case .channel:
            guard let id = filter.channelId else { return "全部频道" }
            return options.channels.first { $0.id == id }?.name ?? AnimeHomeStore.shared.channels.first { $0.id == id }?.name ?? "频道"
        case .type: return filter.type ?? "全部类型"
        case .year: return filter.year ?? "全部年份"
        case .area: return filter.area ?? "全部地区"
        case .status: return filter.status?.title ?? "全部状态"
        }
    }
}

extension AnimeBrowseFilter {
    func value(for field: AnimeFilterField) -> String? {
        switch field {
        case .channel: return channelId.map(String.init)
        case .type: return type
        case .year: return year
        case .area: return area
        case .status: return status?.rawValue
        }
    }

    func setting(_ field: AnimeFilterField, to value: String?) -> AnimeBrowseFilter {
        var copy = self
        switch field {
        case .channel: copy.channelId = value.flatMap { Int($0) }
        case .type: copy.type = value
        case .year: copy.year = value
        case .area: copy.area = value
        case .status: copy.status = value.flatMap { AnimeEndState(rawValue: $0) }
        }
        return copy
    }
}

/// 页面上的一行横滑筛选条：选中的是浅底胶囊，其余是次要色文字
private struct BrowseChipRow: View {
    let row: AnimeBrowseRow
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    chip(row.allTitle, value: nil)
                    ForEach(row.options, id: \.value) { option in
                        chip(option.title, value: option.value)
                    }
                }
                .padding(.horizontal, Theme.contentInset - 4)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let selected = row.selected { reader.scrollTo(selected, anchor: .center) }
            }
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        let selected = row.selected == value
        return Button {
            guard !selected else { return }
            Haptics.select()
            onSelect(value)
        } label: {
            Text(title)
                .font(.scaled(14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background {
                    if selected { Capsule().fill(Theme.surfaceHigh) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .id(value ?? "all")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("anime.filter.\(row.field.rawValue).\(value ?? "all")")
    }
}

// MARK: - 筛选面板

/// 一次改完所有条件的底部面板：选好后点「查看 N 部」应用；服务端认这些条件时显示总数。
struct AnimeFilterSheet: View {
    @ObservedObject var model: AnimeBrowseModel
    let channels: [AnimeChannel]
    let title: String

    @State private var draft: AnimeBrowseFilter
    @State private var draftSort: String
    @State private var previewTotal: Int?
    @Environment(\.dismiss) private var dismiss

    init(model: AnimeBrowseModel, channels: [AnimeChannel], title: String) {
        self.model = model
        self.channels = channels
        self.title = title
        _draft = State(initialValue: model.filter)
        _draftSort = State(initialValue: model.sort)
    }

    private struct CountKey: Equatable {
        let filter: AnimeBrowseFilter
        let sort: String
    }

    var body: some View {
        let options = AnimeFilterOptions.make(channels: channels, baseChannelId: model.baseChannelId,
                                              selectedChannelId: draft.channelId)
        let rows = AnimeBrowseRows.make(options: options, filter: draft)
        VStack(spacing: 0) {
            HStack {
                Text("筛选 · \(title)")
                    .font(.scaled(17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(icon: .close).iconStyle(size: 16, color: Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.9))
                .accessibilityLabel("关闭")
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("排序", columns: 4) {
                        ForEach(AnimeBrowseRows.sorts, id: \.self) { sort in
                            SheetChip(title: sort.title, selected: draftSort == sort.value) { draftSort = sort.value }
                        }
                    }
                    ForEach(rows) { row in
                        section(row.label, columns: row.field == .year ? 5 : 4) {
                            SheetChip(title: "全部", selected: row.selected == nil) {
                                draft = draft.setting(row.field, to: nil)
                            }
                            ForEach(row.options, id: \.value) { option in
                                SheetChip(title: option.title, selected: row.selected == option.value) {
                                    draft = draft.setting(row.field, to: option.value)
                                }
                                .accessibilityIdentifier("anime.sheet.\(row.field.rawValue).\(option.value)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Button("重置") {
                    Haptics.select()
                    draft = AnimeBrowseFilter()
                }
                .buttonStyle(SecondaryActionStyle())
                .frame(width: 104)
                .accessibilityIdentifier("anime.sheet.reset")

                Button(previewTotal.map { "查看 \($0.formatted()) 部" } ?? "查看结果") {
                    Haptics.tap()
                    model.apply(filter: draft, sort: draftSort)
                    dismiss()
                }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityIdentifier("anime.sheet.apply")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .background(Theme.surface.ignoresSafeArea())
        .task(id: CountKey(filter: draft, sort: draftSort)) {
            previewTotal = nil
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let total = await model.previewCount(filter: draft, sort: draftSort)
            guard !Task.isCancelled else { return }
            previewTotal = total
        }
    }

    private func section<Content: View>(_ label: String, columns: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.scaled(13))
                .foregroundStyle(Theme.textTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                content()
            }
        }
    }
}

/// 面板里的选项格：选中是正文色实底 + 反色字，其余是浅底次要色字
private struct SheetChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard !selected else { return }
            Haptics.select()
            action()
        } label: {
            Text(title)
                .font(.scaled(14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(selected ? Theme.textPrimary : Theme.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
