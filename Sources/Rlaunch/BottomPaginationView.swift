import Cocoa
import RlaunchCore

// MARK: - 单个页码按钮（自绘完美正圆，绝无裁剪变形）

private final class PageNumberButton: NSControl {
    let pageIndex: Int
    var isCurrent: Bool = false {
        didSet { if oldValue != isCurrent { needsDisplay = true } }
    }
    private var isHovered: Bool = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    var onSelect: ((Int) -> Void)?

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func updateAppearance() {
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onSelect?(pageIndex)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = isDarkMode

        let circleSide: CGFloat = 26
        let circleRect = NSRect(
            x: round((bounds.width - circleSide) / 2),
            y: round((bounds.height - circleSide) / 2),
            width: circleSide,
            height: circleSide
        )
        let circlePath = NSBezierPath(ovalIn: circleRect)

        if isCurrent {
            if dark {
                NSColor.white.withAlphaComponent(0.28).setFill()
                circlePath.fill()
                NSColor.white.withAlphaComponent(0.40).setStroke()
                circlePath.lineWidth = 0.5
                circlePath.stroke()
            } else {
                // 明亮模式：高反差纯黑胶囊，醒目清晰
                NSColor.labelColor.setFill()
                circlePath.fill()
            }
        } else if isHovered {
            let hoverBg = dark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.labelColor.withAlphaComponent(0.10)
            hoverBg.setFill()
            circlePath.fill()
        }

        // 绘制居中数字，杜绝任何截断
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: isCurrent ? .bold : .medium)
        let textColor: NSColor
        if isCurrent {
            textColor = .white
        } else if dark {
            textColor = isHovered ? .white : NSColor.white.withAlphaComponent(0.70)
        } else {
            textColor = isHovered ? .labelColor : NSColor.labelColor.withAlphaComponent(0.68)
        }

        let title = "\(pageIndex + 1)"
        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: pStyle
        ]
        let attrStr = NSAttributedString(string: title, attributes: attrs)
        let strSize = attrStr.size()
        let textRect = NSRect(
            x: circleRect.minX,
            y: round(circleRect.midY - strSize.height / 2),
            width: circleRect.width,
            height: strSize.height
        )
        attrStr.draw(in: textRect)
    }
}

// MARK: - 紧凑翻页箭头按钮

private final class PaginationArrowButton: NSButton {
    private var isHovered: Bool = false {
        didSet { if oldValue != isHovered { updateAppearance() } }
    }

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        isBordered = false
        focusRingType = .none
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 14
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        let dark = isDarkMode
        contentTintColor = dark ? .white : .labelColor
        if !isEnabled {
            alphaValue = 0.28
            layer?.backgroundColor = NSColor.clear.cgColor
        } else if isHovered {
            alphaValue = 1.0
            layer?.backgroundColor = dark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.labelColor.withAlphaComponent(0.09).cgColor
        } else {
            alphaValue = 0.85
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}

// MARK: - 底部分页条（居中胶囊、明暗自适应液态玻璃、条件显示左右箭头、点击直接切页）

final class BottomPaginationView: NSView {

    var onSelectPage: ((Int) -> Void)?
    var onPrevPage: (() -> Void)?
    var onNextPage: (() -> Void)?

    private(set) var currentPage: Int = 0
    private(set) var totalPages: Int = 1

    private let glassContainer: NSView
    private let tintLayer = NSView()
    private let contentHost: NSView
    private let prevButton = PaginationArrowButton(symbolName: "chevron.left", accessibilityLabel: L10n.t("上一页"))
    private let nextButton = PaginationArrowButton(symbolName: "chevron.right", accessibilityLabel: L10n.t("下一页"))
    private var pageButtons: [PageNumberButton] = []

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        // 创建液态玻璃容器，圆角设为 18（高 36 的完美胶囊）
        let (glass, host) = SystemGlass.makeContainer(cornerRadius: 18, material: .hudWindow)
        self.glassContainer = glass
        self.contentHost = host
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false

        glassContainer.wantsLayer = true
        glassContainer.layer?.masksToBounds = true
        glassContainer.layer?.cornerRadius = 18

        tintLayer.wantsLayer = true
        tintLayer.layer?.masksToBounds = true
        tintLayer.layer?.cornerRadius = 18

        addSubview(glassContainer)
        addSubview(tintLayer)
        addSubview(contentHost)

        prevButton.target = self
        prevButton.action = #selector(prevClicked)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)

        contentHost.addSubview(prevButton)
        contentHost.addSubview(nextButton)

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)

        rebuildPageButtons()
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let dark = isDarkMode
        if dark {
            glassContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
            glassContainer.layer?.borderWidth = 0.5
            tintLayer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor

            shadow = NSShadow()
            shadow?.shadowColor = NSColor.black.withAlphaComponent(0.30)
            shadow?.shadowOffset = NSSize(width: 0, height: -2)
            shadow?.shadowBlurRadius = 8
        } else {
            glassContainer.layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor
            glassContainer.layer?.borderWidth = 0.5
            tintLayer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor

            shadow = NSShadow()
            shadow?.shadowColor = NSColor.black.withAlphaComponent(0.10)
            shadow?.shadowOffset = NSSize(width: 0, height: -2)
            shadow?.shadowBlurRadius = 8
        }
        prevButton.updateAppearance()
        nextButton.updateAppearance()
        pageButtons.forEach { $0.updateAppearance() }
    }

    @objc private func prevClicked() {
        guard currentPage > 0 else { return }
        onPrevPage?()
    }

    @objc private func nextClicked() {
        guard currentPage < totalPages - 1 else { return }
        onNextPage?()
    }

    /// 更新当前页与总页数
    func setPage(_ page: Int, total: Int) {
        let safeTotal = max(total, 1)
        let safePage = min(max(page, 0), safeTotal - 1)
        let totalChanged = (safeTotal != totalPages)
        currentPage = safePage
        totalPages = safeTotal

        if totalChanged {
            rebuildPageButtons()
        } else {
            updatePageButtonStates()
        }

        updateArrowStates()
        needsLayout = true
    }

    private func updateArrowStates() {
        let showArrows = (totalPages > 5)
        prevButton.isHidden = !showArrows
        nextButton.isHidden = !showArrows
        prevButton.isEnabled = (currentPage > 0)
        nextButton.isEnabled = (currentPage < totalPages - 1)
    }

    private func rebuildPageButtons() {
        pageButtons.forEach { $0.removeFromSuperview() }
        pageButtons.removeAll()

        for i in 0..<totalPages {
            let btn = PageNumberButton(pageIndex: i)
            btn.isCurrent = (i == currentPage)
            btn.onSelect = { [weak self] pageIndex in
                self?.onSelectPage?(pageIndex)
            }
            pageButtons.append(btn)
            contentHost.addSubview(btn)
        }
        updateArrowStates()
    }

    private func updatePageButtonStates() {
        for (i, btn) in pageButtons.enumerated() {
            btn.isCurrent = (i == currentPage)
        }
    }

    /// 胶囊根据页数和是否展示箭头动态计算理想宽度（给足左右边缘半圆弧安全距离，杜绝裁剪）
    var preferredSize: NSSize {
        let itemSize: CGFloat = 28
        let gap: CGFloat = 4
        let showArrows = (totalPages > 5)
        let arrowW: CGFloat = showArrows ? 28 : 0
        let arrowGap: CGFloat = showArrows ? 5 : 0
        let sidePadding: CGFloat = 10

        let numbersW = CGFloat(totalPages) * itemSize + CGFloat(max(0, totalPages - 1)) * gap
        let totalW = (arrowW + arrowGap) * 2 + numbersW + sidePadding * 2
        return NSSize(width: max(totalW, 48), height: 36)
    }

    override func layout() {
        super.layout()
        glassContainer.frame = bounds
        tintLayer.frame = bounds
        contentHost.frame = bounds

        let showArrows = (totalPages > 5)
        let itemSize: CGFloat = 28
        let gap: CGFloat = 4
        let y = (bounds.height - itemSize) / 2
        var x: CGFloat = 10

        if showArrows {
            prevButton.frame = NSRect(x: x, y: y, width: itemSize, height: itemSize)
            x += itemSize + 5
        } else {
            prevButton.frame = .zero
        }

        for btn in pageButtons {
            btn.frame = NSRect(x: x, y: y, width: itemSize, height: itemSize)
            x += itemSize + gap
        }

        if showArrows {
            x = bounds.width - 10 - itemSize
            nextButton.frame = NSRect(x: x, y: y, width: itemSize, height: itemSize)
        } else {
            nextButton.frame = .zero
        }
    }

    func applyLanguage() {
        prevButton.setAccessibilityLabel(L10n.t("上一页"))
        nextButton.setAccessibilityLabel(L10n.t("下一页"))
    }
}
