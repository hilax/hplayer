import Foundation
import SwiftUI

/// 弹幕显示设置（@AppStorage 键）。
enum DanmakuPrefs {
    static let enabled = "danmaku.enabled"
    /// 占画面高度的比例：0.25 / 0.5 / 0.75 / 1
    static let area = "danmaku.area"
    static let opacity = "danmaku.opacity"
    /// 字号倍数
    static let scale = "danmaku.scale"
    /// 速度倍数
    static let speed = "danmaku.speed"

    static let baseFontSize: CGFloat = 17
    /// 基准速度（点/秒）。所有弹幕同速，排好轨道就不会追尾。
    static let baseSpeed: CGFloat = 140
    /// 排轨道时预留的轨道数；画面放不下的轨道直接不显示（弹幕太密时自然丢一部分）。
    static let laneSlots = 24
    /// 发弹幕可选的颜色（ARGB）：白色 + 棱镜五色（全应用只有弹幕取色用棱镜色）
    static let sendColors: [UInt32] = [0xFFFFFFFF, 0xFFFF5C7A, 0xFFFFB224, 0xFF46C27D, 0xFF3DA5F4, 0xFF8E6CF6]
    /// 上次发弹幕选的颜色
    static let sendColor = "danmaku.sendColor"
}

/// 一条排好轨道的弹幕
struct PlacedDanmaku: Identifiable {
    let item: AnimeDanmaku
    let lane: Int
    var id: String { item.id }
    var time: Double { item.time }
}

/// 在线动漫的弹幕：按播放进度 60 秒一段拉取，快到下一段时提前拉，合并排序后统一排轨道。
@MainActor
final class DanmakuStore: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: DanmakuPrefs.enabled)
            if enabled { update(time: lastTime) }
        }
    }
    @Published private(set) var placed: [PlacedDanmaku] = []
    @Published private(set) var loadedCount = 0

    /// 播放时钟锚点：currentTime 更新不够密，叠层按这两个值插值出每一帧的时间。
    private(set) var anchorTime: Double = 0
    private(set) var anchorDate = Date()

    private var ref: AnimeEpisodeRef?
    private var generation = 0
    private var items: [String: AnimeDanmaku] = [:]
    private var requested: Set<Int> = []
    private var failedAt: [Int: Date] = [:]
    private var lastTime: Double = 0
    private let window = 60.0

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: DanmakuPrefs.enabled) as? Bool ?? true
    }

    /// 换集（或第一次打开）时调用；不是在线动漫传 nil。
    func configure(_ ref: AnimeEpisodeRef?) {
        guard ref != self.ref else { return }
        self.ref = ref
        generation += 1
        items = [:]
        requested = []
        failedAt = [:]
        placed = []
        loadedCount = 0
        lastTime = 0
        anchorTime = 0
        anchorDate = Date()
    }

    /// 播放进度变化时调用：更新时钟锚点，按需拉当前段和下一段。
    func update(time: Double) {
        anchorTime = time
        anchorDate = Date()
        lastTime = time
        guard enabled, ref != nil, !InterfacePreview.active, time.isFinite, time >= 0 else { return }
        let index = Int(time / window)
        fetch(index)
        if time - Double(index) * window >= window * 0.75 { fetch(index + 1) }
    }

    /// 叠层每帧调用：从锚点按倍速往前推，最多推 1.5 秒，免得卡顿时弹幕跑到画面前面去。
    func clock(at date: Date, playing: Bool, rate: Double) -> Double {
        guard playing else { return anchorTime }
        return anchorTime + min(max(date.timeIntervalSince(anchorDate), 0), 1.5) * rate
    }

    /// 能不能发弹幕（只有在线动漫的分集才有）
    var canSend: Bool { ref != nil }

    /// 发一条弹幕（`POST /app/danmu/`）。content 和拉取时一样是 JSON 字符串：{"color": ARGB, "content": 文本}。
    /// 发成功后马上插到当前时间点，带「自己发的」描边。
    func send(text: String, color: UInt32, at time: Double, captcha: AnimeCaptcha?, answer: String) async throws {
        guard let ref else { throw AnimeClientError.emptyData }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = try JSONSerialization.data(withJSONObject: ["color": Int(color), "content": cleaned])
        let point = max(0, Int(time * 1000))
        var body: [String: Any] = ["vid": ref.animeId, "play": ref.play, "part": ref.part,
                                   "content": String(decoding: inner, as: UTF8.self), "time_point": point]
        if let captcha {
            body["uuid"] = captcha.uuid
            body["dots"] = answer.trimmingCharacters(in: .whitespaces)
        }
        let data = try await AnimeClient.shared.perform("/app/danmu/", method: "POST", body: body)
        let id = (data as? [String: Any]).flatMap { AnimeJSON.string($0, ["id"]) } ?? "mine-\(UUID().uuidString)"
        guard self.ref == ref else { return }
        // 稍微往后放一点，发完回到画面上正好从右边进来
        let item = AnimeDanmaku(id: id, time: time + 0.3, text: cleaned, color: color, mine: true)
        items[item.id] = item
        loadedCount = items.count
        if !enabled { enabled = true }
        relayout()
    }

    /// 速度设置改了要重新排轨道
    func relayout() {
        placed = Self.layout(items.values.sorted { ($0.time, $0.id) < ($1.time, $1.id) })
    }

    private func fetch(_ index: Int) {
        guard let ref, !requested.contains(index) else { return }
        if let failed = failedAt[index], Date().timeIntervalSince(failed) < 30 { return }
        requested.insert(index)
        let token = generation
        let start = Int(Double(index) * window * 1000)
        let end = Int(Double(index + 1) * window * 1000)
        Task { [weak self] in
            do {
                let batch = try await AnimeClient.shared.fetchDanmaku(id: ref.animeId, play: ref.play, part: ref.part,
                                                                      startMs: start, endMs: end)
                guard let self, self.generation == token else { return }
                self.merge(batch)
            } catch {
                guard let self, self.generation == token else { return }
                self.requested.remove(index)
                self.failedAt[index] = Date()
            }
        }
    }

    private func merge(_ batch: [AnimeDanmaku]) {
        guard !batch.isEmpty else { return }
        for item in batch { items[item.id] = item }
        loadedCount = items.count
        relayout()
    }

    /// 贪心排轨道：同速运动，只要前一条的尾巴已经完全进入画面，后一条就能在同一轨道出发。
    static func layout(_ sorted: [AnimeDanmaku]) -> [PlacedDanmaku] {
        let speedFactor = UserDefaults.standard.object(forKey: DanmakuPrefs.speed) as? Double ?? 1
        let scale = UserDefaults.standard.object(forKey: DanmakuPrefs.scale) as? Double ?? 1
        let speed = Double(DanmakuPrefs.baseSpeed) * max(speedFactor, 0.3)
        let charWidth = Double(DanmakuPrefs.baseFontSize) * max(scale, 0.5)
        let gap = 24.0
        var freeAt = Array(repeating: -Double.infinity, count: DanmakuPrefs.laneSlots)
        var result: [PlacedDanmaku] = []
        result.reserveCapacity(sorted.count)
        for item in sorted {
            guard let lane = freeAt.firstIndex(where: { $0 <= item.time }) else { continue }
            let width = Double(item.text.count) * charWidth
            freeAt[lane] = item.time + (width + gap) / speed
            result.append(PlacedDanmaku(item: item, lane: lane))
        }
        return result
    }
}
