import CoreGraphics

/// 播放画面怎么摆：画面图层缩放多少、竖屏小窗多高。只做计算，不碰界面，可以单独测试。
///
/// 画面图层（mpv 画图的那一块）的大小固定是横放时的整块屏幕，mpv 把视频按比例画在它中间，
/// 比例和屏幕不一样的片子四周是它自己画的黑边。竖屏时把这块图层缩小放进小窗，
/// 缩放的依据是「视频本身那一块」，不是整块图层：
/// 以前按整块图层缩，16:9 的片子在竖屏里只有小窗的 82% 宽，左右是黑边，
/// 上下还露出垫在下面的小窗（画中画）图层里的那一帧画面。
enum PlayerVideoGeometry {
    /// 竖屏小窗最扁是 16:9：更宽的片子（2.35:1）在里面上下留黑，免得小窗矮到放不下控制按钮
    static let widestInlineAspect: CGFloat = 16.0 / 9.0
    /// 竖屏小窗最高是正方形：4:3、方形、竖拍的片子小窗更高。
    /// 画面图层只有屏幕短边那么高，小窗不超过正方形，画面就不用放大、不会发虚
    static let tallestInlineAspect: CGFloat = 1
    /// 小窗最多占屏幕高度的一半（平板竖屏时正方形太大），下面留给片名和选集
    static let inlineHeightLimit: CGFloat = 0.5
    /// 还没出画面、不知道视频比例时按 16:9 摆，绝大多数片子出画面后不用再动
    static let assumedAspect: CGFloat = 16.0 / 9.0
    /// 小窗和画面的比例差不到 1% 时直接铺满，免得边上留一条不到一个像素的黑线
    private static let coverTolerance: CGFloat = 1.01

    struct Placement: Equatable {
        /// 画面图层的缩放。只有「拉伸」模式横竖不一样
        var scaleX: CGFloat
        var scaleY: CGFloat
        /// 视频那一块在图层里的大小（缩放前）。小窗引导帧就垫在它正下方、和它一样大
        var pictureSize: CGSize

        /// 视频那一块在屏幕上的大小
        var shownSize: CGSize {
            CGSize(width: pictureSize.width * scaleX, height: pictureSize.height * scaleY)
        }
    }

    private static func usable(_ aspect: CGFloat?) -> CGFloat {
        guard let aspect, aspect.isFinite, aspect > 0 else { return assumedAspect }
        return aspect
    }

    /// 视频按比例放进图层后的大小（mpv 的「适应」就是这么画的）
    static func pictureSize(aspect: CGFloat?, in canvas: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return canvas }
        let aspect = usable(aspect)
        if aspect >= canvas.width / canvas.height {
            return CGSize(width: canvas.width, height: canvas.width / aspect)
        }
        return CGSize(width: canvas.height * aspect, height: canvas.height)
    }

    /// 图层放进容器（横屏是整块屏幕，竖屏是顶部小窗）时的缩放。
    /// - 横屏：容器和图层一样大，缩放恰好是 1，和以前一样。
    /// - 竖屏：视频那一块正好放进小窗，图层自带的黑边伸到小窗外面被裁掉。
    /// - 铺满裁切、画面缩放由 mpv 在图层里做，这里仍按「适应」时的那一块来缩，竖屏看到的裁切程度和横屏一致。
    /// - 拉伸：整块图层正好盖住容器。
    static func placement(canvas: CGSize, container: CGSize, aspect: CGFloat?, stretch: Bool) -> Placement {
        guard canvas.width > 0, canvas.height > 0, container.width > 0, container.height > 0 else {
            return Placement(scaleX: 1, scaleY: 1, pictureSize: canvas)
        }
        if stretch {
            return Placement(scaleX: container.width / canvas.width, scaleY: container.height / canvas.height,
                             pictureSize: canvas)
        }
        let picture = pictureSize(aspect: aspect, in: canvas)
        let horizontal = container.width / picture.width
        let vertical = container.height / picture.height
        let fit = min(horizontal, vertical)
        let cover = max(horizontal, vertical)
        // 铺满只用来消掉缩小以后的那条细线，不会把图层放大到超过原大（横屏时恰好还是 1）
        let scale = cover <= fit * coverTolerance ? min(cover, max(fit, 1)) : fit
        return Placement(scaleX: scale, scaleY: scale, pictureSize: picture)
    }

    /// 竖屏时顶部小窗的高度：跟着视频的比例走，16:9 的片子就是 16:9。
    static func inlineHeight(width: CGFloat, screenHeight: CGFloat, aspect: CGFloat?) -> CGFloat {
        guard width > 0 else { return 0 }
        let clamped = min(max(usable(aspect), tallestInlineAspect), widestInlineAspect)
        let natural = width / clamped
        guard screenHeight > 0 else { return natural }
        // 再怎么限制也不低于 16:9
        return max(min(natural, screenHeight * inlineHeightLimit), width / widestInlineAspect)
    }

    /// 转屏时系统给出的是整个窗口转完以后的大小；画面所在的容器转完是多大：
    /// 横着就是整个窗口，竖着是顶部的小窗。
    static func container(afterTransitionTo size: CGSize, aspect: CGFloat?) -> CGSize {
        guard size.height > size.width else { return size }
        return CGSize(width: size.width, height: inlineHeight(width: size.width, screenHeight: size.height, aspect: aspect))
    }
}
