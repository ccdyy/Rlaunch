import Cocoa
import RlaunchCore

/// 支持顶部对齐滚动的网格容器
final class FlippedGridView: NSView {
    override var isFlipped: Bool { true }
}

/// 文件夹展开弹窗视图：半透明居中弹框，展示文件夹内全部应用，支持启动、更名、解散、从文件夹移出、长按多选与中转站放入。
final class FolderPopoverView: NSView {

    var folder: FolderConfig
    var allApps: [AppInfo]
    var isSelectionMode: Bool = false
    var selectedIdentifiers: Set<String> = []
    var pendingPlaceAppsCount: Int = 0
    var isSelectionDisabled: Bool = false

    var onLaunchApp: ((AppInfo) -> Void)?
    var onRemoveApp: ((AppInfo) -> Void)?
    var onRenameFolder: ((String) -> Void)?
    var onDissolveFolder: (() -> Void)?
    var onClose: (() -> Void)?
    var onLongPressApp: ((AppInfo) -> Void)?
    var onToggleSelectApp: ((AppInfo) -> Void)?
    var onPlacePendingApps: (() -> Void)?
    var onSelectionLimitReached: (() -> Void)?

    private let dimmingMask = NSView()
    private let cardShadowContainer = NSView()
    private let cardView = NSView()
    private let titleField = NSTextField()
    private let closeButton = NSButton()
    private let dissolveButton = NSButton()
    private let placePendingButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let gridContainer = FlippedGridView()
    private var appItemViews: [AppItemView] = []

    init(
        folder: FolderConfig,
        allApps: [AppInfo],
        isSelectionMode: Bool = false,
        selectedIdentifiers: Set<String> = [],
        pendingPlaceAppsCount: Int = 0,
        isSelectionDisabled: Bool = false
    ) {
        self.folder = folder
        self.allApps = allApps
        self.isSelectionMode = isSelectionMode
        self.selectedIdentifiers = selectedIdentifiers
        self.pendingPlaceAppsCount = pendingPlaceAppsCount
        self.isSelectionDisabled = isSelectionDisabled
        super.init(frame: .zero)

        wantsLayer = true

        // 半透明背景遮罩（点击外部关闭弹框，轻盈通透避免压抑）
        dimmingMask.wantsLayer = true
        addSubview(dimmingMask)

        // 阴影外容器（只负责投影，避免剪裁阴影）
        cardShadowContainer.wantsLayer = true
        cardShadowContainer.layer?.masksToBounds = false
        cardShadowContainer.layer?.shadowColor = NSColor.black.cgColor
        cardShadowContainer.layer?.shadowOffset = CGSize(width: 0, height: -10)
        cardShadowContainer.layer?.shadowRadius = 24
        addSubview(cardShadowContainer)

        // 内容卡片：纯净半透明圆角卡片（杜绝 NSVisualEffectView 的顶部黑色横线）
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 22
        cardView.layer?.masksToBounds = true
        cardView.layer?.borderWidth = 1
        cardShadowContainer.addSubview(cardView)

        // 文件夹标题（可就地编辑）
        titleField.stringValue = folder.name.isEmpty ? "文件夹" : folder.name
        titleField.font = .systemFont(ofSize: 18, weight: .bold)
        titleField.alignment = .left
        titleField.textColor = .labelColor
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.target = self
        titleField.action = #selector(titleEdited)
        cardView.addSubview(titleField)

        // 解散文件夹按钮
        dissolveButton.bezelStyle = .inline
        dissolveButton.isBordered = false
        dissolveButton.title = "解散文件夹"
        dissolveButton.font = .systemFont(ofSize: 12, weight: .regular)
        dissolveButton.contentTintColor = .secondaryLabelColor
        dissolveButton.target = self
        dissolveButton.action = #selector(dissolveClicked)
        cardView.addSubview(dissolveButton)

        // 放入中转站选中的应用快捷按钮
        placePendingButton.isBordered = false
        placePendingButton.wantsLayer = true
        placePendingButton.layer?.cornerRadius = 11
        placePendingButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        placePendingButton.contentTintColor = .white
        placePendingButton.target = self
        placePendingButton.action = #selector(placePendingClicked)
        placePendingButton.isHidden = true
        cardView.addSubview(placePendingButton)

        // 关闭按钮
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 13, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        cardView.addSubview(closeButton)

        // 底部应用总数
        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        cardView.addSubview(countLabel)

        // 滚动区域：必须设置 borderType = .noBorder，彻底杜绝默认 bezelBorder 产生的“黑色横线”
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = gridContainer
        cardView.addSubview(scrollView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)

        updateThemeAppearance()
        reloadFolderApps()
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
            // 暗色模式：背景遮罩适度沉浸聚焦；卡片近乎完全不透明（alpha: 0.98），彻底杜绝与底层主界面的透视交叠混杂
            dimmingMask.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.40).cgColor
            cardView.layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.98).cgColor
            cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
            cardShadowContainer.layer?.shadowColor = NSColor.black.cgColor
            cardShadowContainer.layer?.shadowOpacity = 0.50
        } else {
            // 亮色模式：纯净不透明（alpha: 0.99）白瓷卡片质感，轮廓清晰扎实，无任何透视穿透干扰
            dimmingMask.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
            cardView.layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.99).cgColor
            cardView.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            cardShadowContainer.layer?.shadowColor = NSColor.black.cgColor
            cardShadowContainer.layer?.shadowOpacity = 0.22
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(
        folder: FolderConfig,
        allApps: [AppInfo],
        isSelectionMode: Bool,
        selectedIdentifiers: Set<String>,
        pendingPlaceAppsCount: Int,
        isSelectionDisabled: Bool = false
    ) {
        self.folder = folder
        self.allApps = allApps
        self.isSelectionMode = isSelectionMode
        self.selectedIdentifiers = selectedIdentifiers
        self.pendingPlaceAppsCount = pendingPlaceAppsCount
        self.isSelectionDisabled = isSelectionDisabled
        titleField.stringValue = folder.name.isEmpty ? "文件夹" : folder.name
        reloadFolderApps()
        needsLayout = true
    }

    private func reloadFolderApps() {
        appItemViews.forEach { $0.removeFromSuperview() }
        appItemViews.removeAll()

        let appPathSet = Set(folder.appPaths)
        let matchedApps = allApps.filter { appPathSet.contains($0.path) }
        countLabel.stringValue = "共 \(matchedApps.count) 个应用"

        if pendingPlaceAppsCount > 0 {
            placePendingButton.isHidden = false
            placePendingButton.attributedTitle = NSAttributedString(
                string: "放入选中应用 (\(pendingPlaceAppsCount))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
            )
        } else {
            placePendingButton.isHidden = true
        }

        let cfg = GridLayoutConfig(columns: 4, rows: 3, columnSpacing: 18, rowSpacing: 18, iconSize: 58)

        for app in matchedApps {
            let item = GridItem.app(app)
            let isSelected = selectedIdentifiers.contains(item.identifier)
            let isItemDisabled = isSelectionDisabled && !isSelected
            let view = AppItemView(item: item, config: cfg)
            view.update(
                item: item,
                config: cfg,
                isSelectionMode: isSelectionMode,
                isItemSelected: isSelected,
                isSelectionDisabled: isItemDisabled
            )

            view.onActivate = { [weak self] _ in
                if self?.isSelectionMode == true {
                    if isItemDisabled {
                        self?.onSelectionLimitReached?()
                    } else {
                        self?.onToggleSelectApp?(app)
                    }
                } else {
                    self?.onLaunchApp?(app)
                }
            }
            view.onLongPress = { [weak self] _ in
                if isItemDisabled {
                    self?.onSelectionLimitReached?()
                } else {
                    self?.onLongPressApp?(app)
                }
            }
            view.onToggleSelect = { [weak self] _ in
                if isItemDisabled {
                    self?.onSelectionLimitReached?()
                } else {
                    self?.onToggleSelectApp?(app)
                }
            }
            view.onSelectionLimitReached = { [weak self] in
                self?.onSelectionLimitReached?()
            }
            view.onContextMenu = { [weak self] _ in
                let menu = NSMenu()
                let mi = NSMenuItem(title: "从文件夹移出", action: #selector(self?.menuRemoveApp(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = app
                menu.addItem(mi)
                return menu
            }
            appItemViews.append(view)
            gridContainer.addSubview(view)
        }
        needsLayout = true
    }

    @objc private func menuRemoveApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        onRemoveApp?(app)
    }

    @objc private func titleEdited() {
        let trimmed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "文件夹" : trimmed
        titleField.stringValue = finalName
        onRenameFolder?(finalName)
    }

    @objc private func dissolveClicked() {
        let alert = NSAlert()
        alert.messageText = "解散文件夹"
        alert.informativeText = "确定要解散「\(folder.name)」吗？里面的应用将被释放回主界面。"
        alert.addButton(withTitle: "解散")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            onDissolveFolder?()
        }
    }

    @objc private func placePendingClicked() {
        onPlacePendingApps?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !cardShadowContainer.frame.contains(p) {
            onClose?()
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        dimmingMask.frame = b

        let maxW = min(620, b.width - 60)
        let maxH = min(460, b.height - 80)
        let cardW: CGFloat = max(380, maxW)
        let cardH: CGFloat = max(280, maxH)
        let cardX = (b.width - cardW) / 2
        let cardY = (b.height - cardH) / 2
        let cardRect = NSRect(x: cardX, y: cardY, width: cardW, height: cardH)

        cardShadowContainer.frame = cardRect
        cardView.frame = cardShadowContainer.bounds

        // 头部
        titleField.frame = NSRect(x: 24, y: cardH - 46, width: cardW - 220, height: 26)
        dissolveButton.frame = NSRect(x: cardW - 130, y: cardH - 44, width: 80, height: 22)
        closeButton.frame = NSRect(x: cardW - 42, y: cardH - 44, width: 22, height: 22)

        // 底部应用总数与放入按钮
        countLabel.frame = NSRect(x: 24, y: 12, width: 140, height: 18)

        if !placePendingButton.isHidden {
            let btnW: CGFloat = 140, btnH: CGFloat = 24
            placePendingButton.frame = NSRect(x: cardW - btnW - 20, y: 10, width: btnW, height: btnH)
        }

        // 中间滚动区域
        let scrollY: CGFloat = 38
        let scrollH = cardH - scrollY - 54
        scrollView.frame = NSRect(x: 16, y: scrollY, width: cardW - 32, height: scrollH)

        // 网格内容计算：4 列排布
        let cols = 4
        let iconS: CGFloat = 58
        let labelH: CGFloat = 28
        let cellW: CGFloat = iconS + 20
        let cellH: CGFloat = iconS + labelH + 12
        let colSpacing: CGFloat = max(8, (scrollView.frame.width - CGFloat(cols) * cellW) / CGFloat(cols + 1))
        let rowSpacing: CGFloat = 16

        let rows = max(1, (appItemViews.count + cols - 1) / cols)
        let contentH = max(scrollH, CGFloat(rows) * cellH + CGFloat(rows + 1) * rowSpacing)
        gridContainer.frame = NSRect(x: 0, y: 0, width: scrollView.frame.width, height: contentH)

        for (i, view) in appItemViews.enumerated() {
            let r = i / cols
            let c = i % cols
            let x = colSpacing + CGFloat(c) * (cellW + colSpacing)
            let y = rowSpacing + CGFloat(r) * (cellH + rowSpacing)
            view.frame = NSRect(x: x, y: y, width: cellW, height: cellH)
        }

        // 默认显示最上面的应用：重置滚动条至顶部
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
