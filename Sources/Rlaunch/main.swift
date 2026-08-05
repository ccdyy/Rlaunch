import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 无 Dock 图标，驻留菜单栏
let delegate = AppDelegate()
app.delegate = delegate
app.run()
