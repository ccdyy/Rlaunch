import Cocoa
import RlaunchCore

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

        applyLanguage()

        for d in [redDot, yellowDot, greenDot] {
            addSubview(d)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func redClicked() { onRed?() }
    @objc private func yellowClicked() { onYellow?() }
    @objc private func greenClicked() { onGreen?() }

    /// 刷新三色按钮的辅助功能标签
    func applyLanguage() {
        redDot.setAccessibilityLabel(L10n.t("隐藏 Rlaunch"))
        yellowDot.setAccessibilityLabel(L10n.t("最小化窗口"))
        greenDot.setAccessibilityLabel(L10n.t("切换全屏"))
    }

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

// MARK: - 搜索框（等比正圆放大镜、完美明暗自适应、文本居中对齐）

final class SearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { SearchFieldCell.self }
        set { }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configure() {
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        sendsSearchStringImmediately = true
        applyPlaceholder()

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)
    }

    @objc private func themeDidChange() {
        updateThemeAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeAppearance()
    }

    func updateThemeAppearance() {
        textColor = .labelColor
        applyPlaceholder()
        needsDisplay = true
    }

    func applyPlaceholder() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let placeholderColor = isDark
            ? NSColor.white.withAlphaComponent(0.48)
            : NSColor.black.withAlphaComponent(0.45)

        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .left
        placeholderAttributedString = NSAttributedString(
            string: L10n.t("搜索应用…"),
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: placeholderColor,
                .paragraphStyle: pStyle
            ]
        )
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
        // 去掉系统默认拉伸放大镜，由 drawInterior 等比自绘
        if let button = searchButtonCell {
            button.image = nil
            button.isTransparent = true
            button.isBordered = false
        }
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchButtonRect(forBounds: rect)
        r.size = NSSize(width: 16, height: 16)
        r.origin.x = rect.minX + 8
        r.origin.y = round(rect.midY - 8)
        return r
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.cancelButtonRect(forBounds: rect)
        r.origin.y = round(rect.midY - r.height / 2)
        return r
    }

    private func adjustedTextRect(forBounds rect: NSRect) -> NSRect {
        let btnRect = searchButtonRect(forBounds: rect)
        let cancelRect = cancelButtonRect(forBounds: rect)
        let left = btnRect.maxX + 8
        let right = cancelRect.width > 0 ? (cancelRect.minX - 4) : (rect.maxX - 8)
        let width = max(0, right - left)

        let font = self.font ?? NSFont.systemFont(ofSize: 13)
        let textHeight = ceil(font.ascender - font.descender + 2)
        let y = round(rect.midY - textHeight / 2)
        return NSRect(x: left, y: y, width: width, height: textHeight)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        return adjustedTextRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        return adjustedTextRect(forBounds: rect)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjustedTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: adjustedTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)

        // 明亮与深色模式精准色彩对比
        let isDark = controlView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tintColor = isDark
            ? NSColor.white.withAlphaComponent(0.68)
            : NSColor.black.withAlphaComponent(0.55)

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [tintColor]))

        guard let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L10n.t("搜索"))?
            .withSymbolConfiguration(config) else { return }

        let btnRect = searchButtonRect(forBounds: cellFrame)
        let symSize = symbol.size
        guard symSize.width > 0, symSize.height > 0 else { return }

        // 等比缩放居中于 14×14 区域，使用原生 draw 保持朝向完全正确
        let targetSide: CGFloat = 13.5
        let scale = min(targetSide / symSize.width, targetSide / symSize.height)
        let drawW = round(symSize.width * scale)
        let drawH = round(symSize.height * scale)
        let drawRect = NSRect(
            x: round(btnRect.midX - drawW / 2),
            y: round(btnRect.midY - drawH / 2),
            width: drawW,
            height: drawH
        )

        symbol.draw(in: drawRect)
    }
}

// MARK: - 液态玻璃搜索框容器（明暗自适应高光边框、系统毛玻璃/Liquid Glass、柔和阴影、胶囊圆角）

final class GlassSearchContainerView: NSView {
    let searchField: SearchField
    private let glassContainer: NSView
    private let tintLayer = NSView()
    private let contentHost: NSView

    var isFocused: Bool = false {
        didSet { updateAppearance() }
    }

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(searchField: SearchField) {
        self.searchField = searchField
        let (glass, host) = SystemGlass.makeContainer(cornerRadius: 17, material: .hudWindow)
        self.glassContainer = glass
        self.contentHost = host
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false

        glassContainer.wantsLayer = true
        glassContainer.layer?.masksToBounds = true
        glassContainer.layer?.cornerRadius = 17

        tintLayer.wantsLayer = true
        tintLayer.layer?.masksToBounds = true
        tintLayer.layer?.cornerRadius = 17

        addSubview(glassContainer)
        addSubview(tintLayer)
        addSubview(contentHost)
        contentHost.addSubview(searchField)

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)
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

    func updateAppearance() {
        let dark = isDarkMode
        if dark {
            glassContainer.layer?.borderColor = isFocused
                ? NSColor.white.withAlphaComponent(0.60).cgColor
                : NSColor.white.withAlphaComponent(0.24).cgColor
            glassContainer.layer?.borderWidth = isFocused ? 1.0 : 0.5
            tintLayer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor

            shadow = NSShadow()
            shadow?.shadowColor = NSColor.black.withAlphaComponent(0.30)
            shadow?.shadowOffset = NSSize(width: 0, height: -2)
            shadow?.shadowBlurRadius = 8
        } else {
            // 明亮模式：清晰微黑描边 + 纯净浅色磨砂底，避免在白色或复杂壁纸上隐形
            glassContainer.layer?.borderColor = isFocused
                ? NSColor.black.withAlphaComponent(0.40).cgColor
                : NSColor.black.withAlphaComponent(0.16).cgColor
            glassContainer.layer?.borderWidth = isFocused ? 1.0 : 0.5
            tintLayer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor

            shadow = NSShadow()
            shadow?.shadowColor = NSColor.black.withAlphaComponent(0.10)
            shadow?.shadowOffset = NSSize(width: 0, height: -2)
            shadow?.shadowBlurRadius = 8
        }
    }

    override func layout() {
        super.layout()
        glassContainer.frame = bounds
        tintLayer.frame = bounds
        contentHost.frame = bounds

        let fieldH: CGFloat = 28
        let fieldY = round((bounds.height - fieldH) / 2)
        searchField.frame = NSRect(
            x: 4,
            y: fieldY,
            width: max(0, bounds.width - 8),
            height: fieldH
        )
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

// MARK: - 顶栏（三色按钮 | 居中液态玻璃搜索栏 | 刷新 全屏 设置）

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
    private(set) var searchContainer: GlassSearchContainerView!
    let refreshButton = SymbolButton(symbol: "arrow.clockwise")
    let fullscreenButton = SymbolButton(symbol: "arrow.up.left.and.arrow.down.right")
    let settingsButton = SymbolButton(symbol: "gearshape")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        searchField.applyPlaceholder()
        searchField.setAccessibilityLabel(L10n.t("搜索应用"))
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        // 用 textDidChange 通知兜底：action 在中文输入法等场景可能不触发
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSControl.textDidChangeNotification, object: searchField)

        searchContainer = GlassSearchContainerView(searchField: searchField)
        addSubview(searchContainer)

        fullscreenButton.toolTip = L10n.t("全屏 / 退出全屏")
        fullscreenButton.target = self
        fullscreenButton.action = #selector(greenClicked)
        addSubview(fullscreenButton)

        refreshButton.toolTip = L10n.t("重新扫描应用")
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        addSubview(refreshButton)

        settingsButton.toolTip = L10n.t("设置")
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

    func controlTextDidBeginEditing(_ obj: Notification) {
        searchContainer?.isFocused = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        searchContainer?.isFocused = false
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
        // 页码指示已迁移至底部分页条，保留兼容接口
    }

    /// 应用（或切换）界面语言：刷新占位符、提示与辅助功能标签
    func applyLanguage() {
        searchField.applyPlaceholder()
        searchField.setAccessibilityLabel(L10n.t("搜索应用"))
        fullscreenButton.toolTip = L10n.t("全屏 / 退出全屏")
        refreshButton.toolTip = L10n.t("重新扫描应用")
        settingsButton.toolTip = L10n.t("设置")
        traffic.applyLanguage()
        needsLayout = true
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

        // 右侧操作图标从右边缘依次向左排布（已移除顶部右侧分页）
        var rightX = bounds.width - sideInset
        let buttonY = (h - 30) / 2
        settingsButton.frame = NSRect(x: rightX - buttonSize, y: buttonY, width: buttonSize, height: 30)
        rightX -= buttonSize + gap
        fullscreenButton.frame = NSRect(x: rightX - buttonSize, y: buttonY, width: buttonSize, height: 30)
        rightX -= buttonSize + gap
        refreshButton.frame = NSRect(x: rightX - buttonSize, y: buttonY, width: buttonSize, height: 30)
        rightX -= buttonSize + gap

        // 搜索栏正居中：中心严格对齐 bounds.width / 2，不受左右侧按钮数量或宽度不对称的影响
        let leftOccupied = traffic.frame.maxX + 16
        let rightOccupied = bounds.width - rightX + 16
        let maxSideOccupied = max(leftOccupied, rightOccupied)

        let maxAllowedWidth = max(140, bounds.width - 2 * maxSideOccupied)
        let searchWidth = min(400, maxAllowedWidth)
        let searchX = (bounds.width - searchWidth) / 2
        let searchH: CGFloat = 34
        searchContainer.frame = NSRect(x: searchX, y: (h - searchH) / 2, width: searchWidth, height: searchH)
    }
}
