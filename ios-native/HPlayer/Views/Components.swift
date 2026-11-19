import SwiftUI

/// 品牌标志的矢量版：近黑底上两道棱镜色竖笔组成 H，中间是播放键。
struct BrandLogo: View {
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Theme.brandNight)

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
                            colors: Array(Theme.prismColors.prefix(3)),
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: barWidth, height: barHeight)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(
                            colors: Array(Theme.prismColors.suffix(3)),
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: barWidth, height: barHeight)
                }

                PlayTriangle()
                    .fill(Theme.brandNight)
                    .overlay {
                        PlayTriangle()
                            .stroke(Color.white, style: StrokeStyle(lineWidth: side * 0.05, lineJoin: .round))
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

/// 空状态、结果页正中间的图标（方向 B · 细线圆环）：外圈一条细线，里面一个卡片色的圆，
/// 图标用主文字色。全应用的居中大图标都用它，不再用琥珀色或灰底圆角块。
struct EmptyStateMark: View {
    let icon: String
    /// 外圈直径；里面的圆是它的 0.7，图标跟着等比缩放
    var size: CGFloat = 132

    init(icon: String, size: CGFloat = 132) {
        self.icon = icon
        self.size = size
    }

    init(_ icon: AppIcon, size: CGFloat = 132) {
        self.init(icon: icon.name, size: size)
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.hairline, lineWidth: 1)
                .frame(width: size, height: size)
            Circle()
                .fill(Theme.surface)
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                .frame(width: size * 0.7, height: size * 0.7)
                .shadow(color: Theme.floatShadow.opacity(0.45), radius: 9, y: 6)
            // 圆的大小固定，图标也用固定字号，「更大字体」下不会撑出圆外
            Image(appIconNamed: icon)
                .font(.system(size: size * 0.18, weight: Theme.iconWeight))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            EmptyStateMark(icon: icon)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 300)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryActionStyle())
                    .frame(maxWidth: 220)
                    .padding(.top, 6)
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
