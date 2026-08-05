import Cocoa

public extension Notification.Name {
    static let themeDidChange = Notification.Name("RlaunchThemeDidChange")
}

/// 全局主题：通过 NSApp.appearance 一键切换明亮 / 深黑 / 跟随系统。
public enum ThemeManager {
    public static var current: Theme = .dark {
        didSet { apply() }
    }

    public static func apply() {
        switch current {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:  NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }
}
