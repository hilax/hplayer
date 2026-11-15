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

    /// 点赞 / 取消点赞（`POST /app/vod_comment/likes`，同一个接口来回切换）
    func toggle(_ comment: AnimeComment, vid: Int) async throws {
        let id = comment.numericID
        guard id > 0, !pending.contains(id) else { return }
        let before = Override(liked: liked(comment), count: count(comment))
        let after = Override(liked: !before.liked, count: max(0, before.count + (before.liked ? -1 : 1)))
        overrides[id] = after
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            try await AnimeClient.shared.perform("/app/vod_comment/likes", method: "POST", body: ["id": id, "vid": vid])
            Haptics.select()
        } catch {
            overrides[id] = before
            throw error
        }
    }
}

enum AnimeSocial {
    /// 发评论（`POST /app/vod_comment/create`）。回复时 last_id 是被回复那条的 id。
    static func postComment(vid: Int, text: String, replyTo: AnimeComment?, captcha: AnimeCaptcha?, answer: String) async throws {
        var body: [String: Any] = ["vid": vid, "comments": text, "last_id": replyTo?.numericID ?? 0]
        if let captcha {
            body["uuid"] = captcha.uuid
            body["dots"] = answer.trimmingCharacters(in: .whitespaces)
        }
        try await AnimeClient.shared.perform("/app/vod_comment/create", method: "POST", body: body)
    }

    /// 服务端要求先过验证码（发得太频繁）
    static func needsCaptcha(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("验证码") || text.contains("验证")
    }

    /// 发出去之后通知列表把这条插到最前面
    static func announce(_ comment: AnimeComment, vid: Int) {
        NotificationCenter.default.post(name: .animeCommentPosted, object: nil, userInfo: ["vid": vid, "comment": comment])
    }
}

extension Notification.Name {
    static let animeCommentPosted = Notification.Name("anime.commentPosted")
}
