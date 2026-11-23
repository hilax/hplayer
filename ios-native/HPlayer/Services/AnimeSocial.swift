import Foundation

/// 评论点赞的本地状态：点下去先改界面，接口失败再改回来。
@MainActor
final class AnimeLikeStore: ObservableObject {
    static let shared = AnimeLikeStore()

    private struct Override: Equatable {
        let liked: Bool
        let count: Int
    }

    @Published private var overrides: [Int: Override] = [:]
    private var pending: Set<Int> = []

    func liked(_ comment: AnimeComment) -> Bool { overrides[comment.numericID]?.liked ?? comment.liked }
    func count(_ comment: AnimeComment) -> Int { overrides[comment.numericID]?.count ?? comment.likes }

    nonisolated static func likeBody(vid: Int, commentID: Int, like: Bool) -> [String: Any] {
        ["vid": vid, "id": commentID, "like": like]
    }

    /// 点赞 / 取消点赞（`POST /app/vod_comment/likes`，按协议传 `like: true/false`）
    func toggle(_ comment: AnimeComment, vid: Int) async throws {
        let id = comment.numericID
        guard id > 0, !pending.contains(id) else { return }
        let before = Override(liked: liked(comment), count: count(comment))
        let after = Override(liked: !before.liked, count: max(0, before.count + (before.liked ? -1 : 1)))
        overrides[id] = after
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            try await AnimeClient.shared.perform("/app/vod_comment/likes", method: "POST",
                                                 body: Self.likeBody(vid: vid, commentID: id, like: after.liked))
            Haptics.select()
        } catch {
            overrides[id] = before
            throw error
        }
    }
}

/// 刚发出去的回复缓存：让评论列表行里的回复预览、回复计数和回复详情页保持同步。
@MainActor
final class AnimeCommentReplyStore: ObservableObject {
    static let shared = AnimeCommentReplyStore()

    @Published private var added: [Int: [AnimeComment]] = [:]

    func record(_ reply: AnimeComment, under rootID: Int) {
        guard rootID > 0 else { return }
        var list = added[rootID] ?? []
        list.removeAll { Self.sameComment($0, reply) }
        list.insert(reply, at: 0)
        added[rootID] = list
    }

    func reset() {
        added.removeAll()
    }

    func mergedPreview(for comment: AnimeComment) -> [AnimeComment] {
        let extras = nonDuplicateLocalReplies(for: comment.numericID, existing: comment.children)
        return Array((extras + comment.children).prefix(3))
    }

    func totalReplies(for comment: AnimeComment) -> Int {
        let extras = nonDuplicateLocalReplies(for: comment.numericID, existing: comment.children)
        return comment.replies + extras.count
    }

    func mergedSubComments(for rootID: Int, fetched: [AnimeComment]) -> [AnimeComment] {
        let extras = nonDuplicateLocalReplies(for: rootID, existing: fetched)
        return extras + fetched
    }

    private func nonDuplicateLocalReplies(for rootID: Int, existing: [AnimeComment]) -> [AnimeComment] {
        guard rootID > 0, let local = added[rootID], !local.isEmpty else { return [] }
        return local.filter { candidate in
            !existing.contains { Self.sameComment($0, candidate) }
        }
    }

    private static func sameComment(_ lhs: AnimeComment, _ rhs: AnimeComment) -> Bool {
        if lhs.id == rhs.id { return true }
        return lhs.numericID > 0 && lhs.numericID == rhs.numericID
    }
}

enum AnimeSocial {
    static func createBody(vid: Int, text: String, replyTo: AnimeComment?, captcha: AnimeCaptcha?, answer: String) -> [String: Any] {
        var body: [String: Any] = ["vid": vid, "comments": text, "last_id": replyTo?.numericID ?? 0]
        if let captcha {
            body["uuid"] = captcha.uuid
            body["dots"] = answer.trimmingCharacters(in: .whitespaces)
        }
        return body
    }

    /// 发评论 / 回复（`POST /app/vod_comment/create`）。顶层评论 `last_id = 0`；回复时为被回复那条的 `id`。
    @discardableResult
    static func postComment(vid: Int, text: String, replyTo: AnimeComment?, captcha: AnimeCaptcha?, answer: String) async throws -> Int {
        let body = createBody(vid: vid, text: text, replyTo: replyTo, captcha: captcha, answer: answer)
        let data = try await AnimeClient.shared.perform("/app/vod_comment/create", method: "POST", body: body)
        return (data as? [String: Any]).flatMap { AnimeJSON.int($0, ["id"]) } ?? 0
    }

    /// 服务端要求先过验证码（发得太频繁）
    static func needsCaptcha(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("验证码") || text.contains("验证") || text.lowercased().contains("captcha")
    }

    /// 发出去之后同步回复缓存并通知列表更新
    @MainActor
    static func announce(_ comment: AnimeComment, vid: Int, rootID: Int? = nil) {
        if let rootID, rootID > 0 {
            AnimeCommentReplyStore.shared.record(comment, under: rootID)
        }
        var info: [String: Any] = ["vid": vid, "comment": comment]
        if let rootID, rootID > 0 {
            info["rootID"] = rootID
        }
        NotificationCenter.default.post(name: .animeCommentPosted, object: nil, userInfo: info)
    }
}

extension Notification.Name {
    static let animeCommentPosted = Notification.Name("anime.commentPosted")
}
