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

    /// 名称标签高度随图标大小缩放（全屏放大图标时文字同步放大）
    var labelHeight: CGFloat { min(40, max(26, iconSize * 0.28)) }
    var cellWidth: CGFloat { iconSize + 16 }
    var cellHeight: CGFloat { iconSize + labelHeight + 8 }
}

/// 一页网格：按 columns×rows 居中排布应用/文件夹；空白处点击返回、右键菜单；
/// 空白处作为拖放目标（文件夹模式下把应用拖到空白 = 移出文件夹）。
final class GridPageView: NSView {

    var items: [GridItem] = [] {
        didSet { syncViews() }
    }
    var layoutConfig: GridLayoutConfig = .defaults {
        didSet {
            // 把新布局参数同步给每个 cell（全屏切换时图标/文字同步放大）
            for view in cellViews { view.applyLayoutConfig(layoutConfig) }
            needsLayout = true
        }
    }
    var onAppClick: ((AppInfo) -> Void)?
    var onFolderClick: ((FolderConfig) -> Void)?
    var onBlankClick: (() -> Void)?
    var onDropAppToBlank: ((String) -> Void)?
    var onDropAppToFolder: ((String, FolderConfig) -> Void)?
    var onContextMenu: ((GridItem?) -> NSMenu?)?

    private var cellViews: [AppItemView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.rlaunchAppPath])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 视图同步（复用 cell，避免重建）

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
            cellViews.append(view)
            addSubview(view)
        }
        while cellViews.count > items.count {
            cellViews.removeLast().removeFromSuperview()
        }
        for (i, item) in items.enumerated() {
            cellViews[i].update(kind: kindFor(item: item), config: layoutConfig)
        }
        needsLayout = true
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

    // MARK: 布局

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

    // MARK: 空白点击 / 右键

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onBlankClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(nil) {
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }
    }

    // MARK: 空白拖放目标（文件夹模式：移出文件夹）

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: .rlaunchAppPath) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let path = sender.draggingPasteboard.string(forType: .rlaunchAppPath) else { return false }
        onDropAppToBlank?(path)
        return true
    }
}
