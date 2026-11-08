import Foundation

enum AnimePlaybackError: LocalizedError {
    case invalidPlayCode
    case parserFailed(String)
    case decryptUrlFailed
    case noPlayableURL

    var errorDescription: String? {
        switch self {
        case .invalidPlayCode: return "无效的播放凭证"
        case .parserFailed(let msg): return "解析服务失败: \(msg)"
        case .decryptUrlFailed: return "媒体地址解密失败"
        case .noPlayableURL: return "未找到有效的播放地址"
        }
    }
}

final class AnimePlaybackResolver {
    static let shared = AnimePlaybackResolver()

    private let md5AesKey = "UY9kxQEtk8Dn08Kr"
    private let md5AesIv  = "J5jQnzGVRfCe4CUk"
    private let apiEndpoint = "http://jxbfdm.cenmo.fun/?md5="
    private let apiHost = "jxbfdm.cenmo.fun"
    private let fallbackIPs = ["120.240.157.64", "183.232.189.187", "111.29.14.203", "183.214.145.89"]
    private let authKey = "EV330AVbUcpZz5csLp6k8g4XYAqlbWG"
    private let authExpire = 600

    private let headerAuthKey = "T8qW2mN6rY4pLc9V"
    private let headerExtraKey = "C6rX9mQ2tV7pLs4N"
    private let headerProbeKey = "522828731F1A016B"
    private let headerCheckKey = "522828731F1A016B"

    private init() {}

    // MARK: - 主解析入口

    func resolve(playCode: String, title: String = "") async throws -> AnimeResolvedStream {
        let clean = playCode.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 如果本身就是直链（如小红书 MP4）
        if clean.hasPrefix("http://") || clean.hasPrefix("https://") {
            guard let url = URL(string: applyRewrites(clean)) else {
                throw AnimePlaybackError.invalidPlayCode
            }
            let isMp4 = url.absoluteString.lowercased().contains(".mp4")
            let quality = PlaybackQualityItem(id: "default", title: "1080P 高清", url: url)
            return AnimeResolvedStream(
                url: url,
                headers: ["User-Agent": ""],
                format: isMp4 ? "mp4" : "hls",
                title: title,
                qualityTitle: "1080P 高清",
                qualities: [quality]
            )
        }

        // 2. 必须以 new- 开头
        guard clean.hasPrefix("new-") else {
            throw AnimePlaybackError.invalidPlayCode
        }

        let md5source = String(clean.dropFirst(4))

        // 解析服务会间歇性抽风：同一份凭据上一次失败、下一次就成功。
        // 每次重试都重新生成 apiSource / sign / 三层头（签名带时间戳，不能复用旧的），
        // 否则一次网络抖动就直接播放失败。
        var lastError: Error = AnimePlaybackError.parserFailed("解析服务没有响应")
        for attempt in 0..<Self.parseAttempts {
            if Task.isCancelled { throw CancellationError() }
            let apiSource = encryptMd5Id(md5source)
            let authParam = generateAuthParams(path: "/", expire: authExpire, key: authKey)
            let headers = buildApiHeaders(path: "/", md5Param: apiSource, authParam: authParam)
            let requestURLString = apiEndpoint + apiSource + "&" + authParam

            do {
                let responseData = try await performParseRequest(urlString: requestURLString, headers: headers)
                return try parseResponse(data: responseData, title: title)
            } catch {
                lastError = error
                if attempt < Self.parseAttempts - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    private static let parseAttempts = 3

    // MARK: - 逆向混淆算法实现

    private func encryptMd5Id(_ md5str: String) -> String {
        let prefix = String(format: "%04d", Int.random(in: 0..<10000))
        let scrambled = String(md5str.lowercased().reversed())
        let guardHash = String(AnimeCrypto.md5("\(prefix):\(scrambled):\(md5AesKey):\(md5AesIv)").prefix(2))

        let index16 = scrambled.index(scrambled.startIndex, offsetBy: min(16, scrambled.count))
        let first16 = String(scrambled[..<index16])
        let remaining = String(scrambled[index16...])
        let wrapped = first16 + guardHash + remaining
        let dataStr = "\(prefix)-\(wrapped)"

        guard let data = dataStr.data(using: .utf8),
              let keyData = md5AesKey.data(using: .utf8),
              let ivData = md5AesIv.data(using: .utf8),
              let encrypted = AnimeCrypto.aes128CbcEncrypt(data: data, key: keyData, iv: ivData) else {
            return ""
        }
        return encrypted.base64EncodedString()
    }

    private func generateAuthParams(path: String, expire: Int, key: String) -> String {
        let expireAt = Int(Date().timeIntervalSince1970) + expire
        let rand = randomNonce(16)
        let uid = "0"
        let hash = AnimeCrypto.md5("\(path)-\(expireAt)-\(rand)-\(uid)-\(key)")
        return "sign=\(expireAt)-\(rand)-\(uid)-\(hash)"
    }

    private func buildClientHeader(path: String, md5Param: String, authParam: String, key: String, bindValues: [String]?, expireSeconds: Int?) -> String {
        let n = randomNonce(20)
        var seed: [String] = [path, md5Param, authParam]

        var expireAt: Int? = nil
        if let expireSeconds {
            expireAt = Int(Date().timeIntervalSince1970) + expireSeconds
            seed.append(String(expireAt!))
        }

        if let bindValues {
            for v in bindValues { seed.append(v) }
        }

        seed.append(n)
        seed.append(key)

        let hash = AnimeCrypto.md5(seed.joined(separator: "|"))
        if let expireAt {
            return "v1:\(expireAt):\(n):\(hash)"
        } else {
            return "v1:\(n):\(hash)"
        }
    }

    private func buildApiHeaders(path: String, md5Param: String, authParam: String) -> [String: String] {
        let auth = buildClientHeader(path: path, md5Param: md5Param, authParam: authParam, key: headerAuthKey, bindValues: nil, expireSeconds: authExpire)
        let extra = buildClientHeader(path: path, md5Param: md5Param, authParam: authParam, key: headerExtraKey, bindValues: [auth], expireSeconds: nil)
        let check = buildClientHeader(path: path, md5Param: md5Param, authParam: authParam, key: headerCheckKey, bindValues: [auth, extra], expireSeconds: nil)

        return [
            "Accept": "*/*",
            "Connection": "keep-alive",
            "X-Goepp-Client-Auth": auth,
            "X-Goepp-Client-Proof": extra,
            "X-Goepp-Client-Probe": headerProbeKey,
            "X-Goepp-Client-Check": check
        ]
    }

    private func randomNonce(_ count: Int) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<count).compactMap { _ in chars.randomElement() })
    }

    // MARK: - 网络请求与 IP 回退

    private func performParseRequest(urlString: String, headers: [String: String]) async throws -> Data {
        guard let originalURL = URL(string: urlString) else {
            throw AnimePlaybackError.invalidPlayCode
        }

        // 先尝试直连域名
        var request = URLRequest(url: originalURL, timeoutInterval: 12)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(apiHost, forHTTPHeaderField: "Host")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                return data
            }
        } catch {
            // 直连失败，进入备用 IP 循环重试
        }

        // 备用 IP 容灾
        for ip in fallbackIPs {
            let pathAndQuery = originalURL.path + (originalURL.query.map { "?\($0)" } ?? "")
            guard let ipURL = URL(string: "http://\(ip)\(pathAndQuery)") else { continue }
            var ipRequest = URLRequest(url: ipURL, timeoutInterval: 10)
            for (k, v) in headers { ipRequest.setValue(v, forHTTPHeaderField: k) }
            ipRequest.setValue(apiHost, forHTTPHeaderField: "Host")

            if let (data, response) = try? await URLSession.shared.data(for: ipRequest),
               let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                return data
            }
        }

        throw AnimePlaybackError.parserFailed("所有解析节点连接失败")
    }

    // MARK: - 响应解密与地址拼装

    private func parseResponse(data: Data, title: String) throws -> AnimeResolvedStream {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataDict = json["data"] as? [String: Any],
              let playAddrs = dataDict["playAddr"] as? [[String: Any]],
              !playAddrs.isEmpty else {
            throw AnimePlaybackError.parserFailed("解析响应数据为空或 code != 0")
        }

        // 使用互换密钥解密: key = md5AesIv, iv = md5AesKey
        guard let keyData = md5AesIv.data(using: .utf8),
              let ivData = md5AesKey.data(using: .utf8) else {
            throw AnimePlaybackError.decryptUrlFailed
        }

        var decodedStreams: [(quality: PlaybackQualityItem, isMp4: Bool, score: Int)] = []

        for (index, addrItem) in playAddrs.enumerated() {
            guard let addrCipher = addrItem["addr"] as? String,
                  let domainCipher = addrItem["m3u8FileDomain"] as? String,
                  let addrData = Data(base64Encoded: addrCipher),
                  let domainData = Data(base64Encoded: domainCipher),
                  let addrPlain = AnimeCrypto.aes128CbcDecrypt(data: addrData, key: keyData, iv: ivData),
                  let domainPlain = AnimeCrypto.aes128CbcDecrypt(data: domainData, key: keyData, iv: ivData),
                  let addrStr = String(data: addrPlain, encoding: .utf8),
                  let domainStr = String(data: domainPlain, encoding: .utf8) else {
                continue
            }

            var fullUrl = domainStr + addrStr
            if domainStr.contains("anixx.r2") {
                fullUrl = "https://sns-music.xhscdn.com/104002e031m0qe7o84s0m6saf3o"
            } else {
                fullUrl = applyRewrites(fullUrl)
            }

            guard let targetURL = URL(string: fullUrl) else { continue }
            let isMp4 = fullUrl.lowercased().contains(".mp4")

            let desc = (addrItem["desc"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let itemTitle = (addrItem["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let qualityName = !desc.isEmpty ? desc : (!itemTitle.isEmpty ? itemTitle : "1080P 高清")

            let width = addrItem["width"] as? Int ?? 0
            let height = addrItem["height"] as? Int ?? 0

            var score = width * height
            if qualityName.contains("4K") || qualityName.contains("2160") {
                score = max(score, 3840 * 2160)
            } else if qualityName.contains("1080") || qualityName.contains("原画") || qualityName.contains("蓝光") {
                score = max(score, 1920 * 1080)
            } else if qualityName.contains("720") || qualityName.contains("超清") {
                score = max(score, 1280 * 720)
            } else if qualityName.contains("480") || qualityName.contains("高清") {
                score = max(score, 854 * 480)
            } else if qualityName.contains("360") || qualityName.contains("标清") {
                score = max(score, 640 * 360)
            } else {
                score = max(score, 1)
            }

            let qualityItem = PlaybackQualityItem(id: "\(index)", title: qualityName, url: targetURL)
            decodedStreams.append((quality: qualityItem, isMp4: isMp4, score: score))
        }

        guard !decodedStreams.isEmpty else {
            throw AnimePlaybackError.noPlayableURL
        }

        // 按画质从最高到最低排序，默认播放最高画质
        decodedStreams.sort { $0.score > $1.score }

        let best = decodedStreams[0]
        let allQualities = decodedStreams.map(\.quality)

        return AnimeResolvedStream(
            url: best.quality.url,
            headers: ["User-Agent": ""],
            format: best.isMp4 ? "mp4" : "hls",
            title: title,
            qualityTitle: best.quality.title,
            qualities: allQualities
        )
    }

    // MARK: - 域名重写规则

    private func applyRewrites(_ urlString: String) -> String {
        var u = urlString
        u = u.replacingOccurrences(of: "play.ddmm.hzhcbkj.cn", with: "m3bkbfdm.hzhcbkj.cn")
        u = u.replacingOccurrences(of: "new.ddmm.hzhcbkj.cn", with: "m3bkbfdm.hzhcbkj.cn")
        u = u.replacingOccurrences(of: "bdmov.a.yximgs.com", with: "v4-kling.kechuangai.com")
        u = u.replacingOccurrences(of: "hwmov6.a.yximgs.com", with: "v4-kling.kechuangai.com")
        u = u.replacingOccurrences(of: "sns-video-default.xhscdn.com", with: "sns-video-bd.xhscdn.com")
        return u
    }
}
