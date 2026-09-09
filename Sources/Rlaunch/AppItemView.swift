import Cocoa
import RlaunchCore

/// 网格单元：应用 或 文件夹
enum GridItem: Equatable {
    case app(AppInfo)
    case folder(FolderConfig)

    var identifier: String {
        switch self {
        case .app(let info): return "app:\(info.path)"
        case .folder(let folder): return "folder:\(folder.id)"
        }
    }

    var appPath: String? {
        if case .app(let info) = self { return info.path }
        return nil
    }
}

extension NSPasteboard.PasteboardType {
    static let rlaunchAppPath = NSPasteboard.PasteboardType("com.rlaunch.app-path")
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
            NSColor.black.withAlphaComponent(0.45).setFill()
            circlePath.fill()
            NSColor.white.withAlphaComponent(0.75).setStroke()
            circlePath.lineWidth = 1.5
            circlePath.stroke()
        }
    }
}

/// 单个应用/文件夹单元：高清图标 + 下方居中名称；支持长按多选、点击切换、右键菜单、拖放。
final class AppItemView: NSView, NSDraggingSource {

    enum Kind {
        case app(AppInfo)
        case folder(FolderConfig)
    }

    var kind: Kind
    var onActivate: ((Kind) -> Void)?
    var onDropAppToFolder: ((String) -> Void)?
    var onContextMenu: ((Kind) -> NSMenu?)?
    var onLongPress: ((Kind) -> Void)?
    var onToggleSelect: ((Kind) -> Void)?

    var isSelectionMode: Bool = false {
        didSet { updateSelectionStyle() }
    }
    var isItemSelected: Bool = false {
        didSet { updateSelectionStyle() }
    }

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badgeView = SelectionBadgeView()
    private var dragStart: NSPoint?
    private var longPressTimer: Timer?
    private var didTriggerLongPress = false
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

        badgeView.isHidden = true
        addSubview(badgeView)

        if case .folder = kind {
            registerForDraggedTypes([.rlaunchAppPath])
        }
        updateContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(kind: Kind, config: GridLayoutConfig, isSelectionMode: Bool, isItemSelected: Bool) {
        self.kind = kind
        self.isSelectionMode = isSelectionMode
        self.isItemSelected = isItemSelected
        if case .folder = kind {
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

    private func updateSelectionStyle() {
        let showBadge = isSelectionMode && isApp
        badgeView.isHidden = !showBadge
        badgeView.isSelected = isItemSelected

        if isSelectionMode && isItemSelected && isApp {
            imageView.alphaValue = 0.85
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            layer?.cornerRadius = 12
        } else {
            imageView.alphaValue = 1.0
            layer?.masksToBounds = false
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private var isApp: Bool {
        if case .app = kind { return true }
        return false
    }

    override func layout() {
        super.layout()
        let iconSize = config.iconSize
        let labelH = config.labelHeight
        let totalH = iconSize + labelH + 8
        let y = (bounds.height - totalH) / 2
        let iconX = (bounds.width - iconSize) / 2
        let iconY = y + labelH + 8
        imageView.frame = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
        label.frame = NSRect(x: 2, y: y, width: bounds.width - 4, height: labelH)

        let badgeSize: CGFloat = 20
        let badgeX = min(bounds.width - badgeSize - 2, iconX + iconSize - badgeSize + 2)
        let badgeY = min(bounds.height - badgeSize - 2, iconY + iconSize - badgeSize + 2)
        badgeView.frame = NSRect(x: badgeX, y: badgeY, width: badgeSize, height: badgeSize)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        didTriggerLongPress = false
        longPressTimer?.invalidate()

        if !isSelectionMode, isApp {
            let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.didTriggerLongPress = true
                self.onLongPress?(self.kind)
            }
            RunLoop.main.add(timer, forMode: .common)
            longPressTimer = timer
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isSelectionMode else { return }
        guard case .app = kind else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, hypot(p.x - start.x, p.y - start.y) > 5 else { return }
        longPressTimer?.invalidate()
        longPressTimer = nil
        dragStart = nil
        beginDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        if didTriggerLongPress {
            didTriggerLongPress = false
            dragStart = nil
            return
        }

        if dragStart != nil {
            dragStart = nil
            if isSelectionMode, isApp {
                onToggleSelect?(kind)
            } else {
                onActivate?(kind)
            }
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

    override func rightMouseDown(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        if let menu = onContextMenu?(kind) {
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }
    }

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
            : (isSelectionMode && isItemSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : .clear)
        layer?.cornerRadius = 12
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
