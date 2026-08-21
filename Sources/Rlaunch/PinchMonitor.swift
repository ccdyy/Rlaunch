import Cocoa
import RlaunchCore

/// 全局捏合监听：四指/五指「捏合」（手指间距缩小）触发唤起（隐藏时打开并全屏）。
///
/// 主路径：MultitouchSupport 私有框架直接读取触控板触点数据——
/// - 无需任何权限，不受系统手势保留影响，能精确统计手指数；
/// - 触点结构体（MTTouch）字段偏移来自公开逆向定义，运行首帧日志用于核对。
/// 回退路径：CGEventTap 监听系统 magnify 事件（需要「辅助功能」权限）。
final class PinchMonitor {
    var onTrigger: (() -> Void)?

    private(set) var isRunning = false

    // MARK: - MultitouchSupport 主路径

    private var mtDevices: [OpaquePointer] = []
    private var mtCallbackBlock: Any?
    private var mtLogFrames = 0
    private let mtLock = NSLock()
    private var requiredShrink: Float = 0.2
    private var armed = false
    private var fired = false
    private var spanInitial: Float = 0

    /// 日志同时写文件（~/Library/Logs/Rlaunch-pinch.log），
    /// 通过 open 启动时 NSLog 进统一日志不易抓取，文件便于诊断。
    private func pinLog(_ message: String) {
        NSLog("Rlaunch: %@", message)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Rlaunch-pinch.log")
        let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    // MARK: - CGEventTap 回退路径

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accumulation: CGFloat = 0
    private var isTracking = false
    private var maxFingers = 0
    private var threshold: CGFloat = 0.7

    func start(config: AppConfig) {
        stop()
        guard config.pinchEnabled else { return }
        requiredShrink = shrink(for: config.pinchThreshold)
        threshold = CGFloat(config.pinchThreshold)
        pinLog("启动捏合监听 AXIsProcessTrusted=\(AXIsProcessTrusted())")
        let mtOK = startMultitouch()
        let tapOK = startEventTap() // 与 MT 并行；触发有冷却去重
        if mtOK && tapOK {
            isRunning = true
            pinLog("捏合监听已启用（触点数据 + 手势事件并行）")
        } else if mtOK {
            isRunning = true
            pinLog("捏合监听已启用（触控板触点数据）")
        } else if tapOK {
            isRunning = true
            pinLog("捏合监听已启用（系统手势事件，需辅助功能权限）")
        } else {
            pinLog("捏合监听启用失败（无触控板数据源，且手势事件监听需辅助功能权限）")
        }
        startLocalDiagnostics()
        startWakeObservers()
        startHealthCheck()
    }

    /// 配置变更时按需应用：运行中只更新阈值（避免反复重启触控板会话）
    func apply(config: AppConfig) {
        if config.pinchEnabled {
            threshold = CGFloat(config.pinchThreshold)
            requiredShrink = shrink(for: config.pinchThreshold)
            if !isRunning {
                start(config: config)
            }
        } else {
            stop()
        }
    }

    func stop() {
        stopMultitouch()
        stopLocalDiagnostics()
        stopEventTap()
        stopWakeObservers()
        stopHealthCheck()
        isRunning = false
        accumulation = 0
        isTracking = false
        maxFingers = 0
        mtLock.lock()
        armed = false
        fired = false
        spanInitial = 0
        mtLock.unlock()
    }

    private func stopEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    // MARK: - 休眠/唤醒与长时间运行的自愈（event tap 可能被系统禁用）

    private var wakeObservers: [NSObjectProtocol] = []
    private var healthTimer: Timer?

    private func startWakeObservers() {
        stopWakeObservers()
        let c = NSWorkspace.shared.notificationCenter
        wakeObservers.append(c.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pinLog("系统唤醒，重新校验捏合监听")
            self?.revalidateTap()
        })
        wakeObservers.append(c.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.revalidateTap()
        })
    }

    private func stopWakeObservers() {
        let c = NSWorkspace.shared.notificationCenter
        for o in wakeObservers { c.removeObserver(o) }
        wakeObservers.removeAll()
    }

    private func startHealthCheck() {
        stopHealthCheck()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.revalidateTap()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func stopHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// 检查 event tap 是否仍可用：被禁用则重新启用，仍无效则整体重建
    private func revalidateTap() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            pinLog("捏合事件监听被系统禁用，尝试重新启用")
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                pinLog("重新启用失败，重建捏合事件监听")
                stopEventTap()
                if startEventTap() {
                    isRunning = true
                }
            }
        }
    }

    // MARK: - 触发（冷却去重：MT 与事件监听并行时的双触发只算一次）

    private var lastTriggerAt: TimeInterval = 0

    private func fireTrigger(_ source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastTriggerAt > 1.2 else {
                self.pinLog("触发冷却中，忽略（\(source)）")
                return
            }
            self.lastTriggerAt = now
            self.pinLog("触发唤起（\(source)）")
            self.onTrigger?()
        }
    }

    // MARK: - 本地手势事件诊断（应用在前台时收到的 magnify，用于核对系统手势上报）

    private var localMonitor: Any?

    private func startLocalDiagnostics() {
        stopLocalDiagnostics()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .gesture]) { [weak self] event in
            let touches = event.touches(matching: .touching, in: nil).count
            self?.pinLog("本地手势 type=\(event.type.rawValue) mag=\(String(format: "%.3f", event.magnification)) touches=\(touches)")
            return event
        }
    }

    private func stopLocalDiagnostics() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    // MARK: - MultitouchSupport 实现

    /// MT 回调：历史签名返回 int（非零表示继续接收），返回 1 保持投递
    private typealias MTFrameCallback = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32, Double, Int32) -> Int32

    private func startMultitouch() -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) else {
            pinLog("加载 MultitouchSupport 失败：\(String(cString: dlerror() ?? strdup("unknown")))")
            return false
        }
        guard let createListSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let registerFullSym = dlsym(handle, "MTRegisterFullFrameCallback"),
              let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let unregisterFullSym = dlsym(handle, "MTUnregisterFullFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop"),
              let isRunningSym = dlsym(handle, "MTDeviceIsRunning") else {
            pinLog("MultitouchSupport 符号缺失")
            return false
        }
        let createList = unsafeBitCast(createListSym, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        let register = unsafeBitCast(registerSym, to: (@convention(c) (OpaquePointer?, MTFrameCallback) -> Void).self)
        let registerFull = unsafeBitCast(registerFullSym, to: (@convention(c) (OpaquePointer?, MTFrameCallback) -> Void).self)
        let unregister = unsafeBitCast(unregisterSym, to: (@convention(c) (OpaquePointer?, MTFrameCallback) -> Void).self)
        let unregisterFull = unsafeBitCast(unregisterFullSym, to: (@convention(c) (OpaquePointer?, MTFrameCallback) -> Void).self)
        let startDevice = unsafeBitCast(startSym, to: (@convention(c) (OpaquePointer?, Int32) -> OSStatus).self)
        let stopDevice = unsafeBitCast(stopSym, to: (@convention(c) (OpaquePointer?) -> Void).self)
        let deviceIsRunning = unsafeBitCast(isRunningSym, to: (@convention(c) (OpaquePointer?) -> Bool).self)

        guard let listPtr = createList() else {
            pinLog("无触控板设备（MTDeviceCreateList 返回空）")
            return false
        }
        let list = Unmanaged<CFArray>.fromOpaque(listPtr).takeUnretainedValue()
        let count = CFArrayGetCount(list)
        guard count > 0 else {
            pinLog("触控板设备列表为空")
            return false
        }
        pinLog("发现 \(count) 个触控板设备")

        // 回调不能直接捕获上下文（C 函数指针），用 block → IMP 桥接；返回 1 表示继续接收帧
        let callback: @convention(block) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32, Double, Int32) -> Int32 = {
            [weak self] device, data, nFingers, timestamp, frame in
            self?.handleMTFrame(device: device, data: data, count: Int(nFingers),
                                timestamp: timestamp, frame: Int(frame))
            return 1
        }
        let imp = imp_implementationWithBlock(callback)
        let cCallback = unsafeBitCast(imp, to: MTFrameCallback.self)
        mtCallbackBlock = callback

        var started = false
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = OpaquePointer(raw)
            // 同时注册触点帧与全量帧回调，适配不同系统版本的帧上报路径
            register(device, cCallback)
            registerFull(device, cCallback)
            let status = startDevice(device, 1) // 1 = 抓取触点帧
            pinLog("设备[\(i)] 启动 status=\(status) isRunning=\(deviceIsRunning(device))")
            if status == 0 {
                mtDevices.append(device)
                started = true
            } else {
                pinLog("触控板设备启动失败 status=\(status)")
                unregister(device, cCallback)
                unregisterFull(device, cCallback)
                // 注意：不调用 MTDeviceRelease —— 引用来自框架设备列表，属借用
            }
        }
        if !started { pinLog("所有触控板设备启动失败") }
        return started
    }

    private func stopMultitouch() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
            let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback"),
            let unregisterFullSym = dlsym(handle, "MTUnregisterFullFrameCallback"),
            let stopSym = dlsym(handle, "MTDeviceStop") else {
            mtDevices.removeAll()
            return
        }
        let unregister = unsafeBitCast(unregisterSym, to: (@convention(c) (OpaquePointer?, MTFrameCallback) -> Void).self)
        let unregisterFull = unsafeBitCast(unregisterFullSym, to: (@convention(c) (OpaquePointer?, MTFrameCallback) -> Void).self)
        let stopDevice = unsafeBitCast(stopSym, to: (@convention(c) (OpaquePointer?) -> Void).self)
        let block = mtCallbackBlock
        if let imp = block.map({ imp_implementationWithBlock($0) }) {
            let cCallback = unsafeBitCast(imp, to: MTFrameCallback.self)
            for device in mtDevices {
                unregister(device, cCallback)
                unregisterFull(device, cCallback)
                stopDevice(device)
                // 不调用 MTDeviceRelease：设备引用来自框架列表（借用）
            }
        }
        mtDevices.removeAll()
    }

    /// 读取一帧触点：MTTouch 布局（MultitouchSupport）——
    /// 0:frame(i32) 8:timestamp(f64) 16:identifier(i32) 20:state(i32)
    /// 24:fingerId 28:handId 32:normalized.pos.x(f32) 36:normalized.pos.y(f32)
    /// 40:vel.x 44:vel.y 48:total 52:pressure 56:angle 60:major 64:minor
    /// 68:absolute.pos.x 72:absolute.pos.y 76:vel.x 80:vel.y 84/88:i32 92:density
    /// 读取一帧触点。注意：新系统上回调第三参数语义待确认（可能是帧号而非手指数），
    /// 因此按「槽位池」读取：遇到 state==0 的空槽即停，最多 16 槽，防止越界。
    private func handleMTFrame(device: OpaquePointer?, data: UnsafeMutablePointer<UInt8>?, count: Int, timestamp: Double, frame: Int) {
        guard let data else { return }
        let stride = 96
        var touching: [(Float, Float)] = []
        var valid = true
        var slots = 0
        for i in 0..<16 {
            let p = UnsafeRawPointer(data + i * stride)
            let state = p.load(fromByteOffset: 20, as: Int32.self)
            let x = p.load(fromByteOffset: 32, as: Float.self)
            let y = p.load(fromByteOffset: 36, as: Float.self)
            slots = i + 1
            if state == 4, x >= -0.2, x <= 1.2, y >= -0.2, y <= 1.2 {
                touching.append((x, y))
            } else if state == 0, x == 0, y == 0 {
                break // 空槽：触点池结束
            } else if state < 0 || state > 7 || !(x >= -1 && x <= 2) || !(y >= -1 && y <= 2) {
                valid = false // 布局不符，数据不可信
                break
            }
        }
        if mtLogFrames < 5 {
            mtLogFrames += 1
            var hex = ""
            for b in 0..<min(32, 32) { hex += String(format: "%02x ", data[b]) }
            pinLog("MT帧#\(mtLogFrames) 参数count=\(count) ts=\(String(format: "%.3f", timestamp)) frame=\(frame) slots=\(slots) valid=\(valid)")
            pinLog("MT帧 hex32: \(hex)")
        }
        guard valid else { return }
        updatePinch(fingerCount: touching.count, positions: touching)
    }

    private func updatePinch(fingerCount: Int, positions: [(Float, Float)]) {
        mtLock.lock()
        defer { mtLock.unlock() }
        guard fingerCount >= 4 else {
            if fingerCount <= 2 { armed = false; fired = false; spanInitial = 0 }
            return
        }
        let span = maxSpan(positions)
        if !armed {
            armed = true
            fired = false
            spanInitial = max(span, 0.001)
            pinLog("捏合准备 手指数=\(fingerCount) 初始跨度=\(String(format: "%.3f", spanInitial))")
            return
        }
        let ratio = span / spanInitial
        if !fired, ratio <= 1 - requiredShrink {
            fired = true
            pinLog("捏合达标 手指数=\(fingerCount) 跨度=\(String(format: "%.3f", spanInitial))→\(String(format: "%.3f", span))")
            fireTrigger("触点数据")
        }
    }

    /// 四指/五指捏合的跨度 = 触点间最大距离
    private func maxSpan(_ pts: [(Float, Float)]) -> Float {
        var m: Float = 0
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let dx = pts[i].0 - pts[j].0
                let dy = pts[i].1 - pts[j].1
                m = max(m, (dx * dx + dy * dy).squareRoot())
            }
        }
        return m
    }

    /// 灵敏度阈值（0.3~2.0，默认 0.7）→ 需要的跨度收缩比例（0.15~0.45）
    private func shrink(for threshold: Double) -> Float {
        Float(min(0.45, max(0.15, 0.10 + 0.15 * threshold)))
    }

    // MARK: - CGEventTap 回退

    private static let eventGestureStarted: UInt32 = 29 // kCGEventGestureStarted
    private static let eventGestureEnded: UInt32 = 30   // kCGEventGestureEnded
    private static let eventMagnify: UInt32 = 31        // kCGEventMagnify
    private static let eventSwipe: UInt32 = 27          // kCGEventSwipe
    private static let eventRotate: UInt32 = 18         // kCGEventRotate
    private static let eventSmartMagnify: UInt32 = 32   // kCGEventSmartMagnify

    private var tapFired = false
    // 跨度检测：四指下落期间记录触点间距的最大/最小值，收缩比例达标即判定捏合
    private var streamSpanMax: Float = 0
    private var streamSpanMin: Float = .greatestFiniteMagnitude
    private var sawFourPlus = false

    private func startEventTap() -> Bool {
        let mask = (CGEventMask(1) << Self.eventGestureStarted)
            | (CGEventMask(1) << Self.eventMagnify)
            | (CGEventMask(1) << Self.eventGestureEnded)
            | (CGEventMask(1) << Self.eventSwipe)
            | (CGEventMask(1) << Self.eventRotate)
            | (CGEventMask(1) << Self.eventSmartMagnify)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<PinchMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // 系统禁用通知（休眠/超时/用户输入打断）：立即重新启用并丢弃该事件
                if type.rawValue >= 0xFFFFFFF0 {
                    monitor.pinLog("收到事件监听禁用通知 type=\(type.rawValue)，重新启用")
                    if let tap = monitor.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return nil
                }
                monitor.handleTapEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            pinLog("事件监听创建失败（需要「辅助功能」权限）")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        tap = newTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    /// 转储手势事件字段（诊断）：110=HIDType 111/112=scroll 113=zoom 114=rotate 115/116=swipe
    private func dumpGestureFields(_ event: CGEvent) -> String {
        var s = ""
        for f in [110, 111, 112, 113, 114, 115, 116, 117, 118] {
            if let field = CGEventField(rawValue: UInt32(f)) {
                s += " f\(f)=\(String(format: "%.3f", event.getDoubleValueField(field)))"
            }
        }
        return s
    }

    /// 触点描述：数量 + 各触点归一化位置（诊断与跨度检测共用）
    private func touchInfo(_ ns: NSEvent) -> (count: Int, span: Float, desc: String) {
        let touches = ns.touches(matching: .touching, in: nil)
        var pts: [(Float, Float)] = []
        for t in touches {
            let p = t.normalizedPosition
            pts.append((Float(p.x), Float(p.y)))
        }
        var m: Float = 0
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let dx = pts[i].0 - pts[j].0
                let dy = pts[i].1 - pts[j].1
                m = max(m, (dx * dx + dy * dy).squareRoot())
            }
        }
        let desc = pts.prefix(5).map { String(format: "(%.2f,%.2f)", $0.0, $0.1) }.joined(separator: " ")
        return (pts.count, m, desc)
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        guard onTrigger != nil, let ns = NSEvent(cgEvent: event) else { return }
        let info = touchInfo(ns)
        switch type.rawValue {
        case Self.eventGestureStarted:
            accumulation = 0
            maxFingers = info.count
            isTracking = true
            updateSpanTracking(count: info.count, span: info.span)
        case Self.eventMagnify:
            if !isTracking {
                accumulation = 0
                maxFingers = 0
                isTracking = true
            }
            maxFingers = max(maxFingers, info.count)
            updateSpanTracking(count: info.count, span: info.span)
            let zoomField = CGEventField(rawValue: 113)
            let zoom = zoomField.map { event.getDoubleValueField($0) } ?? 0
            let mag = zoom != 0 ? zoom : Double(ns.magnification)
            accumulation += CGFloat(mag)
            let magnitude = abs(accumulation)
            let fingersOK = maxFingers == 0 || maxFingers >= 4
            if fingersOK, magnitude >= threshold, accumulation < 0, !tapFired {
                tapFired = true
                accumulation = 0
                fireTrigger("缩放阈值")
            }
        case Self.eventGestureEnded:
            updateSpanTracking(count: info.count, span: info.span)
        default:
            break
        }
    }

    /// 四指以上期间跟踪触点间距最大/最小值；收缩比例达标即判定捏合并触发。
    /// 每次「四指落下 → 全部抬起」只允许触发一次（tapFired 仅在新手势开始时重置），
    /// 避免同一次捏合内多次点火造成关闭后又重新打开。
    private func updateSpanTracking(count: Int, span: Float) {
        guard count >= 4 else {
            if count <= 1 { resetSpanTracking() } // 手指全部抬起：结束本次手势
            return
        }
        if !sawFourPlus { // 新一次四指手势：以当前间距为基线并重新武装
            sawFourPlus = true
            streamSpanMax = span
            streamSpanMin = span
            tapFired = false
        } else {
            streamSpanMax = max(streamSpanMax, span)
            streamSpanMin = min(streamSpanMin, span)
        }
        guard !tapFired, streamSpanMax > 0.02, streamSpanMax > streamSpanMin else { return }
        let ratio = streamSpanMin / streamSpanMax
        if ratio <= 1 - requiredShrink {
            tapFired = true
            pinLog("捏合触发(跨度) 收缩=\(String(format: "%.2f", ratio)) span=\(String(format: "%.3f", streamSpanMax))→\(String(format: "%.3f", streamSpanMin))")
            fireTrigger("跨度检测")
        }
    }

    private func resetSpanTracking() {
        sawFourPlus = false
        tapFired = false
        streamSpanMax = 0
        streamSpanMin = .greatestFiniteMagnitude
    }
}
