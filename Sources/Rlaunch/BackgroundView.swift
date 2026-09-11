import Cocoa
import RlaunchCore

/// 窗口背景：无图片时用系统毛玻璃（NSVisualEffectView，GPU 合成，低占用）；
/// 有图片时显示图片 + 可选高斯模糊（后台线程预渲染，仅设置变化时重算一次）。
final class BackgroundView: NSView {
    private let renderQueue = DispatchQueue(label: "rlaunch.background", qos: .userInitiated)
    private static let ciContext = CIContext()
    private var generation = 0 // 防止旧渲染结果覆盖新设置
    /// 首次（启动阶段）同步完成模糊预渲染，避免窗口出现后从清晰图突变为模糊图的画面跳变
    private var hasRenderedInitialBackground = false
    /// 与窗口圆角保持一致
    private var cornerRadius: CGFloat = 18

    /// 毛玻璃 / 兜底底色
    private weak var effectView: NSVisualEffectView?
    private weak var baseView: GlassBaseView?

    /// 切换窗口模式（窗口化 18 / 全屏 0）时同步圆角
    func setCornerRadius(_ radius: CGFloat) {
        guard abs(cornerRadius - radius) > 0.01 else { return }
        cornerRadius = radius
        applyCornerRadius()
    }

    // MARK: - 上屏首帧保护
    //
    // NSVisualEffectView 的 .behindWindow 背景由 WindowServer 采样窗口后面的桌面生成，
    // 窗口刚 orderFront 的那一帧桌面背景往往还没准备好，整块毛玻璃会渲染成黑色；
    // 由于图标与顶栏盖在中间，肉眼看到的就是「界面四周一圈黑线一闪而过」。
    // 处理方式：上屏前先铺一层与主题一致的兜底底色，等窗口完成首次合成后再揭开毛玻璃。

    /// 上屏前调用：显示兜底底色、隐藏毛玻璃
    func prepareForDisplay() {
        guard let effectView else { return }
        baseView?.isHidden = false
        effectView.isHidden = true
    }

    /// 上屏后调用：等窗口完成首次合成再揭开毛玻璃
    func revealGlassAfterFirstFrame() {
        guard let effectView else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.effectView === effectView else { return }
            effectView.isHidden = false
            self.baseView?.isHidden = true
        }
    }

    // MARK: - 配置

    func setConfig(_ config: AppConfig) {
        generation += 1
        let gen = generation
        subviews.forEach { $0.removeFromSuperview() }
        effectView = nil
        baseView = nil

        if let path = config.backgroundImagePath,
           let image = NSImage(contentsOfFile: path) {
            let holder = NSView()
            holder.wantsLayer = true
            holder.layer?.contents = image
            holder.layer?.contentsGravity = .resizeAspectFill
            holder.alphaValue = config.bgOpacity
            addSubview(holder)

            // 轻微加深提高文字对比度
            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
            overlay.alphaValue = config.bgOpacity
            addSubview(overlay)

            if config.bgBlur > 0.5 {
                if !hasRenderedInitialBackground {
                    // 启动阶段：此时窗口尚未上屏，同步渲染一次即可让首帧就是最终效果
                    hasRenderedInitialBackground = true
                    holder.layer?.contents = blurred(image, radius: config.bgBlur) ?? image
                } else {
                    renderQueue.async { [weak self] in
                        guard let self else { return }
                        let blurred = self.blurred(image, radius: config.bgBlur)
                        DispatchQueue.main.async {
                            guard gen == self.generation else { return }
                            holder.layer?.contents = blurred ?? image
                        }
                    }
                }
            }
        } else {
            let base = GlassBaseView()
            base.wantsLayer = true
            addSubview(base)
            baseView = base

            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.alphaValue = config.bgOpacity
            addSubview(effect)
            effectView = effect
        }
        applyCornerRadius()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for v in subviews { v.frame = bounds }
        applyCornerRadius()
    }

    private func applyCornerRadius() {
        for view in subviews {
            if let effect = view as? NSVisualEffectView {
                // 毛玻璃必须用 maskImage 做圆角：直接设 layer.cornerRadius 会让
                // .behindWindow 的背景合成层与圆角蒙版错位，边缘出现一圈暗线。
                effect.maskImage = cornerRadius > 0.5
                    ? Self.roundedMaskImage(radius: cornerRadius)
                    : nil
            } else {
                view.wantsLayer = true
                view.layer?.cornerRadius = cornerRadius
                view.layer?.masksToBounds = cornerRadius > 0
            }
        }
    }

    /// 可拉伸的圆角蒙版图（九宫格），供 NSVisualEffectView.maskImage 使用
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let r = max(1, radius)
        let side = r * 2 + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    /// 高斯模糊（radius 0 时返回原图）。
    ///
    /// 关键：必须先 `clampedToExtent()` 再模糊。
    /// 直接模糊的话，卷积核会在图像边界外采样到透明像素，导致输出图四周出现
    /// 一圈半透明的深色边缘。clamp 之后边界像素无限外扩，模糊结果四周依然实心。
    private func blurred(_ image: NSImage, radius: CGFloat) -> NSImage? {
        guard radius > 0.5, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let ci = CIImage(cgImage: cg)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage?.cropped(to: ci.extent) else { return image }
        let cgOut = Self.ciContext.createCGImage(output, from: output.extent)
        return cgOut.map { NSImage(cgImage: $0, size: image.size) }
    }
}

/// 毛玻璃上屏首帧的兜底底色：随浅色 / 暗色外观自动切换，避免透出黑色。
private final class GlassBaseView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.18, alpha: 1.0)
            : NSColor(calibratedWhite: 0.93, alpha: 1.0)).cgColor
    }
}
