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
        NSLog("Rlaunch: 背景渲染方式 = %@", SystemGlass.rendererName)

        mainController = MainWindowController(config: config) // 内部已启动扫描
        mainController.show()

        menuBar = MenuBarController()
        menuBar.setup(
            // 菜单栏图标左键：直接以「小屏窗口」形态显示 / 收起，不再弹菜单
            onToggle: { [weak self] in self?.mainController.toggleWindowed() },
            onSettings: { [weak self] in self?.mainController.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        // 全局快捷键：切换显示/隐藏；四指/五指捏合：隐藏时打开并全屏，显示时收起
        hotKey = HotKeyMonitor()
        hotKey.onTrigger = { [weak self] in self?.mainController.toggle() }
        pinch = PinchMonitor()
        pinch.onTrigger = { [weak self] in
            guard let self else { return }
            if self.mainController.isFrontmost {
                self.mainController.hide()
            } else {
                self.mainController.showFullScreen()
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

    @objc private func configDidChange() {
        applyMonitors(config: ConfigStore.load())
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
