import XCTest
import CommonCrypto
@testable import HPlayer

final class AnimeSecurityTests: XCTestCase {

    func testMD5HashCalculation() {
        let input = "hello anime"
        let hash = AnimeCrypto.md5(input)
        XCTAssertEqual(hash, "f06889680fa6bed118b1071dcb95be86")
    }

    func testAES256RoundTrip() {
        let key = Data("ziISjqkXPsGUMRNGyWigxDGtJbfTdcGv".utf8)
        let iv = Data("WonrnVkxeIxDcFbv".utf8)
        let plain = "2.4.7.9-1794108715730-IOS-1.0.0.1-10E3199773CC47A99F20B09F17B365D8"
        let plainData = Data(plain.utf8)

        guard let encrypted = AnimeCrypto.aes256CbcEncrypt(data: plainData, key: key, iv: iv) else {
            XCTFail("AES256 加密失败")
            return
        }

        XCTAssertFalse(encrypted.isEmpty)

        // 解密验证
        var outData = Data(count: encrypted.count + 16)
        var outLength = 0
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let cipherBytes = [UInt8](encrypted)

        let status = outData.withUnsafeMutableBytes { outBuf in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                keyBytes, key.count,
                ivBytes,
                cipherBytes, encrypted.count,
                outBuf.baseAddress, outBuf.count,
                &outLength
            )
        }

        XCTAssertEqual(status, Int32(kCCSuccess))
        outData.count = outLength
        XCTAssertEqual(String(data: outData, encoding: .utf8), plain)
    }

    func testAES128RoundTrip() {
        let key = Data("UY9kxQEtk8Dn08Kr".utf8)
        let iv = Data("J5jQnzGVRfCe4CUk".utf8)
        let plain = "test-stream-address-payload-12345"
        let plainData = Data(plain.utf8)

        guard let encrypted = AnimeCrypto.aes128CbcEncrypt(data: plainData, key: key, iv: iv) else {
            XCTFail("AES128 加密失败")
            return
        }

        guard let decrypted = AnimeCrypto.aes128CbcDecrypt(data: encrypted, key: key, iv: iv) else {
            XCTFail("AES128 解密失败")
            return
        }

        XCTAssertEqual(String(data: decrypted, encoding: .utf8), plain)
    }

    func testAnimeSignerHeaders() {
        let ts: Int64 = 1794108715730
        let headers = AnimeSigner.shared.headers(customTimestamp: ts)

        XCTAssertEqual(headers["x-version"], "2024-09-24")
        XCTAssertEqual(headers["user-agent"], "Dart/3.6 (dart:io)")
        XCTAssertEqual(headers["appid"], "4150439554430627")
        XCTAssertEqual(headers["ts"], "1794108715730")
        XCTAssertFalse(headers["authentication"]?.isEmpty ?? true)
    }

    func testSignerPrefersIssuedTokenAndDropsExpiredOnes() {
        let suite = "signer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let signer = AnimeSigner(defaults: defaults)
        func jwt(exp: TimeInterval) -> String {
            let payload = Data("{\"UUID\":\"u\",\"exp\":\(Int(exp))}".utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        }
        let fresh = jwt(exp: Date().timeIntervalSince1970 + 3600)
        let stale = jwt(exp: Date().timeIntervalSince1970 - 10)
        XCTAssertTrue(AnimeSigner.isExpired(stale))
        XCTAssertFalse(AnimeSigner.isExpired(fresh))
        signer.adoptIssuedToken("not-a-jwt")
        XCTAssertNotEqual(signer.token, "not-a-jwt")
        signer.adoptIssuedToken(" \(fresh)\n")
        XCTAssertEqual(signer.token, fresh)
        XCTAssertEqual(signer.headers()["x-token"], fresh)
        signer.adoptIssuedToken(stale)
        XCTAssertNotEqual(signer.token, stale, "过期的令牌不再带上")
        signer.discardIssuedToken()
        signer.discardIssuedToken()
        XCTAssertEqual(signer.token, "", "内置令牌被拒后不带令牌，等服务端重新下发")
        XCTAssertNil(signer.headers()["x-token"])
    }

    func testRequestBodyIsHybridEncryptedWithSendKey() throws {
        let payload = try AnimeCrypto.shared.encryptRequest(Data("{}".utf8))
        let parts = payload.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(Data(base64Encoded: parts[0])?.count, 256, "RSA-2048 加密的随机密钥")
        XCTAssertEqual(Data(base64Encoded: parts[1])?.count, 16, "不足一块的明文补齐成一块 AES")
        XCTAssertEqual(payload.count, 369, "和原 App 抓包里短请求体的 content-length 一致")
    }

    func testAccountModelsReadRealFields() {
        let user = AnimeUser(json: ["id": 2817982, "user_name": "Hilax", "email": "a@b.c", "coin": 690, "signnum": 2,
                                    "isvip": false, "pic_url": "http://6666.com/resource/img/icon/x.jpg"])
        XCTAssertEqual(user.displayName, "Hilax")
        XCTAssertEqual(user.coin, 690)
        XCTAssertEqual(user.signDays, 2)
        XCTAssertEqual(user.avatarURL, "", "占位域名的头像当作没有")
        let task = AnimeTask(json: ["id": 1, "title": "签到", "action": "sign", "coin": 30, "num": 1])
        XCTAssertEqual(task?.isSign, true)
        XCTAssertEqual(task?.coin, 30)
        let reply = AnimeComment(json: ["id": 897906, "uname": "可乐", "comments": "正文", "last_id": 264121,
                                        "last_name": "老佛爷", "islike": true], kind: .list)
        XCTAssertEqual(reply?.replyTo, "老佛爷")
        XCTAssertEqual(reply?.liked, true)
        XCTAssertEqual(reply?.numericID, 897906)
    }

    func testAccountUserCachePersistsAndClears() throws {
        let suite = "AnimeAccountCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let user = AnimeUser(json: [
            "id": 2817982,
            "user_name": "Hilax",
            "email": "a@b.c",
            "coin": 690,
            "signnum": 5,
            "isvip": true,
        ])
        AnimeAccount.saveCachedUser(user, in: defaults)
        XCTAssertEqual(AnimeAccount.loadCachedUser(from: defaults), user)

        AnimeAccount.clearCachedUser(from: defaults)
        XCTAssertNil(AnimeAccount.loadCachedUser(from: defaults))
    }

    func testCommentKeepsAllInlineRepliesAndPreviewsThree() {
        let children: [[String: Any]] = (1...5).map {
            ["id": 900 + $0, "uname": "回复\($0)", "comments": "内容\($0)", "last_id": $0 == 2 ? 901 : 264121,
             "last_name": $0 == 2 ? "回复1" : "老佛爷"]
        }
        let comment = AnimeComment(json: ["id": 264121, "uname": "老佛爷", "comments": "置顶", "children_total": 135,
                                          "children": children], kind: .top)
        XCTAssertEqual(comment?.children.count, 5, "保留接口内嵌的全部回复")
        XCTAssertEqual(comment?.preview.count, 3, "列表里只预览前三条")
        XCTAssertEqual(comment?.replies, 135)
        XCTAssertEqual(comment?.children.first?.displayedReplyTarget(under: 264121), "", "直接回复楼主时不重复显示回复对象")
        XCTAssertEqual(comment?.children[1].displayedReplyTarget(under: 264121), "回复1", "楼中楼回复保留被回复人")
    }

    func testSubCommentsPathUsesThemeCIDAndOptionalMarker() {
        XCTAssertEqual(
            AnimeClient.subCommentsPath(themeCommentID: 264121, marker: nil, limit: 20),
            "/app/vod_comment/getsublist?theme_cid=264121&limit=20"
        )
        XCTAssertEqual(
            AnimeClient.subCommentsPath(themeCommentID: 264121, marker: 897906, limit: 5),
            "/app/vod_comment/getsublist?theme_cid=264121&marker=897906&limit=5"
        )
    }

    func testCommentWritePayloadsMatchProtocol() {
        let likeOn = AnimeLikeStore.likeBody(vid: 181964, commentID: 264121, like: true)
        XCTAssertEqual(likeOn["vid"] as? Int, 181964)
        XCTAssertEqual(likeOn["id"] as? Int, 264121)
        XCTAssertEqual(likeOn["like"] as? Bool, true)

        let likeOff = AnimeLikeStore.likeBody(vid: 181964, commentID: 264121, like: false)
        XCTAssertEqual(likeOff["like"] as? Bool, false)

        let topBody = AnimeSocial.createBody(vid: 181964, text: "顶层评论", replyTo: nil, captcha: nil, answer: "")
        XCTAssertEqual(topBody["vid"] as? Int, 181964)
        XCTAssertEqual(topBody["comments"] as? String, "顶层评论")
        XCTAssertEqual(topBody["last_id"] as? Int, 0)
        XCTAssertNil(topBody["uuid"])

        let parent = AnimeComment(localID: 264121, userName: "老佛爷", content: "置顶", replyTo: "")
        let child = AnimeComment(localID: 897906, userName: "可乐", content: "回复", replyTo: "老佛爷", lastID: 264121)
        let captcha = AnimeCaptcha(uuid: "ygqf2sve1qq4UyMNcqoV", image: UIImage())

        let replyTopBody = AnimeSocial.createBody(vid: 181964, text: "回楼主", replyTo: parent, captcha: captcha, answer: " 42 ")
        XCTAssertEqual(replyTopBody["last_id"] as? Int, 264121)
        XCTAssertEqual(replyTopBody["uuid"] as? String, "ygqf2sve1qq4UyMNcqoV")
        XCTAssertEqual(replyTopBody["dots"] as? String, "42")

        let replyChildBody = AnimeSocial.createBody(vid: 181964, text: "回楼中楼", replyTo: child, captcha: nil, answer: "")
        XCTAssertEqual(replyChildBody["last_id"] as? Int, 897906)
    }

    @MainActor
    func testCommentReplyStoreMergesAndDeduplicates() {
        let store = AnimeCommentReplyStore.shared
        store.reset()
        defer { store.reset() }

        let root = AnimeComment(json: [
            "id": 264121,
            "uname": "老佛爷",
            "comments": "置顶",
            "children_total": 1,
            "children": [["id": 897906, "uname": "可乐", "comments": "旧回复", "last_id": 264121, "last_name": "老佛爷"]]
        ], kind: .top)!

        let newReply = AnimeComment(localID: 900999, userName: "我", content: "刚刚发的新回复", replyTo: "老佛爷", lastID: 264121)
        store.record(newReply, under: 264121)

        XCTAssertEqual(store.totalReplies(for: root), 2)
        XCTAssertEqual(store.mergedPreview(for: root).map(\.numericID), [900999, 897906])
        XCTAssertEqual(store.mergedSubComments(for: 264121, fetched: root.children).map(\.numericID), [900999, 897906])

        let fetchedWithServerCopy = [newReply] + root.children
        XCTAssertEqual(store.mergedSubComments(for: 264121, fetched: fetchedWithServerCopy).map(\.numericID), [900999, 897906],
                       "服务端已经返回同 id 回复时不能重复出现")

        let refreshedRoot = AnimeComment(json: [
            "id": 264121,
            "uname": "老佛爷",
            "comments": "置顶",
            "children_total": 2,
            "children": [
                ["id": 900999, "uname": "我", "comments": "刚刚发的新回复", "last_id": 264121, "last_name": "老佛爷"],
                ["id": 897906, "uname": "可乐", "comments": "旧回复", "last_id": 264121, "last_name": "老佛爷"]
            ]
        ], kind: .top)!
        XCTAssertEqual(store.totalReplies(for: refreshedRoot), 2, "服务端已计入该回复时不重复累加")
    }

    func testReplyMessageReadsRealMessageboxReplyFields() {
        let json: [String: Any] = [
            "id": 900100,
            "uid": 1051175,
            "vid": 181964,
            "comments": "同意你的看法",
            "name": "可乐满贯",
            "quote_comments": "原评论内容",
            "quote_name": "我的昵称",
            "created_at": "2026-09-02T13:00:36+08:00",
            "state": 0
        ]
        let msg = AnimeMessage(json: json, kind: .reply)
        XCTAssertEqual(msg?.numericID, 900100)
        XCTAssertEqual(msg?.videoID, 181964)
        XCTAssertEqual(msg?.sender, "可乐满贯")
        XCTAssertEqual(msg?.content, "同意你的看法")
        XCTAssertEqual(msg?.quote, "原评论内容")
        XCTAssertEqual(msg?.quoteAuthor, "我的昵称")
        XCTAssertEqual(msg?.videoName, "", "回复消息里的 name 是回复者用户名，不能当成影片名")
        XCTAssertEqual(msg?.unread, true)
    }

    func testCommentReadsRealFieldNames() {
        let json: [String: Any] = ["id": 264121, "uname": "用户", "comments": "正文", "hits": 621, "istop": 1,
                                   "isvip": true, "children_total": 135, "created_at": "2026-09-02T13:00:36+08:00",
                                   "roles": [["group_name": "管理员"]]]
        let comment = AnimeComment(json: json, kind: .list)
        XCTAssertEqual(comment?.userName, "用户")
        XCTAssertEqual(comment?.content, "正文")
        XCTAssertEqual(comment?.likes, 621)
        XCTAssertEqual(comment?.replies, 135)
        XCTAssertEqual(comment?.pinned, true)
        XCTAssertEqual(comment?.role, "管理员")
        XCTAssertEqual(comment?.time, "09-02 13:00")
        XCTAssertEqual(AnimeJSON.records(in: ["total": 1, "items": [json]] as [String: Any]).count, 1)
    }

    func testDecodesRealWorldAnimePayloads() throws {
        // 接口真实样本：stars 在列表里是字符串、在详情里是数字。
        let listJSON = """
        {"code":20000,"message":"请求成功!","data":{"total":1,"items":[{"id":180167,"cid":20,"name":"恋爱与选举与巧克力","pic":"http://p4-ad.adukwai.com/x.jpg","year":"2012","area":"日本","continu":"13全","type":"后宫,校园","stars":""}]}}
        """
        let listResponse = try JSONDecoder().decode(
            AnimeAPIResponse<AnimeVideoListResult>.self, from: Data(listJSON.utf8)
        )
        XCTAssertEqual(listResponse.data?.items.first?.name, "恋爱与选举与巧克力")
        XCTAssertEqual(listResponse.data?.items.first?.safePicURLString, "https://p4-ad.adukwai.com/x.jpg")

        let detailJSON = """
        {"code":20000,"message":"请求成功!","data":{"id":180167,"name":"恋爱与选举与巧克力","stars":1,"pic":"http://p4-ad.adukwai.com/x.jpg","parts":[{"play":"newup-jp","play_zh":"日语","single_clarity_display":1,"part":["第01集"]}]}}
        """
        let detailResponse = try JSONDecoder().decode(
            AnimeAPIResponse<AnimeVideoDetail>.self, from: Data(detailJSON.utf8)
        )
        XCTAssertEqual(detailResponse.data?.stars, "1")
        XCTAssertEqual(detailResponse.data?.safePicURLString, "https://p4-ad.adukwai.com/x.jpg")
        XCTAssertEqual(detailResponse.data?.parts.first?.part.first, "第01集")
    }

    func testAnimeQualityResolutionAndSorting() throws {
        let q1 = PlaybackQualityItem(id: "0", title: "720P 高清", url: URL(string: "http://example.com/720.m3u8")!)
        let q2 = PlaybackQualityItem(id: "1", title: "1080P 超清", url: URL(string: "http://example.com/1080.m3u8")!)
        let q3 = PlaybackQualityItem(id: "2", title: "480P 标清", url: URL(string: "http://example.com/480.m3u8")!)

        let stream = AnimeResolvedStream(
            url: q2.url,
            headers: ["User-Agent": ""],
            format: "hls",
            title: "测试番剧 第01集",
            qualityTitle: "1080P 超清",
            qualities: [q2, q1, q3]
        )

        // 验证默认画质为最高画质
        XCTAssertEqual(stream.qualityTitle, "1080P 超清")
        XCTAssertEqual(stream.url.absoluteString, "http://example.com/1080.m3u8")
        XCTAssertEqual(stream.qualities.count, 3)

        // 验证构建出的 PlaybackSource 包含多画质
        let source = PlaybackSource.online(
            title: stream.title,
            url: stream.url,
            headers: stream.headers,
            qualities: stream.qualities,
            currentQuality: stream.qualityTitle
        )
        if case .online(_, let url, _, let qualities, let curQ) = source {
            XCTAssertEqual(url.absoluteString, "http://example.com/1080.m3u8")
            XCTAssertEqual(curQ, "1080P 超清")
            XCTAssertEqual(qualities.count, 3)
        } else {
            XCTFail("PlaybackSource.online 匹配失败")
        }
    }

    /// 旧版本写入的播放记录没有 finished 字段，必须还能读出来，否则升级后播放历史全丢。
    func testRecentItemDecodesLegacyRecordWithoutFinishedFlag() throws {
        let legacy = """
        {"id":"a1","title":"测试番剧 第01集","url":"https://example.com/a.m3u8","playedAt":0,"position":120,"duration":600}
        """
        let item = try JSONDecoder().decode(RecentItem.self, from: Data(legacy.utf8))
        XCTAssertNil(item.finished)
        XCTAssertEqual(item.position, 120)
        XCTAssertEqual(item.progress ?? 0, 0.2, accuracy: 0.0001)
    }

    /// 看完的一集 position 会被清掉，靠 finished 标记才能在选集里打勾。
    func testRecentItemFinishedRecordHasNoResumePosition() throws {
        let json = """
        {"id":"a2","title":"测试番剧 第02集","url":"https://example.com/b.m3u8","playedAt":0,"finished":true}
        """
        let item = try JSONDecoder().decode(RecentItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.finished, true)
        XCTAssertNil(item.position)
        XCTAssertNil(item.progress)
    }

    /// 选集倒序必须是稳定的新数组，且集数标题不会互相误配。
    func testEpisodeOrderingAndTitleMatching() throws {
        let episodes = ["第01集", "第02集", "第03集", "第10集"]
        let descending = Array(episodes.reversed())
        XCTAssertEqual(descending, ["第10集", "第03集", "第02集", "第01集"])
        XCTAssertEqual(episodes, ["第01集", "第02集", "第03集", "第10集"], "原数组不应被倒序改动")

        // 按完整标题精确匹配：「第1集」不能命中「第10集」的记录
        let titles = Dictionary(episodes.map { ("测试番剧 \($0)", $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(titles["测试番剧 第10集"], "第10集")
        XCTAssertNil(titles["测试番剧 第1集"])
    }
}
