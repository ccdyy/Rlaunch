import Cocoa
import RlaunchCore

// MARK: - 中转站内的条目图标单元（支持 App 与 文件夹，悬停右上角显示删除标）

final class TrayItemView: NSView {
    let item: GridItem
    var onRemove: (() -> Void)?

    private let folderBgCard = NSView()
    private let iconView = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let deleteBadge = NSView()
    private let deleteLabel = NSTextField(labelWithString: "✕")

    init(item: GridItem, size: CGFloat = 68) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true

        if case .folder = item {
            folderBgCard.wantsLayer = true
            folderBgCard.layer?.cornerRadius = 14
            folderBgCard.layer?.masksToBounds = true
            folderBgCard.layer?.borderWidth = 1
            folderBgCard.frame = bounds.insetBy(dx: 1, dy: 1)
            addSubview(folderBgCard)
        }

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        switch item {
        case .app(let info):
            iconView.frame = bounds
            iconView.image = IconCache.shared.icon(for: info.path)
            toolTip = L10n.f("%@\n点击移除出中转站", info.name)
        case .folder(let folder):
            let iconH = size * 0.58
            let iconY = size - iconH - 6
            iconView.frame = NSRect(x: (size - iconH) / 2, y: iconY, width: iconH, height: iconH)

            let sym = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: L10n.t("文件夹"))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconH * 0.85, weight: .medium))
            iconView.image = sym
            toolTip = L10n.f("%@ (文件夹)\n点击移除出中转站", folder.name)

            folderLabel.font = .systemFont(ofSize: 10, weight: .bold)
            folderLabel.alignment = .center
            folderLabel.lineBreakMode = .byTruncatingTail
            folderLabel.frame = NSRect(x: 4, y: 5, width: size - 8, height: 14)
            folderLabel.stringValue = folder.name
            addSubview(folderLabel)
        }

        // 右上角删除小标：尺寸适度放大，位置更加精致
        let badgeSize: CGFloat = 18
        deleteBadge.frame = NSRect(x: size - badgeSize, y: size - badgeSize, width: badgeSize, height: badgeSize)
        deleteBadge.wantsLayer = true
        deleteBadge.layer?.cornerRadius = badgeSize / 2
        deleteBadge.layer?.masksToBounds = true
        deleteBadge.layer?.borderWidth = 1
        deleteBadge.isHidden = true

        deleteLabel.font = .systemFont(ofSize: 10, weight: .bold)
        deleteLabel.alignment = .center
        deleteLabel.frame = NSRect(x: 0, y: (badgeSize - 12) / 2, width: badgeSize, height: 12)
        deleteBadge.addSubview(deleteLabel)

        addSubview(deleteBadge)

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)

        updateAppearance()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    @objc private func themeDidChange() {
        updateAppearance()
    }

    private var isDarkMode: Bool {
        if let eff = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            return eff == .darkAqua
        }
        return ThemeManager.current != .light
    }

    private func updateAppearance() {
        let dark = isDarkMode

        if case .folder = item {
            if dark {
                // 暗色模式：高通透白灰卡片底衬，搭配通透清澈的冰川天蓝文件夹
                folderBgCard.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.16).cgColor
                folderBgCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
                iconView.contentTintColor = NSColor(red: 0.38, green: 0.72, blue: 1.0, alpha: 1.0)
                folderLabel.textColor = .white
            } else {
                // 浅色模式：温润微灰底衬，搭配经典纯正的 macOS 蔚蓝文件夹与清晰深色文字
                folderBgCard.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.06).cgColor
                folderBgCard.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
                iconView.contentTintColor = NSColor(red: 0.15, green: 0.50, blue: 0.94, alpha: 1.0)
                folderLabel.textColor = NSColor(white: 0.12, alpha: 1.0)
            }
        }

        if dark {
            deleteBadge.layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.90).cgColor
            deleteBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            deleteLabel.textColor = .white
        } else {
            deleteBadge.layer?.backgroundColor = NSColor(white: 0.30, alpha: 0.85).cgColor
            deleteBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.40).cgColor
            deleteLabel.textColor = .white
        }
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

// MARK: - 右侧竖向中转站（最大限制 10 项，支持 App 与 文件夹混合移动）

final class SelectionTrayView: NSView {

    static let maxSelectionCount = 10
    static let sideMargin: CGFloat = 8
    static let itemSpacing: CGFloat = 10

    var onRemoveItem: ((GridItem) -> Void)?
    var onCancelAll: (() -> Void)?
    var onPlaceAction: (() -> Void)?
    var onCreateFolder: (() -> Void)?

    private(set) var items: [GridItem] = []
    private(set) var isFolderTarget: Bool = false

    // 采用纯净半透明圆角卡片，彻底根除 NSVisualEffectView 在顶部的黑色横线
    private let backgroundCard = NSView()
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let iconsContainer = NSView()
    private var iconViews: [TrayItemView] = []

    private let placeButton = NSButton()
    private let createFolderButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        backgroundCard.wantsLayer = true
        backgroundCard.layer?.cornerRadius = 18
        backgroundCard.layer?.masksToBounds = true
        backgroundCard.layer?.borderWidth = 1
        addSubview(backgroundCard)

        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 12, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = L10n.t("清空并退出多选")
        closeButton.target = self
        closeButton.action = #selector(cancelClicked)
        backgroundCard.addSubview(closeButton)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = iconsContainer
        backgroundCard.addSubview(scrollView)

        // 操作主按钮（放本页 / 放此文件夹）
        setupActionButton(placeButton, title: L10n.t("放本页"), bg: NSColor.controlAccentColor, action: #selector(placeClicked))
        // 新建文件夹按钮（≥2个App时显示）
        setupActionButton(createFolderButton, title: L10n.t("建文件夹"), bg: NSColor.systemGreen, action: #selector(createFolderClicked))

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)

        updateThemeAppearance()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeAppearance()
    }

    @objc private func themeDidChange() {
        updateThemeAppearance()
    }

    private var isDarkMode: Bool {
        if let eff = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            return eff == .darkAqua
        }
        return ThemeManager.current != .light
    }

    private func updateThemeAppearance() {
        let dark = isDarkMode
        if dark {
            backgroundCard.layer?.backgroundColor = NSColor(white: 0.22, alpha: 0.94).cgColor
            backgroundCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        } else {
            backgroundCard.layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.96).cgColor
            backgroundCard.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        }
    }

    private func setupActionButton(_ btn: NSButton, title: String, bg: NSColor, action: Selector) {
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 12
        btn.layer?.backgroundColor = bg.cgColor
        btn.contentTintColor = .white
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        btn.target = self
        btn.action = action
        backgroundCard.addSubview(btn)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTargetMode(isFolder: Bool) {
        self.isFolderTarget = isFolder
        let title = isFolder ? L10n.t("放文件夹") : L10n.t("放本页")
        placeButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        needsLayout = true
    }

    func setItems(_ newItems: [GridItem]) {
        let capped = Array(newItems.prefix(Self.maxSelectionCount))
        items = capped
        iconViews.forEach { $0.removeFromSuperview() }
        iconViews.removeAll()

        // 默认大图标尺寸（与按钮宽度对齐：84 - 8*2 = 68）
        let iconS: CGFloat = 68
        for item in capped {
            let view = TrayItemView(item: item, size: iconS)
            view.onRemove = { [weak self] in self?.onRemoveItem?(item) }
            iconViews.append(view)
            iconsContainer.addSubview(view)
        }

        let appCount = items.filter { $0.isApp }.count
        let hasFolder = items.contains { $0.isFolder }

        // 选中至少 2 个 App 且无文件夹时显示“建文件夹”
        createFolderButton.isHidden = appCount < 2 || hasFolder

        // 选中有文件夹时强制放本页
        if hasFolder && isFolderTarget {
            setTargetMode(isFolder: false)
        }

        needsLayout = true
    }

    func preferredHeight(maxHeight: CGFloat) -> CGFloat {
        let headerH: CGFloat = 30
        var footerH: CGFloat = 36
        if !createFolderButton.isHidden { footerH += 30 }

        let iconS: CGFloat = 68
        let spacing = Self.itemSpacing
        let displayCount = min(items.count, Self.maxSelectionCount)
        let iconsH = CGFloat(displayCount) * iconS + CGFloat(max(0, displayCount - 1)) * spacing
        return min(maxHeight, max(150, headerH + iconsH + footerH + 16))
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }

        backgroundCard.frame = bounds
        closeButton.frame = NSRect(x: w - 28, y: h - 28, width: 20, height: 20)

        let margin = Self.sideMargin
        let btnW = w - margin * 2
        let btnH: CGFloat = 26
        var currentY: CGFloat = 8

        if !createFolderButton.isHidden {
            createFolderButton.frame = NSRect(x: margin, y: currentY, width: btnW, height: btnH)
            currentY += btnH + 4
        }
        placeButton.frame = NSRect(x: margin, y: currentY, width: btnW, height: btnH)
        currentY += btnH + 8

        let scrollH = max(10, h - currentY - 30)
        scrollView.frame = NSRect(x: 0, y: currentY, width: w, height: scrollH)

        // 图标宽度与按钮同宽，左右间距均为 sideMargin（8pt），与按钮上下完美对齐
        let iconS = btnW
        let spacing = Self.itemSpacing
        let contentH = CGFloat(iconViews.count) * iconS + CGFloat(max(0, iconViews.count - 1)) * spacing
        let finalH = max(scrollH, contentH + 8)
        iconsContainer.frame = NSRect(x: 0, y: 0, width: w, height: finalH)

        let iconX = margin
        for (i, view) in iconViews.enumerated() {
            let y = finalH - CGFloat(i + 1) * iconS - CGFloat(i) * spacing - 4
            view.frame = NSRect(x: iconX, y: y, width: iconS, height: iconS)
        }
    }

    @objc private func placeClicked() { onPlaceAction?() }
    @objc private func createFolderClicked() { onCreateFolder?() }
    @objc private func cancelClicked() { onCancelAll?() }
}
