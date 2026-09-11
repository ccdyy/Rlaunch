import Cocoa
import RlaunchCore

/// 允许有限越界的裁剪视图。
///
/// `NSClipView` 默认把 bounds 严格夹在文档范围内，越界位移会被静默丢弃；
/// 更麻烦的是**回弹动画也会因此失效**：起点在合法范围之外时，动画会被瞬间夹回终点，
/// 表现为"啪"地一下归位（实测轨迹全是终点值，根本没有过渡帧）。
/// 这里放开一个有界的越界区间，橡皮筋与回弹才能同时正常工作。
final class ElasticClipView: NSClipView {
    /// 允许的最大越界距离（应不小于橡皮筋上限）
    var overscrollLimit: CGFloat = 120

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard let documentView else { return proposedBounds }
        let maxX = max(0, documentView.frame.width - bounds.width)
        var adjusted = proposedBounds
        adjusted.origin.x = min(max(adjusted.origin.x, -overscrollLimit), maxX + overscrollLimit)
        return adjusted
    }
}

/// 横向分页滚动视图：拖动时 1:1 跟手，松手后吸附到最近整页。
final class SnapScrollView: NSScrollView {
    var onPageChanged: ((Int) -> Void)?
    var onEscape: (() -> Void)?
    /// 直接输入字符（Launchpad 手感）：由控制器转交给搜索框
    var onTextInput: ((String) -> Void)?
    /// ⌘F 聚焦搜索框
    var onFocusSearch: (() -> Void)?
    /// 回车：打开首个搜索结果
    var onConfirm: (() -> Void)?
    /// 方向键：参数为 (水平方向, 垂直方向)，用于键盘焦点导航
    var onMoveFocus: ((Int, Int) -> Void)?

    private(set) var pageCount = 1
    private(set) var currentPage = 0
    private var snapTimer: Timer?
    /// 触控板手势进行中（began…ended），避免误触发滚轮吸附定时器
    private var isTouchScrolling = false
    /// 本次手势起始页（吸附时最多翻一页，且降低翻页行程阈值）
    private var gestureAnchorPage = 0
    private var lastEventTime: TimeInterval = 0
    private var velocityX: CGFloat = 0

    /// 位移超过页宽此比例即可翻页（默认 18%，原先是 50%）
    private let flipDistanceThreshold: CGFloat = 0.18
    /// 快速轻扫时即使位移不大也翻页（pt/s）
    private let flipVelocityThreshold: CGFloat = 380

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        hasVerticalScroller = false
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        usesPredominantAxisScrolling = true

        let clip = ElasticClipView(frame: bounds)
        clip.autoresizingMask = [.width, .height]
        clip.overscrollLimit = maxOverscroll + 24
        contentView = clip
        clip.postsBoundsChangedNotifications = true
        // 必须在替换 contentView **之后**再关背景：
        // 新建的 NSClipView 默认 drawsBackground = true，会用 controlBackgroundColor
        // 铺满整块可视区，把窗口的玻璃背景整片盖住（表现为顶栏以下全黑）；
        // 而且赋值 contentView 还会把滚动视图自身的 drawsBackground 一并带回 true。
        clip.drawsBackground = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPageCount(_ count: Int) {
        pageCount = max(count, 1)
    }

    // MARK: 滚动与吸附

    override func scrollWheel(with event: NSEvent) {
        // 系统惯性不参与跟手滚动，仅在惯性结束时收敛吸附。
        // 注意要在清除动画之前返回，否则松手后紧跟着的惯性事件会把
        // 刚开始的吸附/回弹动画立刻打断，看起来像卡在越界位置不动。
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) { snap() }
            return
        }

        contentView.layer?.removeAllAnimations()
        snapTimer?.invalidate()

        if event.phase.contains(.began) {
            isTouchScrolling = true
            gestureAnchorPage = currentPage
            velocityX = 0
            lastEventTime = event.timestamp
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            isTouchScrolling = false
        }

        let dx = horizontalDelta(from: event)
        if dx != 0 {
            recordVelocity(delta: dx, timestamp: event.timestamp)
            scrollHorizontally(by: dx)
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            snap()
        } else if event.phase.isEmpty && !event.hasPreciseScrollingDeltas && !isTouchScrolling {
            gestureAnchorPage = currentPage
            // 仅鼠标滚轮（无 phase、非精确 delta）
            scheduleSnap(delay: 0.08)
        }
    }

    private func horizontalDelta(from event: NSEvent) -> CGFloat {
        let raw = event.scrollingDeltaX
        if event.hasPreciseScrollingDeltas { return raw * 1.12 }
        return raw * 14
    }

    private func recordVelocity(delta: CGFloat, timestamp: TimeInterval) {
        guard lastEventTime > 0 else {
            lastEventTime = timestamp
            return
        }
        let dt = timestamp - lastEventTime
        lastEventTime = timestamp
        guard dt > 0.0005 else { return }
        // scrollHorizontally 里 origin -= delta，故 origin 速度 = -delta / dt
        let instant = -delta / CGFloat(dt)
        velocityX = velocityX * 0.55 + instant * 0.45
    }

    /// 到达首/尾页后继续拖动时的最大弹性位移
    private let maxOverscroll: CGFloat = 96
    /// 未阻尼的原始滚动位置（手指总位移），仅在 [0, maxX] 之外才做橡胶筋压缩
    private var rawOriginX: CGFloat = 0
    private var isRawTracking = false

    /// AppKit 惯例：bounds.origin 与 scrollingDelta 反向（减 delta 才是跟手方向）。
    /// 超出首/尾页边界后不硬停，而是按渐近阻尼继续位移，松手再弹回，形成橡皮筋手感。
    private func scrollHorizontally(by delta: CGFloat) {
        let pageW = max(contentView.bounds.width, 1)
        let maxX = CGFloat(max(pageCount - 1, 0)) * pageW
        if !isRawTracking {
            // 以当前所在的有效位置为起点，避免从回弹动画中途接续时产生跳变
            rawOriginX = min(max(contentView.bounds.origin.x, 0), maxX)
            isRawTracking = true
        }
        rawOriginX -= delta
        let displayed = ElasticScroll.displayedOrigin(raw: rawOriginX, maxX: maxX, limit: maxOverscroll)
        contentView.setBoundsOrigin(NSPoint(x: displayed, y: 0))
    }

    private func scheduleSnap(delay: TimeInterval) {
        snapTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.snap()
        }
        RunLoop.main.add(timer, forMode: .common)
        snapTimer = timer
    }

    func snap() {
        snapTimer?.invalidate()
        isRawTracking = false
        scrollToPage(snapTargetPage(), animated: true)
    }

    /// 根据位移 + 速度决定吸附页：轻滑/快扫都能翻页，单次手势最多翻一页。
    private func snapTargetPage() -> Int {
        let pageW = max(contentView.bounds.width, 1)
        let x = contentView.bounds.origin.x
        let maxP = pageCount - 1
        let anchorX = CGFloat(gestureAnchorPage) * pageW
        let dragFraction = (x - anchorX) / pageW

        if dragFraction >= flipDistanceThreshold || velocityX > flipVelocityThreshold {
            return min(gestureAnchorPage + 1, maxP)
        }
        if dragFraction <= -flipDistanceThreshold || velocityX < -flipVelocityThreshold {
            return max(gestureAnchorPage - 1, 0)
        }
        return gestureAnchorPage
    }

    func scrollToPage(_ page: Int, animated: Bool) {
        let clamped = min(max(page, 0), pageCount - 1)
        let pageW = max(contentView.bounds.width, 1)
        let targetX = CGFloat(clamped) * pageW
        let currentX = contentView.bounds.origin.x
        isRawTracking = false
        if currentPage != clamped {
            currentPage = clamped
            onPageChanged?(clamped)
        }
        guard abs(currentX - targetX) > 0.5 else { return }

        let maxX = CGFloat(max(pageCount - 1, 0)) * pageW
        let isBouncingBack = currentX < -0.5 || currentX > maxX + 0.5

        guard animated else {
            contentView.setBoundsOrigin(NSPoint(x: targetX, y: 0))
            return
        }

        guard isBouncingBack else {
            // 普通翻页：轻快吸附
            animateOrigin(to: targetX, duration: 0.15, timing: CAMediaTimingFunction(name: .easeOut))
            return
        }

        settleToEdge(from: currentX, to: targetX)
    }

    /// 越界回弹：**一次到位**地靠边停住。
    ///
    /// 曾经做过"回弹 → 冲过边界 → 再落定"的两段弹簧，但那一来会越过边缘再弹一下，
    /// 观感是松散地弹两次；这里改成单段：起始速度最大，随后平滑衰减到 0，正好停在边界上。
    /// 时长随越界距离小幅增长，短距离不会拖沓，长距离也不会显得急促。
    private func settleToEdge(from currentX: CGFloat, to targetX: CGFloat) {
        let distance = abs(currentX - targetX)
        let duration = 0.34 + min(0.20, distance / 500)
        // 缓出曲线：起步即最快，末尾速度为 0（速度逐渐变小、贴边停住）
        animateOrigin(to: targetX,
                      duration: duration,
                      timing: CAMediaTimingFunction(controlPoints: 0.22, 0.68, 0.32, 1.0)) { [weak self] in
            self?.syncCurrentPage()
        }
    }

    private func animateOrigin(to x: CGFloat,
                               duration: TimeInterval,
                               timing: CAMediaTimingFunction,
                               completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
        } completionHandler: {
            completion?()
        }
    }

    private func syncCurrentPage() {
        let actual = nearestPage()
        if currentPage != actual {
            currentPage = actual
            onPageChanged?(actual)
        }
    }

    private func nearestPage() -> Int {
        let pageW = max(contentView.bounds.width, 1)
        return min(max(Int((contentView.bounds.origin.x + pageW / 2) / pageW), 0), pageCount - 1)
    }

    // MARK: 键盘翻页

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // ⌘F：聚焦搜索框
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFocusSearch?()
            return
        }
        switch event.keyCode {
        case 123: onMoveFocus?(-1, 0)                           // ←
        case 124: onMoveFocus?(1, 0)                            // →
        case 125: onMoveFocus?(0, 1)                            // ↓
        case 126: onMoveFocus?(0, -1)                           // ↑
        case 116: scrollToPage(currentPage - 1, animated: true) // PageUp
        case 121: scrollToPage(currentPage + 1, animated: true) // PageDown
        case 115: scrollToPage(0, animated: true)               // Home
        case 119: scrollToPage(pageCount - 1, animated: true)   // End
        case 53: onEscape?()                                    // Esc
        case 36, 76: onConfirm?()                               // ↩ / 小键盘 Enter
        default:
            // 直接输入可打印字符即开始搜索（无需先点击搜索框）
            let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
            if event.modifierFlags.intersection(disallowed).isEmpty,
               let chars = event.characters, !chars.isEmpty,
               chars.rangeOfCharacter(from: .controlCharacters) == nil {
                onTextInput?(chars)
                return
            }
            super.keyDown(with: event)
        }
    }
}
