import Cocoa
import RlaunchCore

/// 全局手势监听：两指捏合（magnify 事件）累计幅度超过阈值时唤起界面。
///
/// 说明：macOS 把四指/五指捏合保留为系统级 Launchpad/Exposé 手势，第三方应用无法接管；
/// 本实现监听全局 magnify 事件（捏合/张开），以累计幅度阈值区分误触，
/// 效果等同触控板捏合唤起。若想更接近原版，可在系统设置中把「启动台」手势关闭后
/// 使用本实现的两指捏合唤起。
final class GestureMonitor {
    var onTrigger: (() -> Void)?

    private var monitor: Any?
    private var accumulation: CGFloat = 0
    private var isTracking = false
    private var threshold: CGFloat = 0.7

    func start(config: AppConfig) {
        stop()
        guard config.gestureEnabled else { return }
        threshold = CGFloat(config.gestureThreshold)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.magnify, .gesture]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        accumulation = 0
        isTracking = false
    }

    private func handle(_ event: NSEvent) {
        guard onTrigger != nil else { return }
        if event.type == .gesture {
            // 四指/五指捏合等系统手势由 macOS 保留（Launchpad/Exposé），第三方无法接管
            return
        }
        guard event.type == .magnify else { return }
        if event.phase.contains(.began) {
            accumulation = 0
            isTracking = true
        }
        guard isTracking else { return }
        accumulation += event.magnification
        if event.phase.contains(.ended) || event.phase.isEmpty {
            isTracking = false
            if abs(accumulation) >= threshold {
                accumulation = 0
                onTrigger?()
            }
        }
    }
}
