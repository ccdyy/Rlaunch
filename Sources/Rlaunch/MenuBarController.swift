import Cocoa

/// 菜单栏状态项：显示/隐藏、设置、退出（LSUIElement 应用的主入口之一）。
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func setup(onToggle: @escaping () -> Void,
               onSettings: @escaping () -> Void,
               onQuit: @escaping () -> Void) {
        if let image = AppIcon.menuBar {
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Rlaunch"

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "显示 / 隐藏 Rlaunch", action: #selector(toggleAction), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Rlaunch", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        self.onToggle = onToggle
        self.onSettings = onSettings
        self.onQuit = onQuit
    }

    private var onToggle: (() -> Void)?
    private var onSettings: (() -> Void)?
    private var onQuit: (() -> Void)?

    @objc private func toggleAction() { onToggle?() }
    @objc private func settingsAction() { onSettings?() }
    @objc private func quitAction() { onQuit?() }
}
