import SwiftUI

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
