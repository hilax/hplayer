import SwiftUI
import UIKit

// MARK: - 封面取色

/// 一张精选封面的颜色：取画面露在横幅里那一块的平均色，再压到适合铺满整页、上面压白字的明度。
struct ArtworkTint: Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    /// 浅色模式用的淡色：同一个色相提亮到最亮，再和浅色页面底色（#F4F5F8）按 45% 混合，深色文字压在上面也清楚。
    var pastel: ArtworkTint {
        let high = max(red, green, blue)
        guard high > 0 else { return ArtworkTint(red: 0.957, green: 0.961, blue: 0.973) }
        func mix(_ value: Double, _ page: Double) -> Double { page + (value / high - page) * 0.45 }
        return ArtworkTint(red: mix(red, 0.957), green: mix(green, 0.961), blue: mix(blue, 0.973))
    }

    /// 轮播卡片是 16:9 的横图，封面按「填满」裁切，只有中间这一块露在外面。
    static let heroAspect: CGFloat = 16.0 / 9.0
    /// 明度上限：再亮，上面的白字就看不清了。参考视频里压白字的底色基本都在这个亮度附近。
    static let maxBrightness = 0.40
    /// 饱和度上限：保留封面的色相，又不至于刺眼。
    static let maxSaturation = 0.65

    /// 平均色 → 整页底色：色相不变，饱和度和明度各自封顶；本来就够暗、够淡的颜色原样保留。
    static func page(red: Double, green: Double, blue: Double) -> ArtworkTint {
        let r = min(max(red, 0), 1), g = min(max(green, 0), 1), b = min(max(blue, 0), 1)
        let high = max(r, g, b), low = min(r, g, b)
        guard high > 0 else { return ArtworkTint(red: 0, green: 0, blue: 0) }
        let brightness = min(high, maxBrightness)
        let saturation = min((high - low) / high, maxSaturation)
        // 每个通道在最暗和最亮通道之间的相对位置决定色相，换算前后保持不变。
        func channel(_ value: Double) -> Double {
            let position = high > low ? (value - low) / (high - low) : 1
            return brightness * (1 - saturation * (1 - position))
        }
        return ArtworkTint(red: channel(r), green: channel(g), blue: channel(b))
    }

    /// 图片按 aspect 居中裁切后露出部分的平均色（0...1）。先缩到 12×12 再平均，几乎不花时间。
    static func averageColor(of image: CGImage, aspect: CGFloat = ArtworkTint.heroAspect) -> (red: Double, green: Double, blue: Double)? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width >= 1, height >= 1, aspect > 0 else { return nil }
        var crop = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > aspect {
            crop.size.width = max(1, (height * aspect).rounded())
            crop.origin.x = ((width - crop.width) / 2).rounded(.down)
        } else {
            crop.size.height = max(1, (width / aspect).rounded())
            crop.origin.y = ((height - crop.height) / 2).rounded(.down)
        }
        guard let visible = image.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(visible, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[offset])
            green += Double(pixels[offset + 1])
            blue += Double(pixels[offset + 2])
            alpha += Double(pixels[offset + 3])
        }
        guard alpha > 0 else { return nil }
        // 像素是预乘过透明度的：颜色之和除以透明度之和，就是按不透明程度加权的平均色。
        return (red / alpha, green / alpha, blue / alpha)
    }
}

/// 页面顶部氛围色的状态。
enum HeroTint: Hashable {
    /// 没有轮播：不铺颜色
    case plain
    /// 有轮播、颜色还没算好：先铺一层中性灰，算好后再过渡过去
    case pending
    case artwork(ArtworkTint)
}

/// 轮播每一张的取色。用的是首页本来就会预取的背景小图（160px），每张算一次就记住。
/// key 是这一张显示的图片地址；图片加载失败时用 fallback（例如背景图失败退回海报）。
final class HeroPalette: ObservableObject {
    /// 推荐、动漫、片库三个频道共用：切频道时页面重建，算过的颜色还在，不会先闪一下灰色
    static let shared = HeroPalette()

    struct Source: Hashable {
        let key: String
        var fallback = ""
        /// 这张图在卡片里露出部分的宽高比
        var aspect: CGFloat = ArtworkTint.heroAspect
    }

    @Published private(set) var tints: [String: ArtworkTint] = [:]
    private var loading: Set<String> = []
    private var failedAt: [String: Date] = [:]

    /// 这一张现在该用的颜色。没有轮播时是普通页面底色；颜色还没算好时是「待定」。
    func tint(forKey key: String?) -> HeroTint {
        guard let key, !key.isEmpty else { return .plain }
        return tints[key].map(HeroTint.artwork) ?? .pending
    }

    /// 轮播换了一批时调用（主线程）。已经算过的、正在算的不重复算；失败的过一分钟再试。
    func prepare(_ sources: [Source]) {
        for source in sources {
            let key = source.key
            guard !key.isEmpty, tints[key] == nil, !loading.contains(key) else { continue }
            if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { continue }
            loading.insert(key)
            Task { @MainActor [weak self] in
                let tint = await HeroPalette.load(source)
                guard let self else { return }
                self.loading.remove(key)
                if let tint {
                    self.tints[key] = tint
                    self.failedAt[key] = nil
                } else {
                    self.failedAt[key] = Date()
                }
            }
        }
    }

    private static func load(_ source: Source) async -> ArtworkTint? {
        for candidate in [source.key, source.fallback] where !candidate.isEmpty {
            guard let url = URL(string: candidate),
                  let image = await ImagePipeline.shared.image(url, maxPixel: ArtworkSize.backdrop, priority: .utility),
                  let cgImage = image.cgImage,
                  let average = ArtworkTint.averageColor(of: cgImage, aspect: source.aspect) else { continue }
            return ArtworkTint.page(red: average.red, green: average.green, blue: average.blue)
        }
        return nil
    }
}

/// 轮播当前是哪一张（取色用的 key）。单独放一个对象：翻页时只有页面顶部的氛围色重画，整个首页不重算。
final class CarouselTintState: ObservableObject {
    @Published var key: String?
}

// MARK: - 首页顶部氛围色

/// 首页顶部的一层氛围色：当前这张轮播图的取色，从屏幕顶端往下渐渐淡进页面底色。
/// 翻页时颜色用 0.6 秒交叉淡入；深色模式用压暗的封面色，浅色模式用同色相的淡色。
struct HomeAmbientBackdrop: View {
    @ObservedObject var state: CarouselTintState
    @ObservedObject var palette: HeroPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = palette.tint(forKey: state.key)
        // 换色时新旧两层交叉淡入（渐变本身在旧系统上不会插值）
        ZStack {
            LinearGradient(stops: stops(for: tint), startPoint: .top, endPoint: .bottom)
                .id(tint)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.6), value: tint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stops(for tint: HeroTint) -> [Gradient.Stop] {
        let color: Color
        switch tint {
        case .plain:
            return [.init(color: .clear, location: 0), .init(color: .clear, location: 1)]
        case .pending:
            color = colorScheme == .dark ? Theme.surfaceRaised : Theme.surfaceHigh
        case .artwork(let value):
            color = colorScheme == .dark ? value.color : value.pastel.color
        }
        let middle = colorScheme == .dark ? 0.45 : 0.55
        return [
            .init(color: color, location: 0),
            .init(color: color.opacity(middle), location: 0.55),
            .init(color: color.opacity(0), location: 1),
        ]
    }
}
