import Cocoa

/// 菜单栏状态项：
/// - **左键点击**：直接显示 / 收起 Rlaunch 的「小屏」窗口化界面，不再弹出菜单；
/// - **右键（或 ⌃ + 左键）**：弹出「设置 / 退出」菜单，保留退出入口。
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var onToggle: (() -> Void)?
    private var onSettings: (() -> Void)?
    private var onQuit: (() -> Void)?
    private var contextMenu: NSMenu?
    /// 防止 performClick 展示菜单时再次进入点击回调
    private var isShowingMenu = false

    func setup(onToggle: @escaping () -> Void,
               onSettings: @escaping () -> Void,
               onQuit: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onSettings = onSettings
        self.onQuit = onQuit

        if let button = statusItem.button {
            if let image = AppIcon.menuBar {
                button.image = image
            }
            button.toolTip = "Rlaunch：点击打开 / 收起，右键查看更多"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 同时接收左右键抬起事件，左键走直开、右键走菜单
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

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

        contextMenu = menu
    }

    // MARK: - 点击分发

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard !isShowingMenu else { return }
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondaryClick {
            presentContextMenu(from: sender)
        } else {
            onToggle?()
        }
    }

    /// 在状态项图标正下方弹出菜单（同步跟踪，菜单关闭后返回）
    private func presentContextMenu(from button: NSStatusBarButton) {
        guard let contextMenu else { return }
        isShowingMenu = true
        contextMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 6),
            in: button)
        isShowingMenu = false
    }

    @objc private func toggleAction() { onToggle?() }
    @objc private func settingsAction() { onSettings?() }
    @objc private func quitAction() { onQuit?() }
}
