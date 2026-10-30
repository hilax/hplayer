import Foundation

/// 匹配过程的简要记录（最近 300 条），排查「为什么没匹配上、为什么慢」用。
/// 只含番号或片名关键词、来源、状态码和耗时，不含 Cookie、Key 或网盘路径。
final class MatchDiagnostics: @unchecked Sendable {
    static let shared = MatchDiagnostics()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 300

    func record(_ message: String) {
        let stamp = Self.stamp(Date())
        lock.lock()
        lines.append("\(stamp) \(message)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        lines = []
        lock.unlock()
    }

    private static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return String(format: "%02d:%02d:%02d.%03d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, (parts.nanosecond ?? 0) / 1_000_000)
    }

    static func describe(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain)(\(value.code)) \(value.localizedDescription)"
    }

    /// 返回内容的顶层字段名，接口改了格式时一眼能看出来。
    static func keys(of data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "不是 JSON（\(data.count) 字节）" }
        if let dictionary = object as? [String: Any] {
            return "字段：" + dictionary.keys.sorted().joined(separator: ",").prefix(300)
        }
        return "JSON 数组（\((object as? [Any])?.count ?? 0) 项）"
    }

    static func seconds(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }
}
