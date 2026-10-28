import CryptoKit
import Foundation

struct MediaMetadata: Codable, Identifiable, Hashable {
    let imdbID: String
    let type: String
    let title: String
    let year: String
    let posterURL: String
    let backgroundURL: String
    let logoURL: String
    let overview: String
    let rating: String
    let genres: [String]
    let country: String
    let season: Int?
    let episode: Int?
    var matchedByHash = false

    var id: String { imdbID }
    var isSeries: Bool { type == "series" }
}

@MainActor
final class MediaMetadataStore: ObservableObject {
    @Published private(set) var metadataByMediaID: [String: MediaMetadata] = [:]
    @Published private(set) var resolvingIDs: Set<String> = []

    private let storageKey = "hplayer.mediaMetadata.v1"
    private var hashCache: [String: MediaMetadata] = [:]
    private var titleCache: [String: MediaMetadata] = [:]
    private var runningIDs: Set<String> = []

    init() {
        load()
    }

    func sync(files: [LocalMedia]) {
        let validIDs = Set(files.map(\.id))
        metadataByMediaID = metadataByMediaID.filter { validIDs.contains($0.key) }

        for file in files where metadataByMediaID[file.id] == nil && !runningIDs.contains(file.id) {
            runningIDs.insert(file.id)
            resolvingIDs.insert(file.id)
            Task { [weak self] in
                guard let self else { return }
                let metadata = await self.resolve(file)
                if let metadata {
                    self.metadataByMediaID[file.id] = metadata
                }
                self.runningIDs.remove(file.id)
                self.resolvingIDs.remove(file.id)
            }
        }
    }

    private func resolve(_ file: LocalMedia) async -> MediaMetadata? {
        let fingerprint = await MediaFingerprint.make(for: file.url)
        if let fingerprint, let cached = hashCache[fingerprint] {
            var metadata = cached
            metadata.matchedByHash = true
            return metadata
        }

        let parsed = MediaNameParser.parse(file.name)
        let titleKey = MediaNameParser.cacheKey(parsed.title)
        if let cached = titleCache[titleKey] {
            var metadata = cached
            metadata.matchedByHash = false
            if let fingerprint { hashCache[fingerprint] = metadata }
            save()
            return metadata
        }

        guard !parsed.title.isEmpty,
              let metadata = await CinemetaClient.shared.lookup(
                  title: parsed.title,
                  year: parsed.year,
                  season: parsed.season,
                  episode: parsed.episode
              ) else {
            return nil
        }

        titleCache[titleKey] = metadata
        if let fingerprint { hashCache[fingerprint] = metadata }
        save()
        return metadata
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return
        }
        hashCache = payload.hash
        titleCache = payload.title
    }

    private func save() {
        let payload = CachePayload(hash: hashCache, title: titleCache)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private struct CachePayload: Codable {
        let hash: [String: MediaMetadata]
        let title: [String: MediaMetadata]
    }
}

private enum MediaFingerprint {
    static func make(for url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let chunkSize = 64 * 1024
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }

            guard let size = try? handle.seekToEnd() else { return nil }
            if size < UInt64(chunkSize * 2) {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }

            guard let first = try? handle.read(upToCount: chunkSize),
                  (try? handle.seek(toOffset: size - UInt64(chunkSize))) != nil,
                  let last = try? handle.read(upToCount: chunkSize) else {
                return nil
            }

            var checksum = size
            addChecksum(first, to: &checksum)
            addChecksum(last, to: &checksum)
            return String(format: "%016llx", checksum)
        }.value
    }

    private static func addChecksum(_ data: Data, to checksum: inout UInt64) {
        var offset = 0
        while offset + 8 <= data.count {
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(data[offset + index]) << UInt64(index * 8)
            }
            checksum &+= value
            offset += 8
        }
    }
}

enum MediaNameParser {
    struct ParsedName {
        let title: String
        let year: String?
        let season: Int?
        let episode: Int?
    }

    static func parse(_ filename: String) -> ParsedName {
        var value = (filename as NSString).deletingPathExtension
        value = value.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "[()\\[\\]【】]", with: " ", options: .regularExpression)

        let seasonEpisode = capture(#"(?i)\bS(\d{1,2})E(\d{1,3})\b"#, in: value)
        let chineseEpisode = capture(#"第\s*(\d{1,4})\s*[集话話]"#, in: value)
        let season = seasonEpisode.first.flatMap(Int.init)
        let episode = seasonEpisode.dropFirst().first.flatMap(Int.init)
            ?? chineseEpisode.first.flatMap(Int.init)

        let year = capture(#"\b(19\d{2}|20\d{2})\b"#, in: value).first
        let releaseMarkers = [
            #"(?i)\bS\d{1,2}E\d{1,3}\b"#,
            #"(?i)\b(?:19|20)\d{2}\b"#,
            #"(?i)\b(?:2160p|1080p|720p|480p|4k|uhd)\b"#,
            #"(?i)\b(?:WEB[- ]?DL|WEBRip|BluRay|BDRip|HDTV|HDRip|DVDRip)\b"#,
            #"(?i)\b(?:H\.?264|H\.?265|HEVC|AVC|x264|x265)\b"#,
            #"(?i)\b(?:AAC|DDP?|AC3|DTS|TrueHD|Atmos)\b"#,
            #"(?i)\b(?:10bit|8bit|HDR10\+?|DoVi|Dolby Vision)\b"#,
            #"(?i)\b(?:REPACK|PROPER|REMUX|MULTi|CHS|CHT|简中|繁中|中字|国语|粤语)\b"#,
            #"(?i)\b(?:BlackTV|HDSWEB|Pure|CHD|WiKi|CMCT)\b"#,
            #"第\s*\d{1,4}\s*[集话話]"#,
        ]

        var cutoff = value.endIndex
        for marker in releaseMarkers {
            if let range = value.range(of: marker, options: .regularExpression),
               range.lowerBound < cutoff {
                cutoff = range.lowerBound
            }
        }
        value = String(value[..<cutoff])
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—")))

        return ParsedName(
            title: value.isEmpty ? (filename as NSString).deletingPathExtension : value,
            year: year,
            season: season,
            episode: episode
        )
    }

    static func cacheKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}]+"#, with: "", options: .regularExpression)
    }

    private static func capture(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }
}

private actor CinemetaClient {
    static let shared = CinemetaClient()

    func lookup(title: String, year: String?, season: Int?, episode: Int?) async -> MediaMetadata? {
        async let movies = search(title: title, type: "movie")
        async let series = search(title: title, type: "series")
        let (movieResults, seriesResults) = await (movies, series)
        let candidates = movieResults + seriesResults
        guard !candidates.isEmpty else { return nil }

        let ranked = candidates.enumerated().sorted { lhs, rhs in
            score(lhs.element, title: title, year: year, preferredSeries: season != nil)
                > score(rhs.element, title: title, year: year, preferredSeries: season != nil)
        }
        guard let selected = ranked.first?.element else { return nil }

        let detail = await detail(type: selected.type, id: selected.id)
        return MediaMetadata(
            imdbID: selected.id,
            type: selected.type,
            title: detail?.name.nonEmpty ?? selected.name,
            year: extractYear(detail?.releaseInfo ?? selected.releaseInfo),
            posterURL: detail?.poster.nonEmpty ?? selected.poster,
            backgroundURL: detail?.background.nonEmpty ?? selected.background,
            logoURL: detail?.logo ?? "",
            overview: detail?.description ?? "",
            rating: detail?.imdbRating ?? "",
            genres: detail?.genres ?? [],
            country: detail?.country ?? "",
            season: season,
            episode: episode
        )
    }

    private func search(title: String, type: String) async -> [CinemetaSearchItem] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~ "))
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://v3-cinemeta.strem.io/catalog/\(type)/top/search=\(encoded.replacingOccurrences(of: " ", with: "%20")).json") else {
            return []
        }
        guard let envelope: CinemetaSearchEnvelope = await request(url) else { return [] }
        return envelope.metas.filter { !$0.id.isEmpty && !$0.name.isEmpty }
    }

    private func detail(type: String, id: String) async -> CinemetaDetail? {
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(type)/\(id).json"),
              let envelope: CinemetaDetailEnvelope = await request(url) else {
            return nil
        }
        return envelope.meta
    }

    private func request<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func score(
        _ item: CinemetaSearchItem,
        title: String,
        year: String?,
        preferredSeries: Bool
    ) -> Int {
        let expected = MediaNameParser.cacheKey(title)
        let actual = MediaNameParser.cacheKey(item.name)
        var value = 0
        if expected == actual { value += 200 }
        else if actual.contains(expected) || expected.contains(actual) { value += 100 }
        if preferredSeries == (item.type == "series") { value += 40 }
        if let year, item.releaseInfo.contains(year) { value += 20 }
        return value
    }

    private func extractYear(_ value: String) -> String {
        value.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? ""
    }

    private struct CinemetaSearchEnvelope: Decodable {
        let metas: [CinemetaSearchItem]
    }

    private struct CinemetaSearchItem: Decodable {
        let id: String
        let type: String
        let name: String
        let poster: String
        let background: String
        let releaseInfo: String

        enum CodingKeys: String, CodingKey {
            case id, type, name, poster, background, releaseInfo
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            poster = try container.decodeIfPresent(String.self, forKey: .poster) ?? ""
            background = try container.decodeIfPresent(String.self, forKey: .background) ?? ""
            releaseInfo = try container.decodeIfPresent(String.self, forKey: .releaseInfo) ?? ""
        }
    }

    private struct CinemetaDetailEnvelope: Decodable {
        let meta: CinemetaDetail
    }

    private struct CinemetaDetail: Decodable {
        let name: String
        let poster: String
        let background: String
        let logo: String?
        let description: String?
        let genres: [String]?
        let releaseInfo: String?
        let imdbRating: String?
        let country: String?

        enum CodingKeys: String, CodingKey {
            case name, poster, background, logo, description, genres, releaseInfo, imdbRating, country
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            poster = try container.decodeIfPresent(String.self, forKey: .poster) ?? ""
            background = try container.decodeIfPresent(String.self, forKey: .background) ?? ""
            logo = try container.decodeIfPresent(String.self, forKey: .logo)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            genres = try container.decodeIfPresent([String].self, forKey: .genres)
            releaseInfo = try container.decodeIfPresent(String.self, forKey: .releaseInfo)
            imdbRating = try container.decodeIfPresent(String.self, forKey: .imdbRating)
            country = try container.decodeIfPresent(String.self, forKey: .country)
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
