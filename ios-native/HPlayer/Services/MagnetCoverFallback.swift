import Foundation

/// 磁力页封面的兜底：JavBus 对刚登记的新片，小图和大图常常都还没上传（一直回 404，重试没用）。
/// 这时按番号去 DMM 的图片服务找官方封面。只发送番号。
/// 结果按番号缓存：找到的整个运行期内有效；没找到的隔一段时间再查（新片可能过几天才有封面）。
actor MagnetCoverFallback {
    static let shared = MagnetCoverFallback()

    typealias Lookup = @Sendable (String) async -> URL?

    static let missLifetime: TimeInterval = 15 * 60

    private let lookup: Lookup
    private let now: @Sendable () -> Date
    private var found: [String: URL] = [:]
    private var missed: [String: Date] = [:]
    private var running: [String: Task<URL?, Never>] = [:]

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        lookup: @escaping Lookup = { code in
            guard let poster = await DMMClient.shared.lookupCover(code)?.posterURL else { return nil }
            return URL(string: poster)
        }
    ) {
        self.now = now
        self.lookup = lookup
    }

    func url(for code: String) async -> URL? {
        let key = code.uppercased()
        if let hit = found[key] { return hit }
        if let time = missed[key], now().timeIntervalSince(time) < Self.missLifetime { return nil }
        // 同一个番号同时有多个格子在等（列表和详情页）时，共用一次查询。
        if let task = running[key] { return await task.value }
        let lookup = self.lookup
        let task = Task<URL?, Never> { await lookup(key) }
        running[key] = task
        let result = await task.value
        running[key] = nil
        if let result { found[key] = result; missed[key] = nil } else if !Task.isCancelled { missed[key] = now() }
        return result
    }
}
