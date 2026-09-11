import Cocoa
import RlaunchCore

/// 网格布局参数
struct GridLayoutConfig: Equatable {
    var columns: Int = 7
    var rows: Int = 5
    var columnSpacing: CGFloat = 24
    var rowSpacing: CGFloat = 24
    var iconSize: CGFloat = 64

    static let defaults = GridLayoutConfig()

    var labelHeight: CGFloat { min(40, max(26, iconSize * 0.28)) }
    var cellWidth: CGFloat { iconSize + 20 }
    var cellHeight: CGFloat { iconSize + labelHeight + 16 }
}

/// 一页网格：按 columns×rows 居中排布应用/文件夹；支持跨单元格大文件夹、长按多选、空白处点击返回、右键菜单。
final class GridPageView: NSView {

    var items: [GridItem] = [] {
        didSet { syncViews() }
    }
    var layoutConfig: GridLayoutConfig = .defaults {
        didSet {
            for view in cellViews { view.applyLayoutConfig(layoutConfig) }
            needsLayout = true
        }
    }

    var isSelectionMode: Bool = false {
        didSet { syncSelectionState() }
    }
    var selectedIdentifiers: Set<String> = [] {
        didSet { syncSelectionState() }
    }
    var isSelectionDisabled: Bool = false {
        didSet { syncSelectionState() }
    }

    var onAppClick: ((AppInfo) -> Void)?
    var onFolderClick: ((FolderConfig) -> Void)?
    var onBlankClick: (() -> Void)?
    var onDropAppToBlank: ((String) -> Void)?
    var onDropAppToFolder: ((String, FolderConfig) -> Void)?
    var onDropAppsToFolder: (([String], FolderConfig) -> Void)?
    var onContextMenu: ((GridItem?) -> NSMenu?)?
    var onLongPressItem: ((GridItem) -> Void)?
    var onToggleSelectItem: ((GridItem) -> Void)?
    var onResizeFolder: ((FolderConfig, Int, Int) -> Void)?
    var onSelectionLimitReached: (() -> Void)?
    var onReorderDrop: (([String], Int) -> Void)?
    var getSelectedItemsForDrag: (() -> [GridItem])?

    private var cellViews: [AppItemView] = []
    private let insertionIndicator = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.rlaunchReorderItems, .rlaunchAppPath, .rlaunchFolderID])

        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.layer?.cornerRadius = 2
        insertionIndicator.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.layer?.shadowOpacity = 0.85
        insertionIndicator.layer?.shadowRadius = 4
        insertionIndicator.layer?.shadowOffset = .zero
        insertionIndicator.isHidden = true
        addSubview(insertionIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func syncViews() {
        while cellViews.count < items.count {
            let dummy = GridItem.app(AppInfo(name: "", path: "", bundleID: ""))
            let view = AppItemView(item: dummy, config: layoutConfig)
            view.onActivate = { [weak self] item in
                switch item {
                case .app(let info): self?.onAppClick?(info)
                case .folder(let folder): self?.onFolderClick?(folder)
                }
            }
            view.onDropAppToFolder = { [weak self, weak view] path in
                guard let self, let view, case .folder(let folder) = view.item else { return }
                self.onDropAppToFolder?(path, folder)
            }
            view.onDropAppsToFolder = { [weak self, weak view] paths in
                guard let self, let view, case .folder(let folder) = view.item else { return }
                self.onDropAppsToFolder?(paths, folder)
            }
            view.onContextMenu = { [weak self] item in
                self?.onContextMenu?(item)
            }
            view.onLongPress = { [weak self] item in
                self?.onLongPressItem?(item)
            }
            view.onToggleSelect = { [weak self] item in
                self?.onToggleSelectItem?(item)
            }
            view.onSelectionLimitReached = { [weak self] in
                self?.onSelectionLimitReached?()
            }
            view.onResizeFolder = { [weak self] folder, cols, rows in
                self?.onResizeFolder?(folder, cols, rows)
            }
            view.getSelectedItemsForDrag = { [weak self] in
                self?.getSelectedItemsForDrag?() ?? []
            }
            cellViews.append(view)
            addSubview(view)
        }
        while cellViews.count > items.count {
            cellViews.removeLast().removeFromSuperview()
        }
        for (i, item) in items.enumerated() {
            let selected = selectedIdentifiers.contains(item.identifier)
            let disabled = isSelectionDisabled && !selected
            cellViews[i].update(
                item: item,
                config: layoutConfig,
                isSelectionMode: isSelectionMode,
                isItemSelected: selected,
                isSelectionDisabled: disabled
            )
        }
        addSubview(insertionIndicator, positioned: .above, relativeTo: nil)
        needsLayout = true
    }

    private func syncSelectionState() {
        for (i, item) in items.enumerated() where i < cellViews.count {
            let selected = selectedIdentifiers.contains(item.identifier)
            let disabled = isSelectionDisabled && !selected
            cellViews[i].isSelectionMode = isSelectionMode
            cellViews[i].isItemSelected = selected
            cellViews[i].isSelectionDisabled = disabled
        }
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }

        let cfg = layoutConfig
        let cols = max(cfg.columns, 1)
        let rows = max(cfg.rows, 1)
        let cellW = cfg.cellWidth
        let cellH = cfg.cellHeight
        let colSpacing = cfg.columnSpacing
        let rowSpacing = cfg.rowSpacing

        let gridW = CGFloat(cols) * cellW + CGFloat(cols - 1) * colSpacing
        let gridH = CGFloat(rows) * cellH + CGFloat(rows - 1) * rowSpacing
        let x0 = (W - gridW) / 2
        let y0 = (H - gridH) / 2

        var occupied = Array(repeating: Array(repeating: false, count: cols), count: rows)

        for (i, view) in cellViews.enumerated() {
            guard i < items.count else {
                view.isHidden = true
                continue
            }
            let item = items[i]
            let spanC = min(item.spanColumns, cols)
            let spanR = min(item.spanRows, rows)

            var placedRow: Int?
            var placedCol: Int?

            outerLoop: for r in 0..<rows {
                if r + spanR > rows { continue }
                for c in 0..<cols {
                    if c + spanC > cols { continue }
                    var canFit = true
                    checkLoop: for dr in 0..<spanR {
                        for dc in 0..<spanC {
                            if occupied[r + dr][c + dc] {
                                canFit = false
                                break checkLoop
                            }
                        }
                    }
                    if canFit {
                        placedRow = r
                        placedCol = c
                        break outerLoop
                    }
                }
            }

            guard let pr = placedRow, let pc = placedCol else {
                view.isHidden = true
                continue
            }

            view.isHidden = false
            for dr in 0..<spanR {
                for dc in 0..<spanC {
                    occupied[pr + dr][pc + dc] = true
                }
            }

            let w = CGFloat(spanC) * cellW + CGFloat(spanC - 1) * colSpacing
            let h = CGFloat(spanR) * cellH + CGFloat(spanR - 1) * rowSpacing
            let x = x0 + CGFloat(pc) * (cellW + colSpacing)
            let topY = y0 + gridH - CGFloat(pr) * (cellH + rowSpacing)
            let y = topY - h
            view.frame = NSRect(x: x, y: y, width: w, height: h)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onBlankClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(nil) {
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }
    }

    private func targetIndex(for point: NSPoint) -> (index: Int, rect: NSRect) {
        guard !items.isEmpty, !cellViews.isEmpty else {
            let x: CGFloat = 20
            let y = bounds.height - 100
            return (0, NSRect(x: x, y: y, width: 3.5, height: 70))
        }

        var bestIndex = 0
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        var bestRect = NSRect.zero

        let count = min(items.count, cellViews.count)
        for i in 0...count {
            let rect: NSRect
            if i == 0 {
                let f = cellViews[0].frame
                rect = NSRect(x: max(2, f.minX - 4), y: f.minY, width: 3.5, height: f.height)
            } else if i == count {
                let f = cellViews[count - 1].frame
                rect = NSRect(x: min(bounds.width - 6, f.maxX + 1), y: f.minY, width: 3.5, height: f.height)
            } else {
                let prevF = cellViews[i - 1].frame
                let nextF = cellViews[i].frame
                if abs(prevF.midY - nextF.midY) < 25 {
                    let midX = (prevF.maxX + nextF.minX) / 2
                    rect = NSRect(x: midX - 1.75, y: nextF.minY, width: 3.5, height: nextF.height)
                } else {
                    rect = NSRect(x: max(2, nextF.minX - 4), y: nextF.minY, width: 3.5, height: nextF.height)
                }
            }

            let dy = (rect.midY - point.y) * 1.5
            let dx = rect.midX - point.x
            let dist = hypot(dx, dy)
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i
                bestRect = rect
            }
        }

        return (bestIndex, bestRect)
    }

    private func updateInsertionIndicator(for sender: NSDraggingInfo) {
        let p = convert(sender.draggingLocation, from: nil)
        // 如果正悬停在某个可以接收的文件夹上方，隐藏插入指示条，避免与文件夹微缩放高亮冲突
        let pb = sender.draggingPasteboard
        let isFolderDrag = pb.string(forType: .rlaunchFolderID) != nil
        if !isFolderDrag {
            for v in cellViews where !v.isHidden {
                if case .folder = v.item, v.frame.contains(p) {
                    insertionIndicator.isHidden = true
                    return
                }
            }
        }

        let res = targetIndex(for: p)
        insertionIndicator.frame = res.rect
        insertionIndicator.isHidden = false
        addSubview(insertionIndicator, positioned: .above, relativeTo: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.string(forType: .rlaunchReorderItems) != nil ||
           sender.draggingPasteboard.string(forType: .rlaunchAppPath) != nil ||
           sender.draggingPasteboard.string(forType: .rlaunchFolderID) != nil {
            updateInsertionIndicator(for: sender)
            return .move
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.string(forType: .rlaunchReorderItems) != nil ||
           sender.draggingPasteboard.string(forType: .rlaunchAppPath) != nil ||
           sender.draggingPasteboard.string(forType: .rlaunchFolderID) != nil {
            updateInsertionIndicator(for: sender)
            return .move
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionIndicator.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        insertionIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertionIndicator.isHidden = true
        let pb = sender.draggingPasteboard

        var itemIds: [String] = []
        if let jsonStr = pb.string(forType: .rlaunchReorderItems),
           let data = jsonStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            itemIds = decoded
        } else if let path = pb.string(forType: .rlaunchAppPath) {
            itemIds = ["app:\(path)"]
        } else if let folderId = pb.string(forType: .rlaunchFolderID) {
            itemIds = ["folder:\(folderId)"]
        }

        guard !itemIds.isEmpty else { return false }

        let p = convert(sender.draggingLocation, from: nil)
        let dropIndex = targetIndex(for: p).index

        onReorderDrop?(itemIds, dropIndex)
        return true
    }
}
