import Cocoa

// MARK: - 三色圆点按钮（红=隐藏、黄=最小化、绿=全屏）

final class TrafficLightsView: NSView {
    var onRed: (() -> Void)?
    var onYellow: (() -> Void)?
    var onGreen: (() -> Void)?

    private let redDot = DotButton(color: NSColor(red: 1.0, green: 0.373, blue: 0.341, alpha: 1.0))
    private let yellowDot = DotButton(color: NSColor(red: 0.996, green: 0.745, blue: 0.18, alpha: 1.0))
    private let greenDot = DotButton(color: NSColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1.0))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        redDot.onClick = { [weak self] in self?.onRed?() }
        yellowDot.onClick = { [weak self] in self?.onYellow?() }
        greenDot.onClick = { [weak self] in self?.onGreen?() }
        for d in [redDot, yellowDot, greenDot] {
            d.wantsLayer = true
            d.layer?.cornerRadius = 6
            addSubview(d)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size: CGFloat = 12
        let gap: CGFloat = 8
        let y = (bounds.height - size) / 2
        var x: CGFloat = 0
        for d in [redDot, yellowDot, greenDot] {
            d.frame = NSRect(x: x, y: y, width: size, height: size)
            x += size + gap
        }
    }
}

private final class DotButton: NSView {
    var onClick: (() -> Void)?
    private var hovered = false

    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.opacity = 0.6
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.opacity = 1.0
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

// MARK: - 顶栏（三色按钮 | 文件夹返回 | 搜索 | 页码 全屏 设置）

final class TopBarView: NSView {
    var onRed: (() -> Void)?
    var onYellow: (() -> Void)?
    var onGreen: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onPrevPage: (() -> Void)?
    var onNextPage: (() -> Void)?
    var onSettings: (() -> Void)?
    var onBackToMain: (() -> Void)?

    let traffic = TrafficLightsView()
    let searchField = NSSearchField()
    let pageLabel = PageLabel()
    let fullscreenButton = SymbolButton(symbol: "arrow.up.left.and.arrow.down.right")
    let settingsButton = SymbolButton(symbol: "gearshape")
    let folderLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        searchField.placeholderString = "搜索应用…"
        searchField.font = .systemFont(ofSize: 13)
        searchField.controlSize = .large
        searchField.sendsSearchStringImmediately = true
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

        settingsButton.toolTip = "设置"
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        addSubview(settingsButton)

        folderLabel.font = .systemFont(ofSize: 13, weight: .medium)
        folderLabel.textColor = .labelColor
        folderLabel.isHidden = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(backClicked))
        folderLabel.addGestureRecognizer(click)
        addSubview(folderLabel)

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
        onSearchChanged?(searchField.stringValue)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        onSearchChanged?(sender.stringValue)
    }

    @objc private func greenClicked() { onGreen?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func backClicked() { onBackToMain?() }

    func setFolderMode(name: String?) {
        if let name {
            folderLabel.stringValue = "← \(name)"
            folderLabel.isHidden = false
        } else {
            folderLabel.isHidden = true
        }
    }

    func setPage(_ page: Int, of total: Int) {
        pageLabel.stringValue = "\(page + 1) / \(max(total, 1))"
    }

    func setFullscreen(_ isFullscreen: Bool) {
        fullscreenButton.image = NSImage(
            systemSymbolName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let gap: CGFloat = 10

        traffic.frame = NSRect(x: 18, y: 0, width: 12 * 3 + 8 * 2, height: h)

        if !folderLabel.isHidden {
            let size = folderLabel.sizeThatFits(NSSize(width: 220, height: h))
            folderLabel.frame = NSRect(x: traffic.frame.maxX + 24, y: (h - size.height) / 2,
                                       width: size.width + 4, height: size.height)
        }

        let searchWidth = min(460, bounds.width - 380)
        searchField.frame = NSRect(x: (bounds.width - searchWidth) / 2, y: (h - 30) / 2,
                                   width: searchWidth, height: 30)

        pageLabel.sizeToFit()
        let pageW = max(pageLabel.frame.width, 48)
        pageLabel.frame = NSRect(x: bounds.width - 18 - 36 - gap - 36 - gap - pageW,
                                 y: (h - pageLabel.frame.height) / 2,
                                 width: pageW, height: pageLabel.frame.height)

        settingsButton.frame = NSRect(x: bounds.width - 18 - 36, y: (h - 30) / 2, width: 36, height: 30)
        fullscreenButton.frame = NSRect(x: bounds.width - 18 - 36 - gap - 36, y: (h - 30) / 2, width: 36, height: 30)
    }
}
