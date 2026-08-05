import Cocoa

/// 横向分页滚动视图：滚动停止后自动吸附到最近的整页（page snapping）。
final class SnapScrollView: NSScrollView {
    var onPageChanged: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    private(set) var pageCount = 1
    private(set) var currentPage = 0
    private var snapTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .none
        hasVerticalScroller = false
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPageCount(_ count: Int) {
        pageCount = max(count, 1)
    }

    // MARK: 滚动与吸附

    override func scrollWheel(with event: NSEvent) {
        // 打断进行中的吸附动画
        contentView.layer?.removeAllAnimations()
        super.scrollWheel(with: event)

        if event.momentumPhase.contains(.ended) {
            // 触控板惯性滚动结束：立即吸附
            snapTimer?.invalidate()
            snap()
            return
        }
        if !event.momentumPhase.isEmpty {
            // 惯性进行中：等惯性结束再吸附
            snapTimer?.invalidate()
            return
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            // 手指抬起：极短延迟确认无惯性后吸附（若有惯性，momentum 事件会接管并取消定时器）
            scheduleSnap(delay: 0.03)
            return
        }
        // 触控板手指拖动中不吸附；鼠标滚轮无 phase 事件，用短定时器兜底
        guard event.phase.isEmpty else { return }
        scheduleSnap(delay: 0.08)
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
        let pageW = max(contentView.bounds.width, 1)
        let target = Int((contentView.bounds.origin.x + pageW / 2) / pageW)
        scrollToPage(target, animated: true)
    }

    func scrollToPage(_ page: Int, animated: Bool) {
        let clamped = min(max(page, 0), pageCount - 1)
        let targetX = CGFloat(clamped) * max(contentView.bounds.width, 1)
        let currentX = contentView.bounds.origin.x
        // 乐观更新页码：动画期间连按翻页不丢页
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
                // 动画被滚动打断时也收敛到实际所在页
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
        switch event.keyCode {
        case 123: scrollToPage(currentPage - 1, animated: true) // ←
        case 124: scrollToPage(currentPage + 1, animated: true) // →
        case 116: scrollToPage(currentPage - 1, animated: true) // PageUp
        case 121: scrollToPage(currentPage + 1, animated: true) // PageDown
        case 115: scrollToPage(0, animated: true)               // Home
        case 119: scrollToPage(pageCount - 1, animated: true)   // End
        case 53: onEscape?()                                    // Esc
        default: super.keyDown(with: event)
        }
    }
}
