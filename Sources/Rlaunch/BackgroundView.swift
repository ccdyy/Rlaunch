import Cocoa
import RlaunchCore

/// 窗口背景：无图片时用系统毛玻璃（NSVisualEffectView，GPU 合成，低占用）；
/// 有图片时显示图片 + 可选高斯模糊（后台线程预渲染，仅设置变化时重算一次）。
final class BackgroundView: NSView {
    private let renderQueue = DispatchQueue(label: "rlaunch.background", qos: .userInitiated)
    private static let ciContext = CIContext()
    private var generation = 0 // 防止旧渲染结果覆盖新设置

    func setConfig(_ config: AppConfig) {
        generation += 1
        let gen = generation
        subviews.forEach { $0.removeFromSuperview() }

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
                renderQueue.async { [weak self] in
                    guard let self else { return }
                    let blurred = self.blurred(image, radius: config.bgBlur)
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        holder.layer?.contents = blurred ?? image
                    }
                }
            }
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.alphaValue = config.bgOpacity
            addSubview(effect)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for v in subviews { v.frame = bounds }
    }

    /// 高斯模糊（radius 0 时返回原图），后台线程调用。
    private func blurred(_ image: NSImage, radius: CGFloat) -> NSImage? {
        guard radius > 0.5, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let ci = CIImage(cgImage: cg)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ci, forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage?.cropped(to: ci.extent) else { return image }
        let cgOut = Self.ciContext.createCGImage(output, from: output.extent)
        return cgOut.map { NSImage(cgImage: $0, size: image.size) }
    }
}
