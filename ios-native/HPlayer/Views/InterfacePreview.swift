import Foundation

/// A launch-only switch for simulator screenshots. Fixture data is compiled only in Debug.
enum InterfacePreview {
    static var screen: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HPLAYER_DESIGN_SCREEN"]
        #else
        return nil
        #endif
    }
    static var active: Bool { screen != nil }
}
