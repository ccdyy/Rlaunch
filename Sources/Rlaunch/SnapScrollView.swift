import Cocoa

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
        contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPageCount(_ count: Int) {
        pageCount = max(count, 1)
    }

    // MARK: 滚动与吸附

    override func scrollWheel(with event: NSEvent) {
        contentView.layer?.removeAllAnimations()
        snapTimer?.invalidate()

        // 系统惯性不参与跟手滚动，仅在惯性结束时收敛吸附
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) { snap() }
            return
        }

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

    /// AppKit 惯例：bounds.origin 与 scrollingDelta 反向（减 delta 才是跟手方向）
    private func scrollHorizontally(by delta: CGFloat) {
        let pageW = max(contentView.bounds.width, 1)
        let maxX = CGFloat(max(pageCount - 1, 0)) * pageW
        var x = contentView.bounds.origin.x - delta
        x = min(max(x, 0), maxX)
        contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
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
        let targetX = CGFloat(clamped) * max(contentView.bounds.width, 1)
        let currentX = contentView.bounds.origin.x
        if currentPage != clamped {
            currentPage = clamped
            onPageChanged?(clamped)
        }
        guard abs(currentX - targetX) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
            } completionHandler: { [weak self] in
                guard let self else { return }
                let actual = self.nearestPage()
                if self.currentPage != actual {
                    self.currentPage = actual
                    self.onPageChanged?(actual)
                }
            }
        } else {
            contentView.setBoundsOrigin(NSPoint(x: targetX, y: 0))
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
