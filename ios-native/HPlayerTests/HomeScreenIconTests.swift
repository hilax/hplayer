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
                if let name = icon.alternateName {
                    let entry = try XCTUnwrap(alternates[name] as? [String: Any], "Missing \(name) in \(family)")
                    XCTAssertNil(entry["CFBundleIconName"], "Alternate icon \(name) should use CFBundleIconFiles instead of Assets.car CFBundleIconName")
                    let files = try XCTUnwrap(entry["CFBundleIconFiles"] as? [String], "Missing CFBundleIconFiles for \(name) in \(family)")
                    XCTAssertTrue(files.contains(name), "Missing \(name) file entry in \(family)")
                }
                XCTAssertNotNil(UIImage(named: icon.previewName, in: bundle, compatibleWith: nil), "Missing \(icon.previewName)")
            }
            let legacyPrism = try XCTUnwrap(alternates["AppIconPrism"] as? [String: Any], "Keep the alternate used by earlier builds")
            XCTAssertNil(legacyPrism["CFBundleIconName"])
            let legacyFiles = try XCTUnwrap(legacyPrism["CFBundleIconFiles"] as? [String])
            XCTAssertTrue(legacyFiles.contains("AppIconPrism"))

            // 珊瑚橙换了注册名；旧名 AppIconCoral 保留为别名并指向新名的实体 PNG。
            XCTAssertEqual(HomeScreenIcon.coral.alternateName, "HPIconCoral")
            let legacyCoral = try XCTUnwrap(alternates["AppIconCoral"] as? [String: Any], "Keep the coral name used by earlier builds")
            XCTAssertNil(legacyCoral["CFBundleIconName"])
            let legacyCoralFiles = try XCTUnwrap(legacyCoral["CFBundleIconFiles"] as? [String])
            XCTAssertTrue(legacyCoralFiles.contains("HPIconCoral"))
        }

        // 确认所有备选图标在 .app 根目录均存在轻量实体 @2x / @3x 与 iPad PNG，避免回退为空白网格。
        let requiredAlternates = ["AppIconPrism"] + HomeScreenIcon.allCases.compactMap(\.alternateName)
        let expectedSuffixes: [(String, Int)] = [
            ("@2x.png", 120),
            ("@3x.png", 180),
            ("@2x~ipad.png", 152),
            ("-83.5@2x~ipad.png", 167),
        ]
        for name in requiredAlternates {
            for (suffix, pixels) in expectedSuffixes {
                let url = bundle.bundleURL.appendingPathComponent("\(name)\(suffix)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "Missing bundled root PNG \(name)\(suffix)")
                let data = try Data(contentsOf: url)
                let image = try XCTUnwrap(UIImage(data: data), "Corrupted root icon PNG \(name)\(suffix)")
                let cg = try XCTUnwrap(image.cgImage)
                XCTAssertEqual(cg.width, pixels, "\(name)\(suffix) width")
                XCTAssertEqual(cg.height, pixels, "\(name)\(suffix) height")
            }
        }
    }
}
