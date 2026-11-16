import XCTest
import UIKit
@testable import HPlayer

/// 图标是生成出来的自定义符号：确认每一个都进了包、按符号编译、并且真的画出了东西。
/// 模板写错时 Xcode 不一定报错，只会得到空白图标，所以这里逐个渲染检查。
final class AppIconAssetTests: XCTestCase {
    private var allNames: [String] {
        Set(AppIcon.allCases.flatMap { [$0.name, $0.activeName] }).sorted()
    }

    func testEveryIconIsABundledSymbolThatDrawsSomething() throws {
        let config = UIImage.SymbolConfiguration(pointSize: 24)
        for name in allNames {
            let image = try XCTUnwrap(UIImage(named: name, in: .main, with: config), "Missing symbol \(name)")
            XCTAssertTrue(image.isSymbolImage, "\(name) should compile as a symbol image")
            XCTAssertGreaterThan(image.size.width, 6, "\(name) is too narrow")
            XCTAssertGreaterThan(image.size.height, 12, "\(name) is too short")
            let coverage = inkCoverage(of: image)
            XCTAssertGreaterThan(coverage, 0.01, "\(name) draws nothing")
            XCTAssertLessThan(coverage, 0.9, "\(name) draws a solid block")
        }
    }

    func testIconsScaleWithTheRequestedPointSize() throws {
        let small = try XCTUnwrap(UIImage(named: AppIcon.unselected.name, in: .main,
                                          with: UIImage.SymbolConfiguration(pointSize: 12)))
        let large = try XCTUnwrap(UIImage(named: AppIcon.unselected.name, in: .main,
                                          with: UIImage.SymbolConfiguration(pointSize: 36)))
        XCTAssertEqual(large.size.width / small.size.width, 3, accuracy: 0.35)
    }

    func testFilledVariantsDifferFromOutlines() throws {
        for icon in [AppIcon.home, .library, .magnet, .cloud, .mine] {
            XCTAssertNotEqual(icon.name, icon.activeName)
            let outline = try XCTUnwrap(UIImage(named: icon.name, in: .main, with: nil))
            let filled = try XCTUnwrap(UIImage(named: icon.activeName, in: .main, with: nil))
            XCTAssertGreaterThan(inkCoverage(of: filled), inkCoverage(of: outline), "\(icon) selected should be solid")
        }
    }

    func testEveryIconHasASpokenName() {
        for icon in AppIcon.allCases {
            XCTAssertFalse(icon.spokenName.isEmpty, "\(icon)")
            XCTAssertEqual(AppIcon.byAssetName[icon.name], icon)
        }
    }

    /// 在 48×48 的透明画布上按比例画出图标，返回不透明像素的占比。
    private func inkCoverage(of image: UIImage) -> Double {
        let side = 48
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let tinted = image.withTintColor(.black, renderingMode: .alwaysOriginal)
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let size = image.size
            let factor = min(CGFloat(side) / size.width, CGFloat(side) / size.height)
            let drawn = CGSize(width: size.width * factor, height: size.height * factor)
            tinted.draw(in: CGRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2,
                                   width: drawn.width, height: drawn.height))
        }
        guard let cg = rendered.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var ink = 0
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > 127 { ink += 1 }
        return Double(ink) / Double(side * side)
    }
}
