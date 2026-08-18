import Cocoa

/// 从 App Bundle 加载应用图标（AppIcon.icns / MenuBarIcon.png）。
enum AppIcon {
    /// 应用主图标（关于、活动监视器等）
    static var application: NSImage? {
        if let icns = NSImage(named: "AppIcon") { return icns }
        return loadPNG("AppIcon-1024")
    }

    /// 菜单栏状态项图标（彩色，非 template）：显式拼接 @1x/@2x 表示，保证 Retina 清晰
    static var menuBar: NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        var reps = 0
        if let rep = bitmapRep("MenuBarIcon", points: 18) {
            image.addRepresentation(rep)
            reps += 1
        }
        if let rep = bitmapRep("MenuBarIcon@2x", points: 18) {
            image.addRepresentation(rep)
            reps += 1
        }
        guard reps > 0 else { return application }
        image.isTemplate = false
        return image
    }

    private static func bitmapRep(_ name: String, points: CGFloat) -> NSBitmapImageRep? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        // 以点为单位设置逻辑尺寸：@1x 与 @2x 均表示 18pt，AppKit 自动按像素密度选取
        rep.size = NSSize(width: points, height: points)
        return rep
    }

    private static func loadPNG(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }
}
