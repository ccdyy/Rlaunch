import Cocoa
import RlaunchCore

extension NSPasteboard.PasteboardType {
    static let rlaunchAppPath = NSPasteboard.PasteboardType("com.rlaunch.app-path")
    static let rlaunchFolderID = NSPasteboard.PasteboardType("com.rlaunch.folder-id")
    static let rlaunchReorderItems = NSPasteboard.PasteboardType("com.rlaunch.reorder-items")
}

// MARK: - 多选状态指示徽章

final class SelectionBadgeView: NSView {
    var isSelected: Bool = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let circlePath = NSBezierPath(ovalIn: b)

        if isSelected {
            NSColor.controlAccentColor.setFill()
            circlePath.fill()

            let checkmark = NSBezierPath()
            let w = b.width, h = b.height
            let x0 = b.minX, y0 = b.minY
            checkmark.move(to: NSPoint(x: x0 + w * 0.28, y: y0 + h * 0.50))
            checkmark.line(to: NSPoint(x: x0 + w * 0.44, y: y0 + h * 0.30))
            checkmark.line(to: NSPoint(x: x0 + w * 0.74, y: y0 + h * 0.70))
            checkmark.lineWidth = 2.0
            checkmark.lineCapStyle = .round
            checkmark.lineJoinStyle = .round
            NSColor.white.setStroke()
            checkmark.stroke()
        } else {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                NSColor.black.withAlphaComponent(0.45).setFill()
                circlePath.fill()
                NSColor.white.withAlphaComponent(0.75).setStroke()
                circlePath.lineWidth = 1.5
                circlePath.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.75).setFill()
                circlePath.fill()
                NSColor.black.withAlphaComponent(0.40).setStroke()
                circlePath.lineWidth = 1.5
                circlePath.stroke()
            }
        }
    }
}

// MARK: - 单个应用/文件夹单元视图

final class AppItemView: NSView, NSDraggingSource {

    var item: GridItem
    var onActivate: ((GridItem) -> Void)?
    var onDropAppToFolder: ((String) -> Void)?
    var onDropAppsToFolder: (([String]) -> Void)?
    var onContextMenu: ((GridItem) -> NSMenu?)?
    var onLongPress: ((GridItem) -> Void)?
    var onToggleSelect: ((GridItem) -> Void)?
    var onResizeFolder: ((FolderConfig, Int, Int) -> Void)?

    var isSelectionMode: Bool = false {
        didSet { updateSelectionStyle() }
    }
    var isItemSelected: Bool = false {
        didSet { updateSelectionStyle() }
    }
    var isSelectionDisabled: Bool = false {
        didSet { updateSelectionStyle() }
    }
    /// 应用是否正在运行（在图标下方显示小圆点，类似 Dock 的运行指示）
    var isRunning: Bool = false {
        didSet {
            guard isRunning != oldValue else { return }
            runningDot.isHidden = !isRunning
        }
    }
    /// 键盘焦点（方向键导航时高亮）
    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            focusRing.isHidden = !isFocused
        }
    }
    var onSelectionLimitReached: (() -> Void)?
    var getSelectedItemsForDrag: (() -> [GridItem])?

    // 基础子组件
    private let singleImageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badgeView = SelectionBadgeView()
    /// 运行中指示小圆点
    private let runningDot = NSView()
    /// 键盘焦点高亮环
    private let focusRing = NSView()

    // 文件夹专属子组件：采用纯净图层背景（彻底杜绝 NSVisualEffectView 的顶部黑色横线）
    private let folderCard = NSView()
    private var folderSlotViews: [NSView] = []

    // 交互与长按多选跟踪
    private var dragStart: NSPoint?
    private var longPressTimer: Timer?
    private var didTriggerLongPress = false

    private var config = GridLayoutConfig.defaults

    init(item: GridItem, config: GridLayoutConfig) {
        self.item = item
        super.init(frame: .zero)
        self.config = config
        wantsLayer = true

        // 键盘焦点高亮环（位于所有内容之下，只露出一圈）
        focusRing.wantsLayer = true
        focusRing.layer?.cornerRadius = 14
        focusRing.layer?.borderWidth = 1.6
        focusRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
        focusRing.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        focusRing.isHidden = true
        addSubview(focusRing)

        // 单个应用图标
        singleImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(singleImageView)

        // 文件夹背景卡片：纯净半透明圆角卡片，无任何系统 CoreUI 杂线
        folderCard.wantsLayer = true
        folderCard.layer?.cornerRadius = 16
        folderCard.layer?.masksToBounds = true
        folderCard.layer?.borderWidth = 1
        folderCard.isHidden = true
        addSubview(folderCard)

        // 名称标签
        label.font = .systemFont(ofSize: max(11, config.iconSize * 0.19))
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        addSubview(label)

        // 多选徽章
        badgeView.isHidden = true
        addSubview(badgeView)

        // 运行中指示点（默认隐藏，仅应用且正在运行时显示）
        runningDot.wantsLayer = true
        runningDot.layer?.cornerRadius = 2.5
        runningDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        runningDot.isHidden = true
        addSubview(runningDot)

        if case .folder = item {
            registerForDraggedTypes([.rlaunchAppPath])
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)

        updateContent()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionStyle()
    }

    @objc private func themeDidChange() {
        updateSelectionStyle()
    }

    private var isDarkMode: Bool {
        if let eff = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            return eff == .darkAqua
        }
        return ThemeManager.current != .light
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(
        item: GridItem,
        config: GridLayoutConfig,
        isSelectionMode: Bool,
        isItemSelected: Bool,
        isSelectionDisabled: Bool = false
    ) {
        self.item = item
        self.isSelectionMode = isSelectionMode
        self.isItemSelected = isItemSelected
        self.isSelectionDisabled = isSelectionDisabled

        if case .folder = item {
            if registeredDraggedTypes.isEmpty { registerForDraggedTypes([.rlaunchAppPath]) }
        } else {
            unregisterDraggedTypes()
        }

        applyLayoutConfig(config)
        updateContent()
        updateSelectionStyle()
        needsLayout = true
    }

    func applyLayoutConfig(_ config: GridLayoutConfig) {
        self.config = config
        label.font = .systemFont(ofSize: max(11, config.iconSize * 0.19))
        needsLayout = true
    }

    private func updateContent() {
        switch item {
        case .app(let info):
            singleImageView.isHidden = false
            folderCard.isHidden = true
            clearFolderSlots()

            singleImageView.image = IconCache.shared.icon(for: info.path)
            singleImageView.contentTintColor = nil
            label.stringValue = info.name

        case .folder(let folder):
            singleImageView.isHidden = true
            folderCard.isHidden = false
            label.stringValue = folder.name.isEmpty ? "文件夹" : folder.name

            populateFolderSlots(folder: folder)
        }
        // 辅助功能：VoiceOver 可朗读条目名称与类型
        let kind = item.isFolder ? "文件夹" : "应用"
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(item.displayName)，\(kind)")
        toolTip = item.isFolder ? "\(item.displayName)（文件夹）" : item.displayName
    }

    private func clearFolderSlots() {
        folderSlotViews.forEach { $0.removeFromSuperview() }
        folderSlotViews.removeAll()
    }

    /// 根据文件夹占用网格 N 与内部 App 数量 M 动态排布图标，支持更大图标与更饱满的显示效果
    private func populateFolderSlots(folder: FolderConfig) {
        clearFolderSlots()

        let cols = max(1, folder.spanColumns)
        let rows = max(1, folder.spanRows)
        let totalSlots = cols * rows
        let apps = folder.appPaths
        let appCount = apps.count

        if appCount == 0 {
            // 空文件夹：居中放一个大号默认文件夹符号
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            let sym = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "文件夹")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: config.iconSize * 0.72, weight: .regular))
            iv.image = sym
            iv.contentTintColor = .secondaryLabelColor
            folderSlotViews.append(iv)
            addSubview(iv)
            return
        }

        if totalSlots > appCount {
            // N > M：展示全部 M 个 App，剩余留空
            for path in apps {
                let iv = NSImageView()
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.image = IconCache.shared.icon(for: path)
                folderSlotViews.append(iv)
                addSubview(iv)
            }
        } else {
            // N <= M：前 N - 1 个显示单一图标，最后一个显示叠加
            let directCount = totalSlots - 1
            if directCount > 0 {
                for i in 0..<directCount {
                    let iv = NSImageView()
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    iv.image = IconCache.shared.icon(for: apps[i])
                    folderSlotViews.append(iv)
                    addSubview(iv)
                }
            }
            // 最后一个槽位：叠加图标
            let remainingPaths = Array(apps.dropFirst(directCount))
            let stackedView = StackedIconView()
            stackedView.setApps(paths: remainingPaths, remainingCount: remainingPaths.count)
            folderSlotViews.append(stackedView)
            addSubview(stackedView)
        }
    }

    private func updateSelectionStyle() {
        badgeView.isHidden = !isSelectionMode
        badgeView.isSelected = isItemSelected
        badgeView.needsDisplay = true

        let dark = isDarkMode

        if isSelectionMode && isItemSelected {
            singleImageView.alphaValue = 0.85
            folderCard.alphaValue = 1.0
            folderCard.layer?.borderWidth = 2
            folderCard.layer?.borderColor = NSColor.controlAccentColor.cgColor
            folderCard.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.24 : 0.18).cgColor
            label.textColor = .labelColor
            if case .app = item {
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.14 : 0.12).cgColor
                layer?.cornerRadius = 12
            }
        } else if isSelectionMode && isSelectionDisabled {
            // 达到 10 个数量上限：未选中项置灰，提示不可选
            singleImageView.alphaValue = 0.32
            folderCard.alphaValue = 0.32
            folderCard.layer?.borderWidth = 1
            if dark {
                folderCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
                folderCard.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            } else {
                folderCard.layer?.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
                folderCard.layer?.backgroundColor = NSColor(white: 0.90, alpha: 0.40).cgColor
            }
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .tertiaryLabelColor
        } else {
            singleImageView.alphaValue = 1.0
            folderCard.alphaValue = 1.0
            folderCard.layer?.borderWidth = 1
            if dark {
                // 暗色模式：告别死黑，采用通透优雅的高级半透明白灰，明亮且层次丰富
                folderCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
                folderCard.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.22).cgColor
            } else {
                // 亮色模式：高亮柔白质感，边框精致立体
                folderCard.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
                folderCard.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.72).cgColor
            }
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .labelColor
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        let labelH = config.labelHeight
        let y = 0.0
        label.frame = NSRect(x: 2, y: y, width: b.width - 4, height: labelH)

        let contentH = max(10, b.height - labelH - 4)
        let contentW = b.width

        switch item {
        case .app:
            let iconSize = min(config.iconSize, min(contentW, contentH))
            let iconX = (b.width - iconSize) / 2
            let iconY = labelH + (contentH - iconSize) / 2 + 2
            singleImageView.frame = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)

            let badgeSize: CGFloat = 20
            let badgeX = min(b.width - badgeSize - 2, iconX + iconSize - badgeSize + 2)
            let badgeY = min(b.height - badgeSize - 2, iconY + iconSize - badgeSize + 2)
            badgeView.frame = NSRect(x: badgeX, y: badgeY, width: badgeSize, height: badgeSize)

            // 运行指示点：图标正下方居中
            let dotSize: CGFloat = 5
            let dotY = max(2, iconY - dotSize - 3)
            runningDot.frame = NSRect(x: (b.width - dotSize) / 2, y: dotY, width: dotSize, height: dotSize)

            focusRing.frame = NSRect(x: iconX - 5, y: iconY - 5, width: iconSize + 10, height: iconSize + 10)

        case .folder(let folder):
            let cardRect = NSRect(x: 2, y: labelH + 2, width: contentW - 4, height: contentH - 2)
            folderCard.frame = cardRect

            // 多选徽章位于文件夹卡片右上角
            let badgeSize: CGFloat = 20
            badgeView.frame = NSRect(x: cardRect.maxX - badgeSize - 3, y: cardRect.maxY - badgeSize - 3, width: badgeSize, height: badgeSize)

            focusRing.frame = cardRect.insetBy(dx: -3, dy: -3)

            // 内部子槽位布局（spanColumns x spanRows）
            layoutFolderSlots(folder: folder, in: cardRect)
        }
    }

    private func layoutFolderSlots(folder: FolderConfig, in rect: NSRect) {
        guard !folderSlotViews.isEmpty else { return }

        let cols = max(1, folder.spanColumns)
        let rows = max(1, folder.spanRows)

        if folder.appPaths.isEmpty {
            // 空文件夹：单图标居中大号展示
            let iv = folderSlotViews[0]
            let s = min(rect.width * 0.70, rect.height * 0.70)
            iv.frame = NSRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
            return
        }

        // 大幅优化边距，图标更大更醒目
        let isSingleCell = (cols == 1 && rows == 1)
        let padH: CGFloat = isSingleCell ? 4 : 6
        let padV: CGFloat = isSingleCell ? 4 : 6
        let slotW = (rect.width - padH * 2) / CGFloat(cols)
        let slotH = (rect.height - padV * 2) / CGFloat(rows)
        let scaleRatio: CGFloat = isSingleCell ? 0.92 : 0.88
        let iconMax = min(slotW * scaleRatio, slotH * scaleRatio)

        for (idx, view) in folderSlotViews.enumerated() {
            let r = idx / cols
            let c = idx % cols
            if r >= rows { break }

            let cellX = rect.minX + padH + CGFloat(c) * slotW
            let cellY = rect.maxY - padV - CGFloat(r + 1) * slotH
            let ix = cellX + (slotW - iconMax) / 2
            let iy = cellY + (slotH - iconMax) / 2
            view.frame = NSRect(x: ix, y: iy, width: iconMax, height: iconMax)
        }
    }

    // MARK: - 鼠标手势与多选长按

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        didTriggerLongPress = false
        longPressTimer?.invalidate()

        let timer = Timer(timeInterval: 0.40, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.didTriggerLongPress = true
            if self.isSelectionMode {
                if !self.isItemSelected && self.isSelectionDisabled {
                    self.onSelectionLimitReached?()
                } else {
                    self.onToggleSelect?(self.item)
                }
            } else {
                self.onLongPress?(self.item)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, hypot(p.x - start.x, p.y - start.y) > 6 else { return }
        longPressTimer?.invalidate()
        longPressTimer = nil
        dragStart = nil

        // 长按触发后或处于多选状态下，拖拽开启多选/单项重排序
        if isSelectionMode || didTriggerLongPress {
            beginReorderDrag(event: event)
        } else {
            beginDrag(event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        if didTriggerLongPress {
            didTriggerLongPress = false
            dragStart = nil
            return
        }

        if let start = dragStart {
            dragStart = nil
            if isSelectionMode {
                if case .folder = item {
                    // 如果点击在右上角徽章区域（允许额外容错），或者文件夹已处于选中状态，必定执行反选/选中
                    let hitBadge = badgeView.frame.insetBy(dx: -8, dy: -8).contains(start)
                    if hitBadge || isItemSelected {
                        if !isItemSelected && isSelectionDisabled {
                            onSelectionLimitReached?()
                        } else {
                            onToggleSelect?(item)
                        }
                    } else {
                        // 未被选中的文件夹卡片：打开文件夹，方便用户查看或将选中的应用放入文件夹
                        onActivate?(item)
                    }
                } else {
                    if !isItemSelected && isSelectionDisabled {
                        onSelectionLimitReached?()
                    } else {
                        onToggleSelect?(item)
                    }
                }
            } else {
                onActivate?(item)
            }
        }
    }

    private func beginReorderDrag(event: NSEvent) {
        var itemsToDrag: [GridItem] = []
        if let selected = getSelectedItemsForDrag?(), !selected.isEmpty {
            if selected.contains(where: { $0.identifier == item.identifier }) {
                itemsToDrag = selected
            } else {
                onToggleSelect?(item)
                itemsToDrag = selected + [item]
            }
        } else {
            itemsToDrag = [item]
        }

        let pbItem = NSPasteboardItem()
        let ids = itemsToDrag.map { $0.identifier }
        if let data = try? JSONEncoder().encode(ids), let jsonStr = String(data: data, encoding: .utf8) {
            pbItem.setString(jsonStr, forType: .rlaunchReorderItems)
        }

        switch item {
        case .app(let info):
            pbItem.setString(info.path, forType: .rlaunchAppPath)
        case .folder(let folder):
            pbItem.setString(folder.id, forType: .rlaunchFolderID)
        }

        let basePreview = createRetinaPreviewImage()
        let preview = makeDragPreviewImage(baseSnapshot: basePreview, count: itemsToDrag.count)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        let previewSize = preview.size
        dragItem.setDraggingFrame(NSRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height), contents: preview)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func createRetinaPreviewImage() -> NSImage {
        let targetView: NSView
        let targetBounds: NSRect
        switch item {
        case .app:
            targetView = singleImageView
            targetBounds = singleImageView.bounds
        case .folder:
            targetView = folderCard
            targetBounds = folderCard.bounds
        }

        let w = max(1, targetBounds.width)
        let h = max(1, targetBounds.height)

        let wasBadgeHidden = badgeView.isHidden
        badgeView.isHidden = true

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelW = max(1, Int(w * scale))
        let pixelH = max(1, Int(h * scale))

        if let rep = targetView.bitmapImageRepForCachingDisplay(in: targetBounds) {
            targetView.cacheDisplay(in: targetBounds, to: rep)
            badgeView.isHidden = wasBadgeHidden
            let img = NSImage(size: NSSize(width: w, height: h))
            img.addRepresentation(rep)
            return img
        } else if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = NSSize(width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                targetView.displayIgnoringOpacity(targetBounds, in: ctx)
            }
            NSGraphicsContext.restoreGraphicsState()
            badgeView.isHidden = wasBadgeHidden
            let img = NSImage(size: NSSize(width: w, height: h))
            img.addRepresentation(rep)
            return img
        }

        badgeView.isHidden = wasBadgeHidden
        switch item {
        case .app(let info):
            let img = IconCache.shared.icon(for: info.path)
            img.size = NSSize(width: config.iconSize, height: config.iconSize)
            return img
        case .folder:
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: config.iconSize * 0.8, weight: .regular)) ?? NSImage()
        }
    }

    private func makeDragPreviewImage(baseSnapshot: NSImage, count: Int) -> NSImage {
        guard count > 1 else { return baseSnapshot }
        let size = baseSnapshot.size
        let s = max(size.width, size.height)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelW = max(1, Int(s * scale))
        let pixelH = max(1, Int(s * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return baseSnapshot }

        rep.size = NSSize(width: s, height: s)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high

            baseSnapshot.draw(in: NSRect(x: 0, y: 0, width: s, height: s))

            let badgeText = "\(count)"
            let font = NSFont.boldSystemFont(ofSize: max(11, s * 0.20))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: badgeText, attributes: attrs)
            let textSize = str.size()
            let badgeH = max(20, textSize.height + 4)
            let badgeW = max(badgeH, textSize.width + 12)
            let badgeRect = NSRect(x: s - badgeW - 1, y: s - badgeH - 1, width: badgeW, height: badgeH)

            let path = NSBezierPath(roundedRect: badgeRect, xRadius: badgeH / 2, yRadius: badgeH / 2)
            NSColor.controlAccentColor.setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()

            let textRect = NSRect(
                x: badgeRect.minX + (badgeW - textSize.width) / 2,
                y: badgeRect.minY + (badgeH - textSize.height) / 2 - 0.5,
                width: textSize.width,
                height: textSize.height
            )
            str.draw(in: textRect)
        }
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: s, height: s))
        result.addRepresentation(rep)
        return result
    }

    private func beginDrag(event: NSEvent) {
        let pbItem = NSPasteboardItem()
        switch item {
        case .app(let info):
            pbItem.setString(info.path, forType: .rlaunchAppPath)
        case .folder(let folder):
            pbItem.setString(folder.id, forType: .rlaunchFolderID)
        }

        let preview = createRetinaPreviewImage()
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        let previewSize = preview.size
        dragItem.setDraggingFrame(NSRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height), contents: preview)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.move, .copy]
    }

    override func rightMouseDown(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        if let menu = onContextMenu?(item) {
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }
    }

    // MARK: - 拖放接收（仅允许将 App 拖入文件夹；严禁文件夹嵌套）

    private func extractDroppableAppPaths(from sender: NSDraggingInfo, folder: FolderConfig) -> [String] {
        let pb = sender.draggingPasteboard
        // 如果拖拽内容包含文件夹 ID，严禁放入（防嵌套）
        if pb.string(forType: .rlaunchFolderID) != nil { return [] }

        var candidatePaths: [String] = []
        if let jsonStr = pb.string(forType: .rlaunchReorderItems),
           let data = jsonStr.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            // 如果多选列表里包含文件夹，严防嵌套放入
            if ids.contains(where: { $0.hasPrefix("folder:") }) { return [] }
            for id in ids where id.hasPrefix("app:") {
                candidatePaths.append(String(id.dropFirst(4)))
            }
        } else if let path = pb.string(forType: .rlaunchAppPath) {
            candidatePaths.append(path)
        }

        let existing = Set(folder.appPaths)
        return candidatePaths.filter { !existing.contains($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .folder(let folder) = item else { return [] }
        let paths = extractDroppableAppPaths(from: sender, folder: folder)
        guard !paths.isEmpty else { return [] }
        highlight(true)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .folder(let folder) = item else { return [] }
        let paths = extractDroppableAppPaths(from: sender, folder: folder)
        guard !paths.isEmpty else {
            highlight(false)
            return []
        }
        highlight(true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        guard case .folder(let folder) = item else { return false }
        let paths = extractDroppableAppPaths(from: sender, folder: folder)
        guard !paths.isEmpty else { return false }
        if let onDropApps = onDropAppsToFolder {
            onDropApps(paths)
        } else if let first = paths.first {
            onDropAppToFolder?(first)
        }
        return true
    }

    private func highlight(_ on: Bool) {
        wantsLayer = true
        if case .folder = item {
            if on {
                folderCard.layer?.borderColor = NSColor.controlAccentColor.cgColor
                folderCard.layer?.borderWidth = 2.5
                folderCard.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.26).cgColor
                folderCard.layer?.shadowColor = NSColor.controlAccentColor.cgColor
                folderCard.layer?.shadowOpacity = 0.65
                folderCard.layer?.shadowRadius = 8
                folderCard.layer?.shadowOffset = .zero

                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    folderCard.animator().layer?.transform = CATransform3DMakeScale(1.05, 1.05, 1.0)
                }
            } else {
                updateSelectionStyle()
                folderCard.layer?.shadowOpacity = 0

                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    folderCard.animator().layer?.transform = CATransform3DIdentity
                }
            }
        }
    }
}
