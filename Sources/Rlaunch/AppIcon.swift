import Cocoa

/// 从 App Bundle 加载应用图标（AppIcon.icns / MenuBarIcon.png）。
enum AppIcon {
    /// 应用主图标（关于、活动监视器等）
    static var application: NSImage? {
        if let icns = NSImage(named: "AppIcon") { return icns }
        return loadPNG("AppIcon-1024")
    }

    /// 菜单栏状态项图标（彩色，非 template）
    static var menuBar: NSImage? {
        guard let image = loadPNG("MenuBarIcon") else { return application }
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = false
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }

    private static func loadPNG(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }
}
