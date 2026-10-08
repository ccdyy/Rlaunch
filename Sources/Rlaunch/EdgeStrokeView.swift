import Cocoa

/// 窗口与卡片的 1px 描边层。
///
/// 原生窗口四边都有一条极细的描边（暗色偏白高光、亮色偏黑细线），但 `CALayer.border`
/// **会被子层盖住**——玻璃容器上还叠了调色层与内容层，所以过去写在 `glassContainer.layer`
/// 上的 border 实际上一条都没显示出来（截图像素里搜索框边缘只有系统玻璃自带的暗边）。
///
/// 这里统一改用「宿主视图最顶层、且不接收鼠标事件的描边视图」来画这条边：
/// 它自身没有子层，border 必然可见；`hitTest` 返回 nil，不会挡住按钮与窗口拖动。
///
/// 圆角曲率必须与宿主真实轮廓一致，否则描边会飘在轮廓外或缩在里面：
/// - 自家图层裁剪的卡片（文件夹弹窗、提示浮层、设置卡片、有背景图时的主窗口）→ `.continuous`，与系统窗口同形；
/// - 由系统玻璃视图裁剪的面（毛玻璃模式的主窗口、设置窗口、搜索框、分页条）→ `.circular`，与之严丝合缝。
final class EdgeStrokeView: NSView {

    private var cornerRadiusValue: CGFloat
    private var isContinuous: Bool
    private var explicitColor: NSColor?
    /// nil 表示使用「1 物理像素」细线（Retina 上为 0.5pt，与系统窗口边框一致）
    private let fixedStrokeWidth: CGFloat?

    init(cornerRadius: CGFloat,
         color: NSColor? = nil,
         width: CGFloat? = 1,
         continuous: Bool = true) {
        self.cornerRadiusValue = cornerRadius
        self.explicitColor = color
        self.fixedStrokeWidth = width
        self.isContinuous = continuous
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 只负责显示，不能参与命中测试
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        applyStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    override func updateLayer() {
        applyStyle()
    }

    func update(cornerRadius: CGFloat? = nil, color: NSColor? = nil, continuous: Bool? = nil) {
        if let cornerRadius { cornerRadiusValue = cornerRadius }
        if let continuous { isContinuous = continuous }
        explicitColor = color
        applyStyle()
    }

    private func applyStyle() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadiusValue
        layer.cornerCurve = isContinuous ? .continuous : .circular
        layer.borderWidth = fixedStrokeWidth ?? hairlineWidth
        layer.borderColor = (explicitColor ?? Self.automaticColor(for: effectiveAppearance)).cgColor
    }

    /// 1 物理像素对应的点宽（Retina 为 0.5pt）——系统窗口边框与分隔线都是这个粗细
    var hairlineWidth: CGFloat { 1.0 / max(window?.backingScaleFactor ?? 2, 1) }

    /// 与系统窗口一致的描边色：暗色偏白高光，亮色偏黑细线
    static func automaticColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.13)
            : NSColor.black.withAlphaComponent(0.11)
    }

    /// 安装到宿主视图最上层（覆盖全部内容，但不拦截交互）
    @discardableResult
    static func install(on host: NSView,
                        cornerRadius: CGFloat,
                        color: NSColor? = nil,
                        width: CGFloat? = 1,
                        continuous: Bool = true) -> EdgeStrokeView {
        let stroke = EdgeStrokeView(cornerRadius: cornerRadius,
                                    color: color,
                                    width: width,
                                    continuous: continuous)
        stroke.frame = host.bounds
        host.addSubview(stroke, positioned: .above, relativeTo: nil)
        return stroke
    }
}

/// 1 物理像素高的分隔线（系统列表分隔线就是这个粗细，1pt 会明显偏粗）
final class HairlineView: NSView {
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let c = heightAnchor.constraint(equalToConstant: 0.5)
        c.isActive = true
        heightConstraint = c
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        heightConstraint?.constant = 1.0 / max(window?.backingScaleFactor ?? 2, 1)
    }
}

extension CALayer {
    /// 统一设置圆角：`continuous` 为 Apple 连续曲率（系统窗口/卡片的形状）
    func applyRoundedCorner(radius: CGFloat, continuous: Bool, masksToBounds: Bool) {
        cornerRadius = radius
        cornerCurve = continuous ? .continuous : .circular
        self.masksToBounds = masksToBounds
    }
}
