import Foundation

/// 文件名解析结果存到磁盘。
///
/// 启动时要先把整个片库的文件名解析一遍（每个名字十几个正则），才能恢复封面、算出首页；
/// 片库上千个文件时这一步要等一会儿，首页就先空白一下。存下来以后，下次启动直接读，只解析新加入的文件。
/// 装了新版本（解析规则可能变了）缓存自动作废，重新解析一遍。
enum ParsedNameDiskCache {
    /// 解析规则改动时加一，旧缓存立即作废。装新包本身也会让缓存作废，这里是双保险。
    static let revision = 1

    private struct Payload: Codable {
        let stamp: String
        let names: [String: MediaNameParser.ParsedName]
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("hplayer-parsed-names.json")
    }

    /// 当前安装的标记：解析规则版本 + App 版本 + 可执行文件的修改时间（每装一次新包都会变）。
    static var currentStamp: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "")-\(info?["CFBundleVersion"] ?? "")"
        var built = ""
        if let path = Bundle.main.executableURL?.path,
           let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            built = String(Int(date.timeIntervalSince1970))
        }
        return "\(revision)|\(version)|\(built)"
    }

    /// 读出上次保存的解析结果；文件不存在、损坏或标记对不上（换了版本）都返回空。
    static func load(from url: URL = defaultURL, stamp: String = currentStamp) -> [String: MediaNameParser.ParsedName] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.stamp == stamp else { return [:] }
        return payload.names
    }

    static func save(_ names: [String: MediaNameParser.ParsedName], to url: URL = defaultURL, stamp: String = currentStamp) {
        guard let data = try? JSONEncoder().encode(Payload(stamp: stamp, names: names)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
