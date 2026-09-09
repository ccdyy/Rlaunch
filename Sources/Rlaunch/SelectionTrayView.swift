import Cocoa
import RlaunchCore

// MARK: - 中转站内的应用图标单元（正常展示图标，非圆形框，悬停右上角显示删除标）

final class TrayAppIconView: NSView {
    let app: AppInfo
    var onRemove: (() -> Void)?

    private let iconView = NSImageView()
    private let deleteBadge = NSView()
    private let deleteLabel = NSTextField(labelWithString: "✕")

    init(app: AppInfo, size: CGFloat = 44) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))

        wantsLayer = true

        // 正常展示应用图标：自然渲染应用本身的精美图标（macOS 原生圆角矩形/自带外观），绝不强加圆形框截断
        iconView.image = IconCache.shared.icon(for: app.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = bounds
        addSubview(iconView)

        toolTip = "\(app.name)\n点击移除出中转站"

        // 右上角微型删除角标（16x16，悬停时显示）
        let badgeSize: CGFloat = 16
        deleteBadge.frame = NSRect(x: size - badgeSize + 2, y: size - badgeSize + 2, width: badgeSize, height: badgeSize)
        deleteBadge.wantsLayer = true
        deleteBadge.layer?.cornerRadius = badgeSize / 2
        deleteBadge.layer?.masksToBounds = true
        deleteBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        deleteBadge.layer?.borderWidth = 1
        deleteBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        deleteBadge.isHidden = true

        deleteLabel.font = .systemFont(ofSize: 9, weight: .bold)
        deleteLabel.textColor = .white
        deleteLabel.alignment = .center
        deleteLabel.frame = NSRect(x: 0, y: (badgeSize - 12) / 2, width: badgeSize, height: 12)
        deleteBadge.addSubview(deleteLabel)

        addSubview(deleteBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        deleteBadge.isHidden = false
        iconView.alphaValue = 0.85
    }

    override func mouseExited(with event: NSEvent) {
        deleteBadge.isHidden = true
        iconView.alphaValue = 1.0
    }

    override func mouseUp(with event: NSEvent) {
        onRemove?()
    }
}

// MARK: - 右侧竖向中转站（最大限制 10 个应用）

final class SelectionTrayView: NSView {

    static let maxSelectionCount = 10

    var onRemoveItem: ((AppInfo) -> Void)?
    var onCancelAll: (() -> Void)?
    var onPlaceToPage: (() -> Void)?

    private(set) var items: [AppInfo] = []

    private let backgroundCard = NSVisualEffectView()
    private let countBadge = NSTextField(labelWithString: "0")
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let iconsContainer = NSView()
    private var iconViews: [TrayAppIconView] = []
    private let placeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        backgroundCard.material = .hudWindow
        backgroundCard.blendingMode = .withinWindow
        backgroundCard.state = .active
        backgroundCard.wantsLayer = true
        backgroundCard.layer?.cornerRadius = 18
        backgroundCard.layer?.masksToBounds = true
        backgroundCard.layer?.borderWidth = 1
        backgroundCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(backgroundCard)

        countBadge.alignment = .center
        countBadge.font = .systemFont(ofSize: 11, weight: .bold)
        countBadge.textColor = .white
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = 9
        countBadge.layer?.masksToBounds = true
        countBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        backgroundCard.addSubview(countBadge)

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 12, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "清空并退出多选"
        closeButton.target = self
        closeButton.action = #selector(cancelClicked)
        backgroundCard.addSubview(closeButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = iconsContainer
        backgroundCard.addSubview(scrollView)

        placeButton.isBordered = false
        placeButton.wantsLayer = true
        placeButton.layer?.cornerRadius = 14
        placeButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        placeButton.contentTintColor = .white
        placeButton.attributedTitle = NSAttributedString(string: "放本页", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        placeButton.target = self
        placeButton.action = #selector(placeClicked)
        backgroundCard.addSubview(placeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ apps: [AppInfo]) {
        let capped = Array(apps.prefix(Self.maxSelectionCount))
        items = capped
        iconViews.forEach { $0.removeFromSuperview() }
        iconViews.removeAll()
        for app in capped {
            let view = TrayAppIconView(app: app, size: 44)
            view.onRemove = { [weak self] in self?.onRemoveItem?(app) }
            iconViews.append(view)
            iconsContainer.addSubview(view)
        }
        if capped.count >= Self.maxSelectionCount {
            countBadge.stringValue = "\(capped.count)/\(Self.maxSelectionCount)"
        } else {
            countBadge.stringValue = "\(capped.count)"
        }
        needsLayout = true
    }

    func preferredHeight(maxHeight: CGFloat) -> CGFloat {
        let headerH: CGFloat = 34
        let footerH: CGFloat = 42
        let iconS: CGFloat = 44
        let iconSpacing: CGFloat = 8
        let displayCount = min(items.count, Self.maxSelectionCount)
        let iconsH = CGFloat(displayCount) * iconS + CGFloat(max(0, displayCount - 1)) * iconSpacing
        return min(maxHeight, max(140, headerH + iconsH + footerH + 16))
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }

        backgroundCard.frame = bounds
        countBadge.frame = NSRect(x: 10, y: h - 28, width: 28, height: 18)
        closeButton.frame = NSRect(x: w - 30, y: h - 30, width: 22, height: 22)

        let btnW = w - 16, btnH: CGFloat = 28
        placeButton.frame = NSRect(x: 8, y: 10, width: btnW, height: btnH)

        let scrollY = placeButton.frame.maxY + 8
        let scrollH = max(10, h - scrollY - 34)
        scrollView.frame = NSRect(x: 0, y: scrollY, width: w, height: scrollH)

        let iconS: CGFloat = 44, iconSpacing: CGFloat = 8
        let contentH = CGFloat(iconViews.count) * iconS + CGFloat(max(0, iconViews.count - 1)) * iconSpacing
        let finalH = max(scrollH, contentH + 8)
        iconsContainer.frame = NSRect(x: 0, y: 0, width: w, height: finalH)

        let iconX = (w - iconS) / 2
        for (i, view) in iconViews.enumerated() {
            let y = finalH - CGFloat(i + 1) * iconS - CGFloat(i) * iconSpacing - 4
            view.frame = NSRect(x: iconX, y: y, width: iconS, height: iconS)
        }
    }

    @objc private func placeClicked() { onPlaceToPage?() }
    @objc private func cancelClicked() { onCancelAll?() }
}
