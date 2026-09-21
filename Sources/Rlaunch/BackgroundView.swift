import Cocoa
import RlaunchCore

// MARK: - 背景微质感纹理生成器

enum TextureGenerator {
    private static var cache: [String: NSImage] = [:]

    static func tileImage(for texture: BackgroundTexture, isDark: Bool) -> NSImage? {
        guard texture != .none else { return nil }
        let key = "\(texture.rawValue)_\(isDark ? "dark" : "light")"
        if let existing = cache[key] { return existing }

        let image: NSImage
        switch texture {
        case .none:
            return nil
        case .twill:
            // 45° 碳纤/微编织斜纹（8×8 pt）
            let side: CGFloat = 8
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let strokeColor = isDark
                    ? NSColor.white.withAlphaComponent(0.065)
                    : NSColor.black.withAlphaComponent(0.055)
                strokeColor.setStroke()
                let p1 = NSBezierPath()
                p1.lineWidth = 1.0
                p1.move(to: NSPoint(x: -1, y: 7))
                p1.line(to: NSPoint(x: 7, y: -1))
                p1.stroke()

                let p2 = NSBezierPath()
                p2.lineWidth = 1.0
                p2.move(to: NSPoint(x: 3, y: 11))
                p2.line(to: NSPoint(x: 11, y: 3))
                p2.stroke()
                return true
            }
        case .noise:
            // 细腻胶片/磨砂微粒（16×16 pt）
            let side: CGFloat = 16
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let dotLight = isDark
                    ? NSColor.white.withAlphaComponent(0.07)
                    : NSColor.black.withAlphaComponent(0.05)
                let dotDim = isDark
                    ? NSColor.white.withAlphaComponent(0.035)
                    : NSColor.black.withAlphaComponent(0.025)

                let dots: [(CGFloat, CGFloat, Bool)] = [
                    (2, 3, true), (6, 12, false), (11, 4, true), (14, 13, false),
                    (8, 7, true), (4, 9, false), (13, 9, true), (1, 15, false),
                    (9, 14, true), (15, 2, false), (7, 1, true), (10, 10, false)
                ]
                for (x, y, isLight) in dots {
                    (isLight ? dotLight : dotDim).setFill()
                    NSRect(x: x, y: y, width: 1.0, height: 1.0).fill()
                }
                return true
            }
        case .dotGrid:
            // 极客微点阵（14×14 pt）
            let side: CGFloat = 14
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let dotColor = isDark
                    ? NSColor.white.withAlphaComponent(0.12)
                    : NSColor.black.withAlphaComponent(0.10)
                dotColor.setFill()
                let r: CGFloat = 1.0
                let circle = NSBezierPath(ovalIn: NSRect(x: (side - r) / 2, y: (side - r) / 2, width: r, height: r))
                circle.fill()
                return true
            }
        case .grid:
            // 极细方格网（16×16 pt）
            let side: CGFloat = 16
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let lineColor = isDark
                    ? NSColor.white.withAlphaComponent(0.06)
                    : NSColor.black.withAlphaComponent(0.05)
                lineColor.setStroke()
                let p = NSBezierPath()
                p.lineWidth = 0.5
                p.move(to: NSPoint(x: 0, y: 0.25))
                p.line(to: NSPoint(x: side, y: 0.25))
                p.move(to: NSPoint(x: 0.25, y: 0))
                p.line(to: NSPoint(x: 0.25, y: side))
                p.stroke()
                return true
            }
        case .brushed:
            // 横向金属微拉丝（16×16 pt）
            let side: CGFloat = 16
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let lines: [(CGFloat, CGFloat, CGFloat)] = [
                    (2, 0.5, 0.05), (5, 0.8, 0.07), (8, 0.5, 0.04),
                    (11, 0.7, 0.065), (14, 0.5, 0.045)
                ]
                for (y, w, a) in lines {
                    let c = isDark ? NSColor.white.withAlphaComponent(a) : NSColor.black.withAlphaComponent(a)
                    c.setStroke()
                    let path = NSBezierPath()
                    path.lineWidth = w
                    path.move(to: NSPoint(x: 0, y: y))
                    path.line(to: NSPoint(x: side, y: y))
                    path.stroke()
                }
                return true
            }
        }

        cache[key] = image
        return image
    }
}

// MARK: - 背景主视图

/// 窗口背景：无图片时用系统毛玻璃（NSVisualEffectView，GPU 合成，低占用）+ 预设色与质感纹理；
/// 有图片时显示图片 + 可选高斯模糊（平滑缓存，主题切换时不闪烁）。
final class BackgroundView: NSView {
    private let renderQueue = DispatchQueue(label: "rlaunch.background", qos: .userInitiated)
    private static let ciContext = CIContext()
    private var generation = 0

    /// 首次（启动阶段）同步完成模糊预渲染，避免窗口出现后从清晰图突变为模糊图的画面跳变
    private var hasRenderedInitialBackground = false
    /// 与窗口圆角保持一致
    private var cornerRadius: CGFloat = 18

    /// 毛玻璃 / 兜底底色
    private weak var glassView: NSView?
    private weak var baseView: GlassBaseView?

    /// 当前图片模式下的视图引用与缓存
    private weak var imageHolderView: NSView?
    private weak var tintOverlayView: BackgroundTintOverlayView?
    private var currentConfig: AppConfig?
    private var cachedBlurKey: String?
    private var cachedBlurredImage: NSImage?

    /// 切换窗口模式（窗口化 18 / 全屏 0）时同步圆角
    func setCornerRadius(_ radius: CGFloat) {
        guard abs(cornerRadius - radius) > 0.01 else { return }
        cornerRadius = radius
        applyCornerRadius()
    }

    // MARK: - 上屏首帧保护

    func prepareForDisplay() {
        guard glassView != nil else { return }
        baseView?.isHidden = false
        glassView?.isHidden = true
    }

    func revealGlassAfterFirstFrame() {
        guard glassView != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.glassView?.isHidden = false
            self.baseView?.isHidden = true
        }
    }

    // MARK: - 配置更新

    func setConfig(_ config: AppConfig) {
        generation += 1
        let gen = generation
        let previousConfig = currentConfig
        currentConfig = config

        // 判定是否可以直接就地复用现有的自定义图片视图（避免任何图片一闪而过）
        if let path = config.backgroundImagePath,
           let prevPath = previousConfig?.backgroundImagePath,
           path == prevPath,
           let holder = imageHolderView,
           let overlay = tintOverlayView {
            // 图片路径未变：仅更新透明度与明暗调色遮罩，绝不移除重建视图，杜绝闪烁！
            holder.alphaValue = config.bgOpacity
            overlay.update(config: config)

            if abs(config.bgBlur - (previousConfig?.bgBlur ?? 0)) > 0.5 {
                // 仅当用户主动调整了模糊滑块时，在后台平滑重算模糊，算好后直接无缝替换
                if let image = NSImage(contentsOfFile: path) {
                    let blurKey = "\(path)_\(config.bgBlur)"
                    renderQueue.async { [weak self] in
                        guard let self else { return }
                        let blurred = self.blurred(image, radius: config.bgBlur)
                        DispatchQueue.main.async {
                            guard gen == self.generation else { return }
                            self.cachedBlurKey = blurKey
                            self.cachedBlurredImage = blurred
                            holder.layer?.contents = blurred ?? image
                        }
                    }
                }
            }
            applyCornerRadius()
            return
        }

        // 需要全量重建视图树（例如从毛玻璃切到图片，或换了新图片）
        subviews.forEach { $0.removeFromSuperview() }
        glassView = nil
        baseView = nil
        imageHolderView = nil
        tintOverlayView = nil

        if let path = config.backgroundImagePath,
           let image = NSImage(contentsOfFile: path) {
            let holder = NSView()
            holder.wantsLayer = true
            holder.layer?.contentsGravity = .resizeAspectFill
            holder.alphaValue = config.bgOpacity
            addSubview(holder)
            imageHolderView = holder

            let overlay = BackgroundTintOverlayView(isCustomImage: true)
            overlay.wantsLayer = true
            overlay.update(config: config)
            addSubview(overlay)
            tintOverlayView = overlay

            let blurKey = "\(path)_\(config.bgBlur)"
            if config.bgBlur > 0.5 {
                if cachedBlurKey == blurKey, let cached = cachedBlurredImage {
                    // 命中模糊图缓存：直接上屏已模糊好的图像，零延迟零闪烁！
                    holder.layer?.contents = cached
                } else if !hasRenderedInitialBackground {
                    // 启动阶段：首次同步完成模糊预渲染
                    hasRenderedInitialBackground = true
                    let blurred = blurred(image, radius: config.bgBlur) ?? image
                    cachedBlurKey = blurKey
                    cachedBlurredImage = blurred
                    holder.layer?.contents = blurred
                } else {
                    // 如果有旧模糊图，先用旧模糊图垫底防闪，算完新图再替换
                    if let cached = cachedBlurredImage {
                        holder.layer?.contents = cached
                    }
                    renderQueue.async { [weak self] in
                        guard let self else { return }
                        let blurred = self.blurred(image, radius: config.bgBlur) ?? image
                        DispatchQueue.main.async {
                            guard gen == self.generation else { return }
                            self.cachedBlurKey = blurKey
                            self.cachedBlurredImage = blurred
                            holder.layer?.contents = blurred
                        }
                    }
                }
            } else {
                holder.layer?.contents = image
            }
        } else {
            let base = GlassBaseView()
            base.wantsLayer = true
            base.lightPresetId = config.lightBgPreset
            base.darkPresetId = config.darkBgPreset
            base.isHidden = true
            addSubview(base)
            baseView = base

            let glass = SystemGlass.makeBackground(alpha: config.bgOpacity)
            addSubview(glass)
            glassView = glass

            let tintOverlay = BackgroundTintOverlayView(isCustomImage: false)
            tintOverlay.wantsLayer = true
            tintOverlay.update(config: config)
            addSubview(tintOverlay)
            tintOverlayView = tintOverlay
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
            if view === glassView {
                SystemGlass.setCornerRadius(cornerRadius, on: view)
            } else {
                view.wantsLayer = true
                view.layer?.cornerRadius = cornerRadius
                view.layer?.masksToBounds = cornerRadius > 0
            }
        }
    }

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

// MARK: - 毛玻璃首帧兜底底色

private final class GlassBaseView: NSView {
    var lightPresetId: String = "softGray"
    var darkPresetId: String = "default"

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            let preset = BackgroundPresets.findDark(id: darkPresetId)
            layer?.backgroundColor = NSColor(
                calibratedRed: CGFloat(preset.red),
                green: CGFloat(preset.green),
                blue: CGFloat(preset.blue),
                alpha: 1.0
            ).cgColor
        } else {
            let preset = BackgroundPresets.findLight(id: lightPresetId)
            layer?.backgroundColor = NSColor(
                calibratedRed: CGFloat(preset.red),
                green: CGFloat(preset.green),
                blue: CGFloat(preset.blue),
                alpha: 1.0
            ).cgColor
        }
    }
}

// MARK: - 背景色彩与纹理调色层

final class BackgroundTintOverlayView: NSView {
    private var config: AppConfig = .defaults
    private let isCustomImage: Bool
    private let textureLayer = CALayer()

    init(isCustomImage: Bool = false) {
        self.isCustomImage = isCustomImage
        super.init(frame: .zero)
        wantsLayer = true
        textureLayer.masksToBounds = true
        layer?.addSublayer(textureLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func update(config: AppConfig) {
        self.config = config
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        textureLayer.frame = bounds
    }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let op = CGFloat(max(0, min(config.bgOpacity, 1.0)))

        if isCustomImage {
            textureLayer.contents = nil
            textureLayer.backgroundColor = nil
            if isDark {
                let alpha = (0.18 + 0.24 * op) * op
                layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
            } else {
                let alpha = 0.10 * op
                layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
            }
            return
        }

        let preset = isDark
            ? BackgroundPresets.findDark(id: config.darkBgPreset)
            : BackgroundPresets.findLight(id: config.lightBgPreset)

        // 1. 底层微光/沉浸调色
        if isDark {
            if preset.id == "default" {
                let alpha = 0.38 * op
                layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
            } else {
                let alpha = CGFloat(preset.tintOpacity) * op
                layer?.backgroundColor = NSColor(
                    calibratedRed: CGFloat(preset.red),
                    green: CGFloat(preset.green),
                    blue: CGFloat(preset.blue),
                    alpha: alpha
                ).cgColor
            }
        } else {
            let alpha = CGFloat(preset.tintOpacity) * (0.35 + 0.65 * op)
            layer?.backgroundColor = NSColor(
                calibratedRed: CGFloat(preset.red),
                green: CGFloat(preset.green),
                blue: CGFloat(preset.blue),
                alpha: alpha
            ).cgColor
        }

        // 2. 叠加细腻微质感纹理层（当预设包含纹理时）
        if preset.texture != .none,
           let tile = TextureGenerator.tileImage(for: preset.texture, isDark: isDark) {
            textureLayer.backgroundColor = NSColor(patternImage: tile).cgColor
            textureLayer.opacity = Float(min(1.0, 0.45 + 0.55 * op))
        } else {
            textureLayer.backgroundColor = nil
        }
    }
}
