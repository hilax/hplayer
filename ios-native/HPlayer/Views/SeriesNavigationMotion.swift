import SwiftUI

/// On supported systems the poster anchors the system's interactive zoom.
/// A unique shelf/grid scope keeps two copies of the same title unambiguous.
struct SeriesTransitionSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let reduceMotion: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

struct SeriesTransitionDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let reduceMotion: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

#if DEBUG
private struct TestReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var testReducedMotion: Bool {
        get { self[TestReducedMotionKey.self] }
        set { self[TestReducedMotionKey.self] = newValue }
    }
}
#endif
