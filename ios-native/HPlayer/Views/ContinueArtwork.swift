import SwiftUI
import Combine

// MARK: - 继续观看的封面

/// 「继续观看」里不在片库的记录（在线动漫、在线短剧、磁力）观看记录本身不带封面，这里按记录去找一张：
/// - 在线动漫：按番剧编号，先看追番、首页在线列表里有没有，没有再拉一次详情取海报；
/// - 在线短剧：按短剧编号拉详情取封面（密文，显示时本机解密，见 DramaCoverStore）；
/// - 磁力：从资源名 / 文件名里认出番号，去 DMM 找官方封面（横版封套）。
/// 找到的地址存在本机，下次直接用；没找到的过一段时间再试。
@MainActor
final class ContinueArtworkStore: ObservableObject {
    static let shared = ContinueArtworkStore()

    /// 找到的封面
    enum Artwork: Codable, Equatable {
        /// 横图，直接铺满卡片
        case wide(String)
        /// 竖海报：铺一层虚化，海报立在中间
        case poster(String)
        /// 短剧的密文竖封面
        case drama(String)
    }

    @Published private(set) var artworks: [String: Artwork] = [:]
    private var running: Set<String> = []
    private var missedAt: [String: Date] = [:]
    private static let defaultsKey = "hplayer.continue.artworks"
    private static let missLifetime: TimeInterval = 30 * 60

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Artwork].self, from: data) {
            artworks = saved
        }
    }

    /// 这条记录用哪个键查封面；不是这三类（或认不出）返回 nil。
    static func key(for target: ContinueEntry.Target) -> String? {
        switch target {
        case .recent(let recent):
            if let id = recent.animeId { return "anime|\(id)" }
            if let ref = recent.dramaRef { return "drama|\(ref.videoId)" }
            return nil
        case .magnet(let item):
            return "magnet|\(item.infoHash)"
        }
    }

    func artwork(for target: ContinueEntry.Target) -> Artwork? {
        Self.key(for: target).flatMap { artworks[$0] }
    }

    /// 没有就去找（同一条只找一次；没找到的半小时内不再找）
    func resolve(_ target: ContinueEntry.Target) async {
        guard !InterfacePreview.active, let key = Self.key(for: target), artworks[key] == nil,
              !running.contains(key) else { return }
        if let missed = missedAt[key], Date().timeIntervalSince(missed) < Self.missLifetime { return }
        running.insert(key)
        defer { running.remove(key) }
        if let found = await lookup(target) {
            artworks[key] = found
            save()
        } else {
            missedAt[key] = Date()
        }
    }

    private func lookup(_ target: ContinueEntry.Target) async -> Artwork? {
        switch target {
        case .recent(let recent):
            if let id = recent.animeId { return await animePoster(id) }
            if let ref = recent.dramaRef {
                guard let detail = try? await DramaClient.shared.detail(id: ref.videoId), !detail.cover.isEmpty else { return nil }
                return .drama(detail.cover)
            }
            return nil
        case .magnet(let item):
            let code = AVCatalogCode.extract(item.name) ?? item.lastFileTitle.flatMap(AVCatalogCode.extract)
            guard let code, let url = await MagnetCoverFallback.shared.url(for: code) else { return nil }
            return .wide(url.absoluteString)
        }
    }

    private func animePoster(_ id: Int) async -> Artwork? {
        if let pic = AnimeWatchlistStore.shared.items.first(where: { $0.id == id })?.pic, !pic.isEmpty {
            return .poster(Self.https(pic))
        }
        let online = HomeOnlineFeed.shared
        if let item = (online.trending + online.latest).first(where: { $0.id == id }), !item.safePicURLString.isEmpty {
            return .poster(item.safePicURLString)
        }
        guard let detail = try? await AnimeClient.shared.fetchDetail(id: id), let pic = detail.pic, !pic.isEmpty else { return nil }
        return .poster(Self.https(pic))
    }

    private static func https(_ value: String) -> String {
        value.hasPrefix("http://") ? "https://" + value.dropFirst(7) : value
    }

    private func save() {
        if let data = try? JSONEncoder().encode(artworks) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// 继续观看卡片 / 观看历史行里的封面：片库影片用自己的图；在线动漫、短剧、磁力用 ContinueArtworkStore 找到的封面。
/// 竖海报不硬裁成横图：铺一层虚化，海报立在中间。
struct ContinueArtworkView: View {
    let entry: ContinueEntry
    let width: CGFloat
    let height: CGFloat
    @ObservedObject private var store = ContinueArtworkStore.shared

    var body: some View {
        Group {
            if !entry.artworkURL.isEmpty {
                wide(entry.artworkURL)
            } else {
                switch store.artwork(for: entry.target) {
                case .wide(let url)?:
                    wide(url)
                case .poster(let url)?:
                    poster {
                        ArtworkView(urlString: url, title: entry.title)
                    } background: {
                        ArtworkView(urlString: url, title: "", maxPixel: ArtworkSize.backdrop,
                                    loading: .neutral, drawsFallback: false)
                    }
                case .drama(let url)?:
                    poster {
                        DramaCover(urlString: url, title: entry.title)
                    } background: {
                        DramaCover(urlString: url, title: "")
                    }
                case nil:
                    ArtworkView(urlString: "", title: entry.title)
                        .scaledToFill()
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: entry.id) {
            if entry.artworkURL.isEmpty { await store.resolve(entry.target) }
        }
    }

    private func wide(_ url: String) -> some View {
        Color.clear
            .overlay {
                ArtworkView(urlString: url, title: entry.title)
                    .scaledToFill()
            }
            .clipped()
    }

    private func poster<Front: View, Back: View>(@ViewBuilder _ front: () -> Front,
                                                 @ViewBuilder background: () -> Back) -> some View {
        ZStack {
            background()
                .scaledToFill()
                .frame(width: width / 3, height: height / 3)
                .clipped()
                .blur(radius: 5)
                .scaleEffect(3.4)
                .frame(width: width, height: height)
                .clipped()
                .overlay(Color.black.opacity(0.15))
            front()
                .scaledToFill()
                .frame(width: height * 0.86 / 1.5, height: height * 0.86)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        }
        .frame(width: width, height: height)
        .background(Theme.surfaceRaised)
    }
}
