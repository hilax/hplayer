import Foundation

// MARK: - 番剧列表页的筛选条件

/// 连载状态：接口条目里的 isend（1 = 完结）
enum AnimeEndState: String, Hashable, CaseIterable {
    case ongoing, ended

    var title: String { self == .ongoing ? "连载中" : "已完结" }
}

/// 筛选里可以单独去掉的一项（频道只在「全部」类列表里出现）
enum AnimeFilterField: String, CaseIterable, Hashable {
    case channel, type, year, area, status
}

/// 番剧列表页的筛选条件，nil 表示不限。
struct AnimeBrowseFilter: Hashable {
    var channelId: Int? = nil
    var type: String? = nil
    var year: String? = nil
    var area: String? = nil
    var status: AnimeEndState? = nil

    var isEmpty: Bool { activeFields.isEmpty }

    /// 已经设了值的项，按页面上从上到下的顺序
    var activeFields: [AnimeFilterField] {
        AnimeFilterField.allCases.filter { isSet($0) }
    }

    func isSet(_ field: AnimeFilterField) -> Bool {
        switch field {
        case .channel: return channelId != nil
        case .type: return type != nil
        case .year: return year != nil
        case .area: return area != nil
        case .status: return status != nil
        }
    }

    mutating func clear(_ field: AnimeFilterField) {
        switch field {
        case .channel: channelId = nil
        case .type: type = nil
        case .year: year = nil
        case .area: area = nil
        case .status: status = nil
        }
    }

    /// 发给 /app/video/list 的额外参数（频道走 channel 参数，不在这里）。
    /// 接口文档没写这几个参数；服务端不认也不会报错，列表页会自己核对结果。
    var serverParameters: [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        if let type { result.append(("type", type)) }
        if let year { result.append(("year", year)) }
        if let area { result.append(("area", area)) }
        if let status { result.append(("isend", status == .ended ? "1" : "0")) }
        return result
    }

    /// 需要在 App 里核对的项（频道一定是服务端过滤的）
    var checkableFields: [AnimeFilterField] {
        activeFields.filter { $0 != .channel }
    }

    /// 某一项对这个条目是否成立；条目缺这个字段、判断不了时返回 nil。
    /// `knownYears` 是年份选项，用来判断「更早」这类非数字年份。
    func matches(_ item: AnimeVideoItem, field: AnimeFilterField, knownYears: [String]) -> Bool? {
        switch field {
        case .channel:
            return nil
        case .type:
            guard let type else { return nil }
            let raw = (item.type ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            return item.tags.contains(type) || raw.contains(type)
        case .year:
            guard let year else { return nil }
            guard let itemYear = Self.yearNumber(item.year) else { return nil }
            if let wanted = Int(year) { return itemYear == wanted }
            // 「更早」「其他」：比选项里最早的数字年份还早
            guard let earliest = knownYears.compactMap({ Int($0) }).min() else { return nil }
            return itemYear < earliest
        case .area:
            guard let area else { return nil }
            let raw = (item.area ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            return raw.contains(area) || area.contains(raw)
        case .status:
            guard let status else { return nil }
            let ended: Bool
            if let isend = item.isend {
                ended = isend == 1
            } else if let text = AnimeEpisodeText.status(item) {
                ended = text.title == "完结"
            } else {
                return nil
            }
            return ended == (status == .ended)
        }
    }

    /// 条目没有被任何一项明确排除（判断不了的项放行）
    func admits(_ item: AnimeVideoItem, knownYears: [String]) -> Bool {
        checkableFields.allSatisfy { matches(item, field: $0, knownYears: knownYears) != false }
    }

    private static func yearNumber(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.trimmingCharacters(in: .whitespaces).prefix(4)
        guard digits.count == 4, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

// MARK: - 服务端认不认筛选参数

/// 列表接口的文档只写了 channel / sort / limit / page。type / year / area / isend 照样发，
/// 再看第一页回来的条目是不是都符合条件：符合就当服务端认这个参数（总数可信），
/// 不符合就记成「App 自己筛」——之后每页都在本地过滤，并一次多拉几页。只在本次启动内记住。
@MainActor
final class AnimeFilterSupport {
    static let shared = AnimeFilterSupport()

    enum Mode { case unknown, server, client }

    private var modes: [AnimeFilterField: Mode] = [:]

    private init() {}

    func mode(_ field: AnimeFilterField) -> Mode {
        field == .channel ? .server : (modes[field] ?? .unknown)
    }

    /// 这组条件里的每一项服务端都认：总数可以直接用
    func trustsTotal(for filter: AnimeBrowseFilter) -> Bool {
        filter.checkableFields.allSatisfy { mode($0) == .server }
    }

    /// 有一项已知要靠 App 筛：翻页时一次多拉一些
    func needsLocalScan(for filter: AnimeBrowseFilter) -> Bool {
        filter.checkableFields.contains { mode($0) == .client }
    }

    /// 用第一页的条目判断每一项：能判断的条目里 95% 以上符合就算服务端认。
    func record(items: [AnimeVideoItem], filter: AnimeBrowseFilter, knownYears: [String]) {
        for field in filter.checkableFields {
            let verdicts = items.compactMap { filter.matches($0, field: field, knownYears: knownYears) }
            guard verdicts.count >= 6 else { continue }
            let ratio = Double(verdicts.filter { $0 }.count) / Double(verdicts.count)
            if ratio >= 0.95 {
                if modes[field] != .client { modes[field] = .server }
            } else {
                modes[field] = .client
            }
        }
    }
}

// MARK: - 筛选选项

/// 筛选行里的选项：来自 /app/channel 返回的 types / years / areas。
struct AnimeFilterOptions: Equatable {
    var channels: [AnimeChannel] = []
    var types: [String] = []
    var years: [String] = []
    var areas: [String] = []

    /// `baseChannelId` 是列表页本身的频道；为 nil 时是「全部」类列表，显示频道行，
    /// 选项用所选频道的，没选频道就合并所有频道的。
    static func make(channels: [AnimeChannel], baseChannelId: Int?, selectedChannelId: Int?) -> AnimeFilterOptions {
        let sources: [AnimeChannel]
        if let id = baseChannelId ?? selectedChannelId, let channel = channels.first(where: { $0.id == id }) {
            sources = [channel]
        } else {
            sources = channels
        }
        var options = AnimeFilterOptions()
        options.channels = baseChannelId == nil ? channels : []
        options.types = clean(sources.flatMap { $0.types ?? [] })
        options.years = clean(sources.flatMap { $0.years ?? [] })
        options.areas = clean(sources.flatMap { $0.areas ?? [] })
        if options.years.isEmpty {
            // 接口没给年份就用最近八年
            let current = Calendar.current.component(.year, from: Date())
            options.years = (0..<8).map { String(current - $0) }
        } else if options.years.allSatisfy({ Int($0) != nil }) {
            options.years.sort { (Int($0) ?? 0) > (Int($1) ?? 0) }
        }
        return options
    }

    /// 去空、去「全部」、去重，保留接口给的顺序
    private static func clean(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("全部") && $0 != "不限" }
            .filter { seen.insert($0).inserted }
    }
}
