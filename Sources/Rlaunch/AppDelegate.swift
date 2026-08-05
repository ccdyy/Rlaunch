import Cocoa
import RlaunchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: MainWindowController!
    private var menuBar: MenuBarController!
    private var gesture: GestureMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigStore.load()
        ThemeManager.current = config.theme

        mainController = MainWindowController(config: config)
        mainController.startScan()
        mainController.show()

        menuBar = MenuBarController()
        menuBar.setup(
            onToggle: { [weak self] in self?.mainController.toggle() },
            onSettings: { [weak self] in self?.mainController.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        gesture = GestureMonitor()
        gesture.onTrigger = { [weak self] in self?.mainController.toggle() }
        gesture.start(config: config)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 窗口关闭不退出，驻留菜单栏
    }
}
