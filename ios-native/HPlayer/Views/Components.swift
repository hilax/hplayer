import SwiftUI

/// App 图标的矢量版：深蓝底上两道渐变竖笔组成 H，中间是播放键。
struct BrandLogo: View {
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Theme.brandNavy)

            BrandMark()
                .frame(width: size * 0.74, height: size * 0.74)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 不带底色的 H 标志，可以直接放在任意背景上。
struct BrandMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let barWidth = side * 0.31
            let barHeight = side
            let radius = side * 0.1

            ZStack {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.brandCyan, Theme.brandBlue],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: barWidth, height: barHeight)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(uiColor: UIColor(hex: 0x9C82FF)), Color(uiColor: UIColor(hex: 0x5A34E6))],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: barWidth, height: barHeight)
                }

                PlayTriangle()
                    .fill(Theme.brandBlue)
                    .overlay {
                        PlayTriangle()
                            .stroke(Theme.brandNavy, style: StrokeStyle(lineWidth: side * 0.05, lineJoin: .round))
                    }
                    .frame(width: side * 0.52, height: side * 0.46)
                    .offset(x: side * 0.05, y: -side * 0.08)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 68, height: 68)
                .background(Theme.tileTint, in: Circle())
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 黄色文件夹图标：橙色背板（带标签）加黄色前板，用在资源库列表里。
/// 只用圆角矩形拼成，任意尺寸都清晰，浅色和深色模式下颜色不变。
struct FolderGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let corner = min(width, height) * 0.16

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.folderBack)
                    .frame(width: width * 0.46, height: height * 0.42)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.folderBack)
                    .frame(width: width, height: height * 0.84)
                    .offset(y: height * 0.16)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.folderFront)
                    .frame(width: width, height: height * 0.72)
                    .offset(y: height * 0.28)
            }
        }
        .accessibilityHidden(true)
    }
}
