import Cocoa
import RlaunchCore

/// 支持顶部对齐滚动的网格容器
final class FlippedGridView: NSView {
    override var isFlipped: Bool { true }
}

/// 文件夹展开弹窗视图：半透明居中弹框，展示文件夹内全部应用，支持启动、更名、解散、从文件夹移出、长按多选与中转站放入。
final class FolderPopoverView: NSView {

    private static let cardCornerRadius: CGFloat = 22

    var folder: FolderConfig
    var allApps: [AppInfo]
    var isSelectionMode: Bool = false
    var selectedIdentifiers: Set<String> = []
    var pendingPlaceAppsCount: Int = 0
    var isSelectionDisabled: Bool = false
    /// 当前背景预设（用于让卡片与主界面同色系）
    var darkPresetId: String = "default"
    var lightPresetId: String = "softGray"
    /// 是否使用自定义背景图：背景图比纯色预设更需要压色，才能保证卡片内文字可读
    var usesBackgroundImage: Bool = false {
        didSet { if oldValue != usesBackgroundImage { updateThemeAppearance() } }
    }

    var onLaunchApp: ((AppInfo) -> Void)?
    var onRemoveApp: ((AppInfo) -> Void)?
    var onUninstallApp: ((AppInfo) -> Void)?
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
    /// 卡片玻璃背板：直接采样**本窗口**的背景（自定义背景图或毛玻璃预设色），
    /// 因此卡片会随背景一起变化，而不是一块与背景割裂的纯色板。
    private var cardBackdrop: NSView!
    /// 与背景同色系的极轻调色层：只用于压出可读性，不破坏通透感
    private let cardTint = NSView()
    /// 卡片内容承载层（玻璃容器内部，位于调色层之上）
    private var cardContentHost: NSView!
    private var edgeStroke: EdgeStrokeView?
    private let titleField = NSTextField()
    private let closeButton = NSButton()
    private let dissolveButton = NSButton()
    private let placePendingButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let gridContainer = FlippedGridView()
    private var appItemViews: [AppItemView] = []
    /// 当前生效的网格规格（由 layout() 按卡片尺寸动态推算）
    private var appliedGridConfig: GridLayoutConfig?
    /// 仅在内容真正重新加载后重置滚动位置，避免窗口缩放/主题切换把用户滚到一半的列表弹回顶部
    private var needsScrollReset = true

    init(
        folder: FolderConfig,
        allApps: [AppInfo],
        isSelectionMode: Bool = false,
        selectedIdentifiers: Set<String> = [],
        pendingPlaceAppsCount: Int = 0,
        isSelectionDisabled: Bool = false,
        usesBackgroundImage: Bool = false,
        darkPresetId: String = "default",
        lightPresetId: String = "softGray"
    ) {
        self.folder = folder
        self.allApps = allApps
        self.isSelectionMode = isSelectionMode
        self.selectedIdentifiers = selectedIdentifiers
        self.pendingPlaceAppsCount = pendingPlaceAppsCount
        self.isSelectionDisabled = isSelectionDisabled
        self.usesBackgroundImage = usesBackgroundImage
        self.darkPresetId = darkPresetId
        self.lightPresetId = lightPresetId
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

        // 内容卡片：圆角玻璃卡片。圆角交给 cardView 的 layer 裁剪（不使用 maskImage，
        // 从而杜绝 NSVisualEffectView 顶部残留黑线的问题）
        // 轮廓完全由 cardView 自己的图层决定 → 用连续曲率圆角，与系统窗口/卡片同形；
        // 描边不能写在 cardView.layer 上（会被下面的背板/调色/内容子层盖住），改用最上层的描边视图。
        cardView.wantsLayer = true
        cardView.layer?.applyRoundedCorner(radius: Self.cardCornerRadius, continuous: true, masksToBounds: true)
        cardShadowContainer.addSubview(cardView)

        // 玻璃背板（macOS 26+ 原生 Liquid Glass，采样窗口自身内容）→ 极轻的同色系调色 → 内容
        let (backdrop, host) = SystemGlass.makeInWindowContainer(
            cornerRadius: Self.cardCornerRadius, material: .popover)
        cardBackdrop = backdrop
        cardContentHost = host
        cardView.addSubview(backdrop)
        cardTint.wantsLayer = true
        cardTint.autoresizingMask = [.width, .height]
        host.addSubview(cardTint)

        // 文件夹标题（可就地编辑）
        titleField.stringValue = folder.name.isEmpty ? L10n.t("文件夹") : folder.name
        titleField.font = .systemFont(ofSize: 18, weight: .bold)
        titleField.alignment = .left
        titleField.textColor = .labelColor
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.target = self
        titleField.action = #selector(titleEdited)
        cardContentHost.addSubview(titleField)

        // 解散文件夹按钮
        dissolveButton.bezelStyle = .inline
        dissolveButton.isBordered = false
        dissolveButton.title = L10n.t("解散文件夹")
        dissolveButton.font = .systemFont(ofSize: 12, weight: .regular)
        dissolveButton.contentTintColor = .secondaryLabelColor
        dissolveButton.target = self
        dissolveButton.action = #selector(dissolveClicked)
        cardContentHost.addSubview(dissolveButton)

        // 放入中转站选中的应用快捷按钮
        placePendingButton.isBordered = false
        placePendingButton.wantsLayer = true
        placePendingButton.layer?.cornerRadius = 11
        placePendingButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        placePendingButton.contentTintColor = .white
        placePendingButton.target = self
        placePendingButton.action = #selector(placePendingClicked)
        placePendingButton.isHidden = true
        cardContentHost.addSubview(placePendingButton)

        // 关闭按钮
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 13, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        cardContentHost.addSubview(closeButton)

        // 底部应用总数
        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        cardContentHost.addSubview(countLabel)

        // 滚动区域：必须设置 borderType = .noBorder，彻底杜绝默认 bezelBorder 产生的“黑色横线”
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = gridContainer
        cardContentHost.addSubview(scrollView)

        // 最后安装描边：位于内容之上，且不拦截点击
        edgeStroke = EdgeStrokeView.install(on: cardView,
                                           cornerRadius: Self.cardCornerRadius,
                                           width: 1,
                                           continuous: true)

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
        // 玻璃背板之上叠一层自适应调色：纯色预设背景可以更透（保留毛玻璃质感），
        // 自定义背景图则压得更实一些，避免图片纹理干扰图标与文字。
        if dark {
            cardTint.layer?.backgroundColor = usesBackgroundImage
                ? NSColor(calibratedWhite: 0.10, alpha: 0.58).cgColor
                : NSColor(calibratedWhite: 0.16, alpha: 0.30).cgColor
            edgeStroke?.update(color: NSColor.white.withAlphaComponent(0.14))
            cardShadowContainer.layer?.shadowColor = NSColor.black.cgColor
            cardShadowContainer.layer?.shadowOpacity = 0.45
            dimmingMask.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        } else {
            cardTint.layer?.backgroundColor = usesBackgroundImage
                ? NSColor.white.withAlphaComponent(0.74).cgColor
                : NSColor.white.withAlphaComponent(0.50).cgColor
            edgeStroke?.update(color: NSColor.black.withAlphaComponent(0.10))
            cardShadowContainer.layer?.shadowColor = NSColor.black.cgColor
            cardShadowContainer.layer?.shadowOpacity = 0.20
            dimmingMask.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        }
        cardView.layer?.backgroundColor = NSColor.clear.cgColor
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
        titleField.stringValue = folder.name.isEmpty ? L10n.t("文件夹") : folder.name
        // 只有条目真正增删时才回到顶部；仅选中状态变化不应打断用户的滚动位置
        if expectedIdentifiers(for: folder) != appItemViews.map({ $0.item.identifier }) {
            needsScrollReset = true
        }
        reloadFolderApps()
        needsLayout = true
    }

    /// 该文件夹当前应展示的条目标识符（顺序与 reloadFolderApps 一致）
    private func expectedIdentifiers(for folder: FolderConfig) -> [String] {
        let paths = Set(folder.appPaths)
        return allApps.filter { paths.contains($0.path) }.map { "app:\($0.path)" }
    }

    private func reloadFolderApps() {
        appItemViews.forEach { $0.removeFromSuperview() }
        appItemViews.removeAll()

        let appPathSet = Set(folder.appPaths)
        let matchedApps = allApps.filter { appPathSet.contains($0.path) }
        countLabel.stringValue = L10n.f("共 %d 个应用", matchedApps.count)

        if pendingPlaceAppsCount > 0 {
            placePendingButton.isHidden = false
            placePendingButton.attributedTitle = NSAttributedString(
                string: L10n.f("放入选中应用 (%d)", pendingPlaceAppsCount),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
            )
        } else {
            placePendingButton.isHidden = true
        }

        let cfg = appliedGridConfig
            ?? GridLayoutConfig(columns: 4, rows: 3, columnSpacing: 18, rowSpacing: 18, iconSize: 58)

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
                let mi = NSMenuItem(title: L10n.t("从文件夹移出"), action: #selector(self?.menuRemoveApp(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = app
                menu.addItem(mi)

                let reveal = NSMenuItem(title: L10n.t("在访达中显示"), action: #selector(self?.menuRevealApp(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = app
                menu.addItem(reveal)

                menu.addItem(.separator())

                let uninstall = NSMenuItem(title: L10n.t("卸载应用…"), action: #selector(self?.menuUninstallApp(_:)), keyEquivalent: "")
                uninstall.target = self
                uninstall.representedObject = app
                if self?.isAppUninstallable(app.path) == false {
                    uninstall.isEnabled = false
                    uninstall.toolTip = L10n.t("系统应用不可卸载")
                }
                menu.addItem(uninstall)
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

    @objc private func menuRevealApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }

    @objc private func menuUninstallApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        onUninstallApp?(app)
    }

    private func isAppUninstallable(_ path: String) -> Bool {
        if path.hasPrefix("/System/") || path.hasPrefix("/System/Applications") {
            return false
        }
        return FileManager.default.isDeletableFile(atPath: path)
    }

    @objc private func titleEdited() {
        let trimmed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? L10n.t("文件夹") : trimmed
        titleField.stringValue = finalName
        onRenameFolder?(finalName)
    }

    @objc private func dissolveClicked() {
        // 确认交给窗口内浮层处理：伪全屏时 NSAlert 会被压在窗口后面且阻塞主线程
        onDissolveFolder?()
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

        // 卡片尺寸：宽度约占窗口 2/3，高度按内容收紧；
        // 关键是最大高度必须留出充足上下留白——之前用 `b.height - 40`，
        // 应用较多的文件夹会把卡片撑到几乎顶住窗口上下边。
        let hMargin = min(120, max(56, b.width * 0.11))
        let vMargin = min(120, max(48, b.height * 0.15))
        let cardW = min(max(b.width * 0.66, 380), 1040, b.width - hMargin * 2)
        let maxCardH = min(max(b.height * 0.68, 260), 760, b.height - vMargin * 2)
        let scrollW = max(120, cardW - 32)
        // 图标尺寸的高度约束参考卡片上限高度（避免与 cardH 形成循环依赖）
        let maxScrollH = max(60, maxCardH - 38 - 54)

        // 先按宽度推算网格，再据内容行数收紧卡片高度：应用少时不留大片空白，应用多时才拉满
        let cfg = Self.gridConfig(forScrollWidth: scrollW, scrollHeight: maxScrollH)
        if appliedGridConfig != cfg {
            appliedGridConfig = cfg
            for view in appItemViews {
                view.applyLayoutConfig(cfg)
                view.needsLayout = true
            }
        }

        let rows = max(1, (appItemViews.count + cfg.columns - 1) / cfg.columns)
        let gridH = CGFloat(rows) * cfg.cellHeight + CGFloat(rows + 1) * cfg.rowSpacing
        let neededH = gridH + 38 + 54 + 18 // 中间滚动区上下留白 + 头部 + 底部
        let cardH = min(max(neededH, 260), maxCardH)
        let cardX = (b.width - cardW) / 2
        let cardY = (b.height - cardH) / 2
        let cardRect = NSRect(x: cardX, y: cardY, width: cardW, height: cardH)

        cardShadowContainer.frame = cardRect
        cardView.frame = cardShadowContainer.bounds
        // 玻璃铺满卡片；内容宿主挂在玻璃容器内部，调色层与内容都与它等大
        cardBackdrop.frame = cardView.bounds
        cardContentHost.frame = cardBackdrop.bounds
        cardTint.frame = cardContentHost.bounds

        // 头部
        titleField.frame = NSRect(x: 24, y: cardH - 46, width: max(120, cardW - 240), height: 26)
        dissolveButton.frame = NSRect(x: cardW - 130, y: cardH - 44, width: 80, height: 22)
        closeButton.frame = NSRect(x: cardW - 42, y: cardH - 44, width: 22, height: 22)

        // 底部应用总数与放入按钮
        countLabel.frame = NSRect(x: 24, y: 12, width: 200, height: 18)

        if !placePendingButton.isHidden {
            let btnW: CGFloat = 150, btnH: CGFloat = 24
            placePendingButton.frame = NSRect(x: cardW - btnW - 20, y: 10, width: btnW, height: btnH)
        }

        // 中间滚动区域
        let scrollY: CGFloat = 38
        let scrollH = max(60, cardH - scrollY - 54)
        scrollView.frame = NSRect(x: 16, y: scrollY, width: scrollW, height: scrollH)

        let cellW = cfg.cellWidth
        let cellH = cfg.cellHeight
        let colSpacing = cfg.columnSpacing
        let rowSpacing = cfg.rowSpacing

        let contentH = max(scrollH, gridH)
        gridContainer.frame = NSRect(x: 0, y: 0, width: scrollW, height: contentH)

        for (i, view) in appItemViews.enumerated() {
            let r = i / cfg.columns
            let c = i % cfg.columns
            let x = colSpacing + CGFloat(c) * (cellW + colSpacing)
            let y = rowSpacing + CGFloat(r) * (cellH + rowSpacing)
            view.frame = NSRect(x: x, y: y, width: cellW, height: cellH)
        }

        // 默认显示最上面的应用：仅在内容重新加载后重置滚动条，避免布局重算把用户弹回顶部
        if needsScrollReset {
            needsScrollReset = false
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// 依据可用宽度与高度推算网格：卡片越大 → 列数越多、图标越大。
    /// - 列数按四舍五入取整，并封顶 8 列；否则全屏时列数过多会让单元格反而变窄、图标比窗口化时还小。
    /// - 图标尺寸再受可用高度约束，保证矮卡片里至少能完整看到两行，避免小窗口里图标虚大却只能滚动。
    private static func gridConfig(forScrollWidth width: CGFloat, scrollHeight: CGFloat) -> GridLayoutConfig {
        let targetCellWidth = max(84, min(118, width / 6.5))
        let rawColumns = Int(((width - 16) / targetCellWidth).rounded())
        let columns = max(3, min(8, rawColumns))
        let spacing = max(12, min(26, width * 0.022))
        let cellWidth = (width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        var iconSize = max(36, min(92, cellWidth * 0.78))
        if scrollHeight > 0 {
            // cellHeight = iconSize + labelHeight(26) + 16，两行 + 两个行间距需落在可视高度内
            let maxIconByHeight = (scrollHeight - spacing * 2) / 2 - 42
            iconSize = min(iconSize, max(36, maxIconByHeight))
        }
        return GridLayoutConfig(
            columns: columns,
            rows: 3,
            columnSpacing: spacing,
            rowSpacing: spacing,
            iconSize: iconSize
        )
    }
}
