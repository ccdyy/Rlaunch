import Cocoa
import RlaunchCore

/// 网格单元：应用 或 文件夹
enum GridItem {
    case app(AppInfo)
    case folder(FolderConfig)
}

extension NSPasteboard.PasteboardType {
    static let rlaunchAppPath = NSPasteboard.PasteboardType("com.rlaunch.app-path")
}

/// 单个应用/文件夹单元：高清图标 + 下方居中名称；支持点击激活、右键菜单、拖放（源=应用，目标=文件夹）。
final class AppItemView: NSView, NSDraggingSource {

    enum Kind {
        case app(AppInfo)
        case folder(FolderConfig)
    }

    var kind: Kind
    var onActivate: ((Kind) -> Void)?
    var onDropAppToFolder: ((String) -> Void)?
    var onContextMenu: ((Kind) -> NSMenu?)?

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var dragStart: NSPoint?
    private var config = GridLayoutConfig.defaults

    init(kind: Kind, config: GridLayoutConfig) {
        self.kind = kind
        super.init(frame: .zero)
        self.config = config

        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        label.font = .systemFont(ofSize: max(11, config.iconSize * 0.19))
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        addSubview(label)

        if case .folder = kind {
            registerForDraggedTypes([.rlaunchAppPath])
        }
        updateContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(kind: Kind, config: GridLayoutConfig) {
        self.kind = kind
        if case .folder = kind {
            if registeredDraggedTypes.isEmpty { registerForDraggedTypes([.rlaunchAppPath]) }
        } else {
            unregisterDraggedTypes()
        }
        applyLayoutConfig(config)
        updateContent()
        needsLayout = true
    }

    /// 应用布局参数（图标/文字大小随配置变化，全屏时同步放大）
    func applyLayoutConfig(_ config: GridLayoutConfig) {
        self.config = config
        label.font = .systemFont(ofSize: max(11, config.iconSize * 0.19))
        needsLayout = true
    }

    private func updateContent() {
        switch kind {
        case .app(let info):
            imageView.image = IconCache.shared.icon(for: info.path)
            label.stringValue = info.name
            imageView.contentTintColor = nil
        case .folder(let folder):
            let symbol = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "文件夹")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: config.iconSize * 0.55, weight: .regular))
            imageView.image = symbol
            imageView.contentTintColor = .labelColor
            label.stringValue = folder.name
        }
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        let iconSize = config.iconSize
        let labelH = config.labelHeight
        let totalH = iconSize + labelH + 8
        let y = (bounds.height - totalH) / 2
        imageView.frame = NSRect(x: (bounds.width - iconSize) / 2, y: y + labelH + 8, width: iconSize, height: iconSize)
        label.frame = NSRect(x: 2, y: y, width: bounds.width - 4, height: labelH)
    }

    // MARK: 点击 / 拖动

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .app = kind else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, hypot(p.x - start.x, p.y - start.y) > 5 else { return }
        dragStart = nil
        beginDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil {
            dragStart = nil
            onActivate?(kind)
        }
    }

    private func beginDrag(event: NSEvent) {
        guard case .app(let info) = kind else { return }
        let pbItem = NSPasteboardItem()
        pbItem.setString(info.path, forType: .rlaunchAppPath)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        let preview = imageView.image ?? NSImage(size: .zero)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: config.iconSize, height: config.iconSize), contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: 右键菜单

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(kind) {
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }
    }

    // MARK: 文件夹拖放目标

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .folder(let folder) = kind,
              let path = sender.draggingPasteboard.string(forType: .rlaunchAppPath),
              !folder.appPaths.contains(path) else { return [] }
        highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        guard let path = sender.draggingPasteboard.string(forType: .rlaunchAppPath) else { return false }
        onDropAppToFolder?(path)
        return true
    }

    private func highlight(_ on: Bool) {
        wantsLayer = true
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
            : .clear
        layer?.cornerRadius = 12
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
