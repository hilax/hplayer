import XCTest
import UIKit

extension XCUIApplication {
    /// 系统标签栏上的按钮，按标签名字找：首页 / 磁力 / 网盘 / 我的。
    func tabButton(_ title: String) -> XCUIElement {
        tabBars.buttons[title]
    }
}

extension XCUIElement {
    /// 按钮中间画出图标的程度：截取按钮，看中间 60% 区域里和中位亮度相差很大的像素占比。
    /// 只有玻璃底、图标没画出来时接近 0；有图标时一般在 0.05 以上。
    func iconInkRatio() -> Double {
        guard let cg = screenshot().image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var luminance: [Double] = []
        for y in Int(Double(height) * 0.2)..<Int(Double(height) * 0.8) {
            for x in Int(Double(width) * 0.2)..<Int(Double(width) * 0.8) {
                let i = (y * width + x) * 4
                luminance.append((0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255)
            }
        }
        guard !luminance.isEmpty else { return 0 }
        let median = luminance.sorted()[luminance.count / 2]
        return Double(luminance.filter { abs($0 - median) > 0.3 }.count) / Double(luminance.count)
    }
}
