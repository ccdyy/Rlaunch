import Cocoa
import RlaunchCore

/// 网格布局参数
struct GridLayoutConfig {
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

/// 一页网格：按 columns×rows 居中排布应用/文件夹；支持长按多选、空白处点击返回、右键菜单。
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
    var selectedAppPaths: Set<String> = [] {
        didSet { syncSelectionState() }
    }

    var onAppClick: ((AppInfo) -> Void)?
    var onFolderClick: ((FolderConfig) -> Void)?
    var onBlankClick: (() -> Void)?
    var onDropAppToBlank: ((String) -> Void)?
    var onDropAppToFolder: ((String, FolderConfig) -> Void)?
    var onContextMenu: ((GridItem?) -> NSMenu?)?
    var onLongPressItem: ((GridItem) -> Void)?
    var onToggleSelectItem: ((GridItem) -> Void)?

    private var cellViews: [AppItemView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.rlaunchAppPath])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func syncViews() {
        while cellViews.count < items.count {
            let view = AppItemView(kind: .app(AppInfo(name: "", path: "", bundleID: "")), config: layoutConfig)
            view.onActivate = { [weak self] kind in
                switch kind {
                case .app(let info): self?.onAppClick?(info)
                case .folder(let folder): self?.onFolderClick?(folder)
                }
            }
            view.onDropAppToFolder = { [weak self, weak view] path in
                guard let self, let view, case .folder(let folder) = view.kind else { return }
                self.onDropAppToFolder?(path, folder)
            }
            view.onContextMenu = { [weak self] kind in self?.onContextMenu?(self?.kindFor(itemView: kind)) }
            view.onLongPress = { [weak self] kind in
                if let item = self?.kindFor(itemView: kind) { self?.onLongPressItem?(item) }
            }
            view.onToggleSelect = { [weak self] kind in
                if let item = self?.kindFor(itemView: kind) { self?.onToggleSelectItem?(item) }
            }
            cellViews.append(view)
            addSubview(view)
        }
        while cellViews.count > items.count {
            cellViews.removeLast().removeFromSuperview()
        }
        for (i, item) in items.enumerated() {
            let selected = item.appPath.map { selectedAppPaths.contains($0) } ?? false
            cellViews[i].update(kind: kindFor(item: item), config: layoutConfig,
                                isSelectionMode: isSelectionMode, isItemSelected: selected)
        }
        needsLayout = true
    }

    private func syncSelectionState() {
        for (i, item) in items.enumerated() where i < cellViews.count {
            let selected = item.appPath.map { selectedAppPaths.contains($0) } ?? false
            cellViews[i].isSelectionMode = isSelectionMode
            cellViews[i].isItemSelected = selected
        }
    }

    private func kindFor(item: GridItem) -> AppItemView.Kind {
        switch item {
        case .app(let info): return .app(info)
        case .folder(let folder): return .folder(folder)
        }
    }

    private func kindFor(itemView kind: AppItemView.Kind) -> GridItem? {
        switch kind {
        case .app(let info): return .app(info)
        case .folder(let folder): return .folder(folder)
        }
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let cfg = layoutConfig
        let cols = max(cfg.columns, 1)
        let cellW = cfg.cellWidth, cellH = cfg.cellHeight

        let gridW = CGFloat(cols) * cellW + CGFloat(cols - 1) * cfg.columnSpacing
        let gridH = CGFloat(cfg.rows) * cellH + CGFloat(cfg.rows - 1) * cfg.rowSpacing
        let x0 = (W - gridW) / 2
        let y0 = (H - gridH) / 2

        for (i, view) in cellViews.enumerated() {
            let r = i / cols
            let c = i % cols
            let x = x0 + CGFloat(c) * (cellW + cfg.columnSpacing)
            let y = y0 + CGFloat(cfg.rows - 1 - r) * (cellH + cfg.rowSpacing)
            view.frame = NSRect(x: x, y: y, width: cellW, height: cellH)
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: .rlaunchAppPath) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let path = sender.draggingPasteboard.string(forType: .rlaunchAppPath) else { return false }
        onDropAppToBlank?(path)
        return true
    }
}
