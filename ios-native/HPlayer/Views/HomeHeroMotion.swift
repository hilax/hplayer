import SwiftUI
import UIKit

// MARK: - 跟手位置

/// 精选轮播跟手的状态，和选中页分开存。拖动时每一帧都在变的位置不发布，
/// 只有「翻过一半、换了一页」才通知界面，货架和整页不会被逐帧重算。
final class HeroMotionState: ObservableObject {
    /// 现在停在第几页，带小数：0.3 表示从第 0 页往第 1 页拖了三成。没收到页面位置时为 nil。
    private(set) var position: CGFloat?
    /// 过半就算翻到了那一页：整页底色和横幅下沿的颜色跟着它变。
    /// 和参考视频一样，拖不到一半松手就不换色，拖过一半还没松手就已经开始换。
    @Published private(set) var settledIndex = 0
    #if DEBUG
    private(set) var observedIntermediatePosition = false
    #endif

    func update(samples: [Int: CGFloat], originX: CGFloat, width: CGFloat, count: Int) {
        guard let value = HeroPagePosition.position(samples: samples, originX: originX, width: width, count: count),
              position.map({ abs($0 - value) > 0.001 }) ?? true else { return }
        #if DEBUG
        let fraction = value - floor(value)
        if fraction > 0.1 && fraction < 0.9 { observedIntermediatePosition = true }
        #endif
        position = value
        settle(at: Int(value.rounded()))
    }

    /// 还没收到任何页面位置时（刚换了一批精选），先跟着 TabView 的选中项走。
    /// 收到之后以页面位置为准，迟到的选中项不能把颜色拉回去。
    func follow(selection: Int) {
        guard position == nil else { return }
        settle(at: selection)
    }

    /// 精选换了一批：清掉旧的位置，等新页面报上来；在那之前停在选中项上。
    func reset(to selection: Int) {
        position = nil
        settle(at: selection)
    }

    private func settle(at index: Int) {
        let index = max(0, index)
        if settledIndex != index { settledIndex = index }
    }
}

/// 由各页在屏幕上的位置推算轮播停在第几页。
enum HeroPagePosition {
    static func position(samples: [Int: CGFloat], originX: CGFloat, width: CGFloat, count: Int) -> CGFloat? {
        guard width.isFinite, width > 0, originX.isFinite, count > 0 else { return nil }
        // Both visible pages describe the same position. Prefer the centered one;
        // offscreen pages can retain an old frame while TabView recycles them.
        let visible = samples.filter {
            (0..<count).contains($0.key) && $0.value.isFinite && abs($0.value - originX) <= width
        }
        guard let nearest = visible.min(by: {
            let lhs = abs($0.value - originX), rhs = abs($1.value - originX)
            return lhs == rhs ? $0.key < $1.key : lhs < rhs
        }) else { return nil }
        return min(max(CGFloat(nearest.key) - (nearest.value - originX) / width, 0), CGFloat(count - 1))
    }
}

struct HeroPagePositionKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - 封面取色

/// 一张精选封面的颜色：取画面露在横幅里那一块的平均色，再压到适合铺满整页、上面压白字的明度。
struct ArtworkTint: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    /// 横幅大约是 4:5 的竖图，封面按「填满」裁切，只有中间这一块露在外面。
    static let heroAspect: CGFloat = 0.8
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

/// 整页底色和横幅下沿用的颜色。
enum HeroTint: Equatable {
    /// 没有精选：普通的页面底色
    case plain
    /// 有精选、颜色还没算好：先用深色底，算好后再过渡过去
    case pending
    case artwork(ArtworkTint)

    var color: Color {
        switch self {
        case .plain: return Theme.pageBackground
        case .pending: return Theme.brandNight
        case .artwork(let tint): return tint.color
        }
    }
}

/// 精选每一页的取色。用的是首页本来就会预取的背景小图（160px），每张算一次就记住。
final class HeroPalette: ObservableObject {
    @Published private(set) var tints: [String: ArtworkTint] = [:]
    private var loading: Set<String> = []
    private var failedAt: [String: Date] = [:]

    /// 第 index 页现在该用的颜色。
    func tint(items: [HomeMediaItem], index: Int) -> HeroTint {
        guard !items.isEmpty else { return .plain }
        let item = items[min(max(index, 0), items.count - 1)]
        return tints[HomeArtwork.heroURL(item)].map(HeroTint.artwork) ?? .pending
    }

    /// 首页换了一批精选时调用（主线程）。已经算过的、正在算的不重复算；失败的过一分钟再试。
    func prepare(_ items: [HomeMediaItem]) {
        for item in items {
            let key = HomeArtwork.heroURL(item)
            guard !key.isEmpty, tints[key] == nil, !loading.contains(key) else { continue }
            if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { continue }
            loading.insert(key)
            let fallback = item.posterURL
            Task { @MainActor [weak self] in
                let tint = await HeroPalette.load(key, fallback: fallback)
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

    /// 横幅显示的是哪张图就取哪张：背景图加载失败时横幅退回海报，取色也一样。
    private static func load(_ urlString: String, fallback: String) async -> ArtworkTint? {
        for candidate in [urlString, fallback] where !candidate.isEmpty {
            guard let url = URL(string: candidate),
                  let image = await ImagePipeline.shared.image(url, maxPixel: ArtworkSize.backdrop, priority: .utility),
                  let cgImage = image.cgImage,
                  let average = ArtworkTint.averageColor(of: cgImage) else { continue }
            return ArtworkTint.page(red: average.red, green: average.green, blue: average.blue)
        }
        return nil
    }
}

// MARK: - 首页底色

/// 首页整页的底色：当前精选封面的取色，铺满全屏。
/// 翻过一半就用 0.3 秒过渡到新封面的颜色；横幅下沿那层颜色用同一个值、同一个节奏变化，两者始终连成一片。
struct HomeHeroBackdrop: View {
    let items: [HomeMediaItem]
    @ObservedObject var motion: HeroMotionState
    @ObservedObject var palette: HeroPalette

    var body: some View {
        let tint = palette.tint(items: items, index: motion.settledIndex)
        Rectangle()
            .fill(tint.color)
            .animation(Motion.artworkFade, value: tint)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.environment["HPLAYER_HOME_MOTION_TEST"] == "1" {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("轮播动效测试")
                        .accessibilityValue(motion.observedIntermediatePosition ? "interactive" : "settled")
                        .accessibilityIdentifier("home.motionProbe")
                }
            }
            #endif
    }
}

/// 盖在横幅每一页下半截的封面色：上面透明，越往下越接近整页底色，到横幅底边完全变成底色，
/// 画面就像融进了下面的页面里。文字一带再压一点暗，亮画面上的白字也看得清，到底边又退回纯底色。
/// 每一页都用「当前这一页」的颜色（和整页底色同一个值），拖动时新进来的那一页先沿用当前颜色，过半再一起变。
struct HeroTintOverlay: View {
    let items: [HomeMediaItem]
    @ObservedObject var motion: HeroMotionState
    @ObservedObject var palette: HeroPalette

    /// 横轴是横幅高度的比例。文字在 0.57～0.70，按钮在 0.71～0.79，0.81 以下是融进页面的过渡区。
    private static let tintStops: [Gradient.Stop] = [
        .init(color: .clear, location: 0.36),
        .init(color: .black.opacity(0.25), location: 0.52),
        .init(color: .black.opacity(0.5), location: 0.64),
        .init(color: .black.opacity(0.74), location: 0.75),
        .init(color: .black.opacity(0.92), location: 0.86),
        .init(color: .black, location: 0.95),
    ]
    private static let scrimStops: [Gradient.Stop] = [
        .init(color: .clear, location: 0.3),
        .init(color: .black.opacity(0.23), location: 0.5),
        .init(color: .black.opacity(0.38), location: 0.62),
        .init(color: .black.opacity(0.35), location: 0.72),
        .init(color: .black.opacity(0.17), location: 0.82),
        .init(color: .clear, location: 0.92),
    ]

    var body: some View {
        let tint = palette.tint(items: items, index: motion.settledIndex)
        ZStack {
            Rectangle()
                .fill(tint.color)
                .mask { LinearGradient(stops: Self.tintStops, startPoint: .top, endPoint: .bottom) }
            LinearGradient(stops: Self.scrimStops, startPoint: .top, endPoint: .bottom)
        }
        .animation(Motion.artworkFade, value: tint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
