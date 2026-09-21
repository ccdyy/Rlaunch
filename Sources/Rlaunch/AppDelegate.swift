import Cocoa
import RlaunchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController!
    private var menuBar: MenuBarController!
    private var pinch: PinchMonitor!
    private var hotKey: HotKeyMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppIcon.application {
            NSApp.applicationIconImage = icon
        }

        let config = ConfigStore.load()
        ThemeManager.current = config.theme
        L10n.setLanguage(config.language)
        NSLog("Rlaunch: 背景渲染方式 = %@，界面语言 = %@", SystemGlass.rendererName, L10n.language.rawValue)

        mainController = MainWindowController(config: config) // 内部已启动扫描
        mainController.show()


        menuBar = MenuBarController()
        menuBar.setup(
            // 菜单栏图标左键：直接以「小屏窗口」形态显示 / 收起，不再弹菜单
            onToggle: { [weak self] in self?.mainController.toggleWindowed() },
            onSettings: { [weak self] in self?.mainController.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        // 全局快捷键：切换显示/隐藏；四指/五指捏合与张开手势
        hotKey = HotKeyMonitor()
        hotKey.onTrigger = { [weak self] in self?.mainController.toggle() }
        pinch = PinchMonitor()
        pinch.onGestureAction = { [weak self] action in
            guard let self else { return }
            let mouseScreen = MainWindowController.screenContainingMouse()
            switch action {
            case .pinchIn:
                // 四指/五指捏合：唤起全屏，或在分屏多显示器下根据鼠标所在屏幕做屏幕切换
                if self.mainController.isVisible {
                    if let target = mouseScreen,
                       let current = self.mainController.window?.screen,
                       target != current {
                        // 鼠标在另一显示器屏幕捏合：平滑切换到该屏幕显示
                        self.mainController.switchToScreen(target)
                    } else {
                        // 鼠标在当前全屏所在的屏幕捏合：收起隐藏
                        self.mainController.hide()
                    }
                } else {
                    // 隐藏状态下：在鼠标当前所在的屏幕全屏打开
                    self.mainController.showFullScreen(on: mouseScreen)
                }

            case .pinchOut:
                // 四指/五指张开：支持张开关闭
                if self.mainController.isVisible {
                    self.mainController.hide()
                }
            }
        }
        applyMonitors(config: config)

        // 设置面板保存后：重新应用快捷键/捏合监听
        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange), name: ConfigStore.didChange, object: nil)
        // 从系统设置授权返回后重试捏合监听（event tap 需要辅助功能权限）
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - 监听应用（按需重启，避免每次设置保存都打断触控板会话）

    private var appliedHotKey: (Bool, Int?, Int)?
    private var appliedPinch: (Bool, Double)?

    private func applyMonitors(config: AppConfig) {
        let hk = (config.hotKeyEnabled, config.hotKeyKeyCode, config.hotKeyModifiers)
        if !(appliedHotKey.map { $0 == hk } ?? false) {
            hotKey.apply(config: config)
            appliedHotKey = hk
        }
        let pk = (config.pinchEnabled, config.pinchThreshold)
        if !(appliedPinch.map { $0 == pk } ?? false) {
            pinch.apply(config: config)
            appliedPinch = pk
        }
    }

    private var appliedLanguage: AppLanguage?

    @objc private func configDidChange() {
        let config = ConfigStore.load()
        applyMonitors(config: config)
        // 语言变化时重建菜单栏菜单（其标题在创建时固定）
        if appliedLanguage != config.language {
            appliedLanguage = config.language
            L10n.setLanguage(config.language)
            menuBar?.applyLanguage()
        }
    }

    @objc private func appDidBecomeActive() {
        let config = ConfigStore.load()
        if config.pinchEnabled && !pinch.isRunning {
            pinch.apply(config: config)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 窗口关闭不退出，驻留菜单栏
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainController?.persistFrameForTermination()
        hotKey?.stop()
        pinch.stop() // 干净释放触控板会话，避免系统会话被楔死
    }
}
