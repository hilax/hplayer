import XCTest
import UIKit
@testable import HPlayer

@MainActor
final class HomeScreenIconTests: XCTestCase {
    func testEveryInstalledNameSelectsExactlyOneChoice() async {
        for icon in HomeScreenIcon.allCases {
            let matches = HomeScreenIcon.allCases.filter { $0.matchesCurrentName(icon.alternateName) }
            XCTAssertEqual(matches, [icon], "An installed name must identify exactly one choice")
        }
        XCTAssertNil(HomeScreenIcon.prism.alternateName, "Restoring the latest prism must request the primary icon")
        XCTAssertEqual(HomeScreenIcon.allCases.filter { $0.matchesCurrentName("AppIconPrism") }, [.prism],
                       "An existing white-prism selection must survive upgrading from the alternate-icon build")
        XCTAssertFalse(HomeScreenIcon.allCases.contains { $0.matchesCurrentName("UnknownFutureIcon") })
    }

    func testEveryChoiceHasItsPreviewAndSystemIconConfiguration() async throws {
        let bundle = Bundle.main
        // Bundle resolves device-qualified keys for the running device. Inspect the
        // shipped plist directly so an iPhone can also verify the iPad configuration.
        let infoURL = try XCTUnwrap(bundle.url(forResource: "Info", withExtension: "plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), options: [], format: nil
        ) as? [String: Any])
        for family in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let icons = try XCTUnwrap(info[family] as? [String: Any], family)
            let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
            XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
            let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
            for icon in HomeScreenIcon.allCases {
                if let name = icon.alternateName { XCTAssertNotNil(alternates[name], "Missing \(name) in \(family)") }
                XCTAssertNotNil(UIImage(named: icon.previewName, in: bundle, compatibleWith: nil), "Missing \(icon.previewName)")
            }
            XCTAssertNotNil(alternates["AppIconPrism"], "Keep the alternate used by earlier builds")
        }
    }
}
