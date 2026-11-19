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
            let primaryFiles = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String], "Missing primary CFBundleIconFiles in \(family)")
            XCTAssertTrue(primaryFiles.contains("AppIcon60x60"), "Primary icon must declare AppIcon60x60 in \(family)")

            let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
            for icon in HomeScreenIcon.allCases {
                if let name = icon.alternateName {
                    let entry = try XCTUnwrap(alternates[name] as? [String: Any], "Missing \(name) in \(family)")
                    XCTAssertEqual(entry["CFBundleIconName"] as? String, name, "Missing CFBundleIconName for \(name) in \(family)")
                    let files = try XCTUnwrap(entry["CFBundleIconFiles"] as? [String], "Missing CFBundleIconFiles for \(name) in \(family)")
                    XCTAssertTrue(files.contains("\(name)60x60"), "Missing \(name)60x60 file entry in \(family)")
                }
                XCTAssertNotNil(UIImage(named: icon.previewName, in: bundle, compatibleWith: nil), "Missing \(icon.previewName)")
            }
            let legacyPrism = try XCTUnwrap(alternates["AppIconPrism"] as? [String: Any], "Keep the alternate used by earlier builds")
            XCTAssertEqual(legacyPrism["CFBundleIconName"] as? String, "AppIconPrism")
        }

        // 确认主图标与所有备选图标在 .app 根目录均存在实体 @2x / @3x PNG，防止 iOS 18/26 切换图标后回退为空白网格。
        let requiredNames = ["AppIcon", "AppIconPrism"] + HomeScreenIcon.allCases.compactMap(\.alternateName)
        for name in requiredNames {
            for suffix in ["60x60@2x", "60x60@3x", "76x76@2x~ipad", "83.5x83.5@2x~ipad"] {
                let url = bundle.bundleURL.appendingPathComponent("\(name)\(suffix).png")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "Missing bundled root PNG \(name)\(suffix).png")
                let data = try Data(contentsOf: url)
                XCTAssertNotNil(UIImage(data: data), "Corrupted root icon PNG \(name)\(suffix).png")
            }
        }
    }
}
