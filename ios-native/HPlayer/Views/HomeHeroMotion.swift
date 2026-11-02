import SwiftUI

/// Separate from selection so a drag only redraws the backdrop, not every shelf.
final class HeroMotionState: ObservableObject {
    @Published private(set) var position: CGFloat?
    #if DEBUG
    private(set) var observedIntermediatePosition = false
    #endif

    func update(samples: [Int: CGFloat], originX: CGFloat, width: CGFloat, count: Int) {
        guard let value = HeroBlend.position(samples: samples, originX: originX, width: width, count: count),
              position.map({ abs($0 - value) > 0.001 }) ?? true else { return }
        #if DEBUG
        let fraction = value - floor(value)
        if fraction > 0.1 && fraction < 0.9 { observedIntermediatePosition = true }
        #endif
        position = value
    }

    func reset(to selection: Int) { position = CGFloat(max(0, selection)) }
}

/// Crossfade adjacent artwork with an opaque base, avoiding a dark dip halfway.
struct HeroBlend: Equatable {
    let lower: Int
    let upper: Int
    let fraction: Double

    init(position: CGFloat, count: Int) {
        let last = max(0, count - 1)
        let safe = position.isFinite ? min(max(position, 0), CGFloat(last)) : 0
        lower = Int(floor(safe))
        upper = min(lower + 1, last)
        let progress = Double(safe - CGFloat(lower))
        fraction = progress * progress * (3 - 2 * progress)
    }

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

/// Only the two adjacent low-resolution backdrops are rendered while dragging.
struct HomeHeroBackdrop: View {
    let items: [HomeMediaItem]
    let selection: Int
    @ObservedObject var motion: HeroMotionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let blend = HeroBlend(position: reduceMotion ? CGFloat(selection) : (motion.position ?? CGFloat(selection)), count: items.count)
        ZStack {
            Theme.pageBackground
            if !reduceTransparency {
                ForEach(Array(items.enumerated()).filter { $0.offset == blend.lower || $0.offset == blend.upper }, id: \.element.id) { index, item in
                    AmbientBackdrop(urlString: HomeArtwork.heroURL(item), fallbackURLString: item.posterURL)
                        .opacity(index == blend.lower ? 1 : blend.fraction)
                }
            }
        }
        // Progress already follows the native pager. An implicit spring here would
        // trail the finger and keep changing color after a cancelled swipe.
        .transaction { $0.animation = nil }
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
