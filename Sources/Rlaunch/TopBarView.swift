import Cocoa

// MARK: - 三色圆点按钮（红=隐藏、黄=最小化、绿=全屏）
// 鼠标悬停时整组按钮显示对应符号（关闭 × / 缩小 − / 全屏 ⤢），
// 单个按钮悬停时颜色加深，与 macOS 原生红绿灯一致。

final class TrafficLightsView: NSView {
    var onRed: (() -> Void)?
    var onYellow: (() -> Void)?
    var onGreen: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let redDot = TrafficDotButton(color: NSColor(red: 1.0, green: 0.373, blue: 0.341, alpha: 1.0), glyph: "xmark")
    private let yellowDot = TrafficDotButton(color: NSColor(red: 0.996, green: 0.745, blue: 0.18, alpha: 1.0), glyph: "minus")
    private let greenDot = TrafficDotButton(color: NSColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1.0), glyph: "arrow.up.left.and.arrow.down.right")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        redDot.target = self
        redDot.action = #selector(redClicked)
        yellowDot.target = self
        yellowDot.action = #selector(yellowClicked)
        greenDot.target = self
        greenDot.action = #selector(greenClicked)

        // 辅助功能标签：VoiceOver 可朗读三色按钮
        redDot.setAccessibilityLabel("隐藏 Rlaunch")
        yellowDot.setAccessibilityLabel("最小化窗口")
        greenDot.setAccessibilityLabel("切换全屏")

        for d in [redDot, yellowDot, greenDot] {
            addSubview(d)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func redClicked() { onRed?() }
    @objc private func yellowClicked() { onYellow?() }
    @objc private func greenClicked() { onGreen?() }

    override func mouseDown(with event: NSEvent) {
        // 阻止点击空白缝隙处冒泡导致窗口误拖动
    }

    override func layout() {
        super.layout()
        let btnW: CGFloat = 18
        let btnH: CGFloat = 28
        let gap: CGFloat = 4
        let y = (bounds.height - btnH) / 2
        var x: CGFloat = 0
        for d in [redDot, yellowDot, greenDot] {
            d.frame = NSRect(x: x, y: y, width: btnW, height: btnH)
            x += btnW + gap
        }
    }

    // 整组悬停：三个按钮同时显示符号（macOS 原生行为）
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        for d in [redDot, yellowDot, greenDot] { d.showsGlyph = true }
    }

    override func mouseExited(with event: NSEvent) {
        for d in [redDot, yellowDot, greenDot] { d.showsGlyph = false }
    }
}

private final class TrafficDotButton: NSButton {
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    var showsGlyph = false {
        didSet { if showsGlyph != oldValue { needsDisplay = true } }
    }
    private let baseColor: NSColor
    private let glyph: String

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(color: NSColor, glyph: String) {
        self.baseColor = color
        self.glyph = glyph
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = nil
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dotSize: CGFloat = 12
        let dotRect = NSRect(
            x: (bounds.width - dotSize) / 2,
            y: (bounds.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        let isDown = cell?.isHighlighted == true
        let color = isDown
            ? (baseColor.blended(withFraction: 0.35, of: .black) ?? baseColor)
            : (hovered ? (baseColor.blended(withFraction: 0.2, of: .black) ?? baseColor) : baseColor)
        color.setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5)).fill()

        if showsGlyph, let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) {
            let tinted = symbol.tinted(with: NSColor.black.withAlphaComponent(0.65))
            let size = tinted.size
            tinted.draw(in: NSRect(x: dotRect.minX + (dotSize - size.width) / 2,
                                   y: dotRect.minY + (dotSize - size.height) / 2,
                                   width: size.width, height: size.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }
}

private extension NSImage {
    /// 返回按指定颜色着色的副本（用于在圆点上绘制深色符号）
    func tinted(with color: NSColor) -> NSImage {
        guard let copy = self.copy() as? NSImage else { return self }
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}

// MARK: - 搜索框（修复放大镜图标被拉伸：固定搜索按钮尺寸、等比例符号图）

final class SearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { SearchFieldCell.self }
        set { }
    }
}

final class SearchFieldCell: NSSearchFieldCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // 去掉系统默认放大镜（其图像会随控件高度拉伸），由 drawInterior 自绘
        if let button = searchButtonCell {
            button.image = nil
            button.isTransparent = true
            button.isBordered = false
        }
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchButtonRect(forBounds: rect)
        r.size = NSSize(width: 18, height: 18)
        r.origin.y = rect.midY - 9
        return r
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)
        // 自绘放大镜：固定 15pt 符号图、等比、不可拉伸
        guard let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)) else { return }
        let rect = searchButtonRect(forBounds: cellFrame).insetBy(dx: 1, dy: 1)
        NSColor.secondaryLabelColor.set()
        image.draw(in: rect)
    }
}

// MARK: - 页码标签（点击左右翻页）

final class PageLabel: NSTextField {
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        textColor = .labelColor
        alignment = .center
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.x < bounds.width / 2 { onPrev?() } else { onNext?() }
    }
}

// MARK: - 符号按钮（悬停高亮）

final class SymbolButton: NSButton {
    private var hovered = false

    init(symbol: String, size: CGFloat = 15) {
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = .clear
    }
}

// MARK: - 顶栏（三色按钮 | 搜索 | 页码 刷新 全屏 设置）

final class TopBarView: NSView, NSSearchFieldDelegate {
    var onRed: (() -> Void)?
    var onYellow: (() -> Void)?
    var onGreen: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?
    /// 搜索框内回车：打开首个结果
    var onSearchSubmit: (() -> Void)?
    var onPrevPage: (() -> Void)?
    var onNextPage: (() -> Void)?
    var onSettings: (() -> Void)?
    var onRefresh: (() -> Void)?

    let traffic = TrafficLightsView()
    let searchField = SearchField()
    let pageLabel = PageLabel()
    let refreshButton = SymbolButton(symbol: "arrow.clockwise")
    let fullscreenButton = SymbolButton(symbol: "arrow.up.left.and.arrow.down.right")
    let settingsButton = SymbolButton(symbol: "gearshape")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        searchField.placeholderString = "搜索应用…"
        searchField.font = .systemFont(ofSize: 13)
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("搜索应用")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        // 用 textDidChange 通知兜底：action 在中文输入法等场景可能不触发
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSControl.textDidChangeNotification, object: searchField)
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 9
        addSubview(searchField)

        pageLabel.stringValue = "1 / 1"
        pageLabel.onPrev = { [weak self] in self?.onPrevPage?() }
        pageLabel.onNext = { [weak self] in self?.onNextPage?() }
        addSubview(pageLabel)

        fullscreenButton.toolTip = "全屏 / 退出全屏"
        fullscreenButton.target = self
        fullscreenButton.action = #selector(greenClicked)
        addSubview(fullscreenButton)

        refreshButton.toolTip = "重新扫描应用"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        addSubview(refreshButton)

        settingsButton.toolTip = "设置"
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        addSubview(settingsButton)

        addSubview(traffic)
        traffic.onRed = { [weak self] in self?.onRed?() }
        traffic.onYellow = { [weak self] in self?.onYellow?() }
        traffic.onGreen = { [weak self] in self?.onGreen?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textDidChange(_ notification: Notification) {
        emitSearch(searchField.stringValue)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        emitSearch(sender.stringValue)
    }

    /// `sendsSearchStringImmediately` 下 action 与 textDidChange 会同时触发，
    /// 这里按值去重，避免每次按键重复全量刷新网格。
    private var lastEmittedQuery: String?

    private func emitSearch(_ query: String) {
        guard query != lastEmittedQuery else { return }
        lastEmittedQuery = query
        onSearchChanged?(query)
    }

    /// 回车提交搜索（`sendsSearchStringImmediately` 下 action 无法区分回车与输入，故用命令拦截）
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSearchSubmit?()
            return true
        }
        return false
    }

    @objc private func greenClicked() { onGreen?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func refreshClicked() { onRefresh?() }

    func setPage(_ page: Int, of total: Int) {
        pageLabel.stringValue = "\(page + 1) / \(max(total, 1))"
    }

    /// 程序化清空搜索框：同时重置去重缓存，否则下次输入相同关键词会被误判为重复而不触发搜索
    func clearSearchField() {
        searchField.stringValue = ""
        lastEmittedQuery = nil
    }

    private(set) var isFullscreen: Bool = false
    private var dragStartLoc: NSPoint?
    private var longPressTimer: Timer?
    private var isDraggingWindow = false

    func setFullscreen(_ isFullscreen: Bool) {
        self.isFullscreen = isFullscreen
        fullscreenButton.image = NSImage(
            systemSymbolName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !isFullscreen, window != nil else { return }
        dragStartLoc = event.locationInWindow
        isDraggingWindow = false
        longPressTimer?.invalidate()

        let timer = Timer(timeInterval: 0.22, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isDraggingWindow = true
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFullscreen, let window = self.window, let start = dragStartLoc else { return }
        let current = event.locationInWindow
        if isDraggingWindow || hypot(current.x - start.x, current.y - start.y) > 6 {
            longPressTimer?.invalidate()
            longPressTimer = nil
            isDraggingWindow = false
            dragStartLoc = nil
            window.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        isDraggingWindow = false
        dragStartLoc = nil
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let gap: CGFloat = 10
        let sideInset: CGFloat = 16
        let buttonSize: CGFloat = 36

        traffic.frame = NSRect(x: sideInset, y: 0, width: 62, height: h)

        // 右侧图标与页码从右边缘依次向左排布，避免窄窗口下与搜索框重叠
        var rightX = bounds.width - sideInset
        let buttonY = (h - 30) / 2
        settingsButton.frame = NSRect(x: rightX - buttonSize, y: buttonY, width: buttonSize, height: 30)
        rightX -= buttonSize + gap
        fullscreenButton.frame = NSRect(x: rightX - buttonSize, y: buttonY, width: buttonSize, height: 30)
        rightX -= buttonSize + gap
        refreshButton.frame = NSRect(x: rightX - buttonSize, y: buttonY, width: buttonSize, height: 30)
        rightX -= buttonSize + gap

        pageLabel.sizeToFit()
        let pageW = max(pageLabel.frame.width, 44)
        pageLabel.frame = NSRect(x: rightX - pageW, y: (h - pageLabel.frame.height) / 2,
                                 width: pageW, height: pageLabel.frame.height)
        rightX -= pageW

        // 搜索框在「三色按钮」与「页码」之间的可用区间内居中，并留出至少 12pt 间距
        let minX = traffic.frame.maxX + 16
        let available = max(120, rightX - 12 - minX)
        let searchWidth = min(460, available)
        let searchX = minX + (available - searchWidth) / 2
        searchField.frame = NSRect(x: searchX, y: (h - 30) / 2, width: searchWidth, height: 30)
    }
}
