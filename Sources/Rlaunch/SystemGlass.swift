import Cocoa

/// 系统玻璃背景的运行时适配层。
///
/// macOS 26 (Tahoe) 起 AppKit 提供了 `NSGlassEffectView`（Liquid Glass），
/// 是 `NSVisualEffectView` 的原生替代：自带 `cornerRadius`，无需再用 maskImage 做圆角。
///
/// 这里**按类名运行时探测**而不是直接引用类型：
/// 直接写 `NSGlassEffectView` 会要求使用 macOS 26 SDK 才能编译，而本项目仍支持在更早的 Xcode 上构建。
/// 探测不到时自动回退到 `NSVisualEffectView`，因此 macOS 13+ 到 macOS 26+ 都能正常工作。
enum SystemGlass {

    /// 原生玻璃的类名（macOS 26+）
    private static let nativeClassName = "NSGlassEffectView"

    /// 当前系统是否支持原生玻璃。
    ///
    /// 可用环境变量 `RLAUNCH_GLASS=legacy` 强制回退到 `NSVisualEffectView`——
    /// 原生玻璃是 macOS 26 的新 API，万一在个别机器或配置下表现异常，无需重新编译即可退回。
    static var isNativeGlassAvailable: Bool {
        if ProcessInfo.processInfo.environment["RLAUNCH_GLASS"]?.lowercased() == "legacy" {
            return false
        }
        return NSClassFromString(nativeClassName) != nil
    }

    /// 当前实际使用的渲染方式名称（用于设置界面展示 / 日志）
    static var rendererName: String {
        isNativeGlassAvailable ? "Liquid Glass（macOS 26 原生）" : "毛玻璃（NSVisualEffectView）"
    }

    // MARK: - 创建

    /// 创建一个铺满父视图的**纯背景**玻璃视图（不承载内容，内容作为兄弟视图叠在其上）。
    static func makeBackground(alpha: CGFloat) -> NSView {
        if isNativeGlassAvailable,
           let glassClass = NSClassFromString(nativeClassName) as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            // style = .regular（标准玻璃）；tintColor 留空保持中性
            glass.setValue(0, forKey: "style")
            glass.alphaValue = alpha
            glass.autoresizingMask = [.width, .height]
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.alphaValue = alpha
        effect.autoresizingMask = [.width, .height]
        return effect
    }

    /// 该视图是否为原生玻璃（回退路径下为 false）
    static func isNativeGlass(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)) == nativeClassName
    }

    /// 创建一个**需要承载子视图**的玻璃容器。
    ///
    /// 原生玻璃只保证 `contentView` 位于玻璃效果内部，任意子视图的层级不被保证，
    /// 因此承载内容的场景必须把内容加在返回的 `contentHost` 上；回退路径下两者都是同一个视图。
    static func makeContainer(cornerRadius: CGFloat,
                              material: NSVisualEffectView.Material) -> (view: NSView, contentHost: NSView) {
        if isNativeGlassAvailable,
           let glassClass = NSClassFromString(nativeClassName) as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            glass.setValue(0, forKey: "style")
            let container = NSView(frame: .zero)
            glass.setValue(container, forKey: "contentView")
            setCornerRadius(cornerRadius, on: glass)
            return (glass, container)
        }

        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        setCornerRadius(cornerRadius, on: effect)
        return (effect, effect)
    }

    // MARK: - 圆角

    /// 统一设置圆角：原生玻璃用自带属性，毛玻璃用 maskImage
    /// （直接给 NSVisualEffectView 设 layer.cornerRadius 会让 .behindWindow 采样区与圆角错位、边缘发暗）
    static func setCornerRadius(_ radius: CGFloat, on view: NSView) {
        if isNativeGlass(view) {
            view.setValue(NSNumber(value: Double(radius)), forKey: "cornerRadius")
            return
        }
        guard let effect = view as? NSVisualEffectView else { return }
        effect.maskImage = radius > 0.5 ? roundedMaskImage(radius: radius) : nil
    }

    /// 可拉伸的圆角蒙版图（九宫格），供 `NSVisualEffectView.maskImage` 使用
    static func roundedMaskImage(radius: CGFloat) -> NSImage {
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
}
