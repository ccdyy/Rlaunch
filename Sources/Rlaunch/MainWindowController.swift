import Cocoa
import RlaunchCore

/// borderless 窗口默认 canBecomeKey = false，导致搜索框无法聚焦输入，必须覆盖
private final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {

    private var config: AppConfig
    private var apps: [AppInfo] = []
    private var currentFolderID: String?
    private var searchQuery = ""
    private var pages: [GridPageView] = []
    private var lastLayoutSize: NSSize = .zero
    private(set) var isPseudoFullScreen = false
    private var frameBeforeFullScreen: NSRect = .zero
    private var isScreenTransitioning = false

    private let background = BackgroundView()
    private let topBar = TopBarView()
    private let selectionTray = SelectionTrayView()
    private let scrollView = SnapScrollView()
    private let pagesContainer = NSView()
    private var settingsController: SettingsWindowController?
    private var folderPopoverView: FolderPopoverView?
    private let toastView = ToastView()

    private(set) var isSelectionMode = false
    private var selectedItems: [GridItem] = []
    private var selectedIdentifiers: Set<String> { Set(selectedItems.map { $0.identifier }) }
    private static let maxSelectionCount = SelectionTrayView.maxSelectionCount

    func showToast(_ message: String) {
        guard let root = window?.contentView else { return }
        toastView.show(message: message, in: root)
    }

    // MARK: - 居中轻量浮层 Toast 提示

    private final class ToastView: NSView {
        private let label = NSTextField(labelWithString: "")
        private var hideTimer: Timer?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 16
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.45
            layer?.shadowOffset = CGSize(width: 0, height: -4)
            layer?.shadowRadius = 10

            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.alignment = .center
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(message: String, in parentView: NSView) {
            label.stringValue = message
            label.sizeToFit()
            let padH: CGFloat = 22
            let padV: CGFloat = 9
            let w = label.frame.width + padH * 2
            let h = label.frame.height + padV * 2
            let x = (parentView.bounds.width - w) / 2
            let y = parentView.bounds.height - h - 68 // 顶栏下方居中展示
            frame = NSRect(x: x, y: y, width: w, height: h)
            label.frame = NSRect(x: padH, y: padV, width: label.frame.width, height: label.frame.height)

            if superview == nil {
                alphaValue = 0
                parentView.addSubview(self, positioned: .above, relativeTo: nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    self.animator().alphaValue = 1.0
                }
            } else {
                parentView.addSubview(self, positioned: .above, relativeTo: nil)
                alphaValue = 1.0
            }

            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    self.animator().alphaValue = 0
                } completionHandler: {
                    if self.alphaValue == 0 {
                        self.removeFromSuperview()
                    }
                }
            }
        }
    }

    // MARK: - 根视图

    private final class RootView: NSView {
        weak var controller: MainWindowController?

        override func layout() {
            super.layout()
            guard let c = controller else { return }
            let b = bounds
            let topInset: CGFloat = c.isPseudoFullScreen ? c.fullscreenTopInset() : 0
            c.background.frame = b
            c.topBar.frame = NSRect(x: 0, y: b.height - 56 - topInset, width: b.width, height: 56)

            let scrollH = max(b.height - 56 - topInset, 0)
            c.scrollView.frame = NSRect(x: 0, y: 0, width: b.width, height: scrollH)

            c.selectionTray.isHidden = !c.isSelectionMode
            if c.isSelectionMode {
                let trayW: CGFloat = 84
                let maxTrayH = max(160, scrollH - 32)
                let trayH = c.selectionTray.preferredHeight(maxHeight: maxTrayH)
                let trayX = b.width - trayW - 16
                let trayY = max(16, (scrollH - trayH) / 2)
                c.selectionTray.frame = NSRect(x: trayX, y: trayY, width: trayW, height: trayH)
            }

            if let popover = c.folderPopoverView {
                popover.frame = b
                if popover.superview === self && !c.selectionTray.isHidden {
                    self.addSubview(c.selectionTray, positioned: .above, relativeTo: popover)
                }
            }

            c.didLayoutRoot()
        }
    }

    // MARK: - 初始化

    init(config: AppConfig) {
        self.config = config
        let rect = NSRect(x: 0, y: 0, width: config.windowWidth, height: config.windowHeight)
        let window = LauncherWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 620, height: 440)
        window.collectionBehavior = []
        window.titleVisibility = .hidden
        window.level = Self.windowLevel(isFullscreen: false, screen: nil, windowFrame: rect)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        setupActivationObservers()

        let root = RootView()
        root.controller = self
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = root

        background.setConfig(config)
        root.addSubview(background)
        root.addSubview(topBar)
        root.addSubview(scrollView)
        root.addSubview(selectionTray)
        scrollView.documentView = pagesContainer

        selectionTray.isHidden = true
        wireTopBar()
        wireSelectionTray()

        scrollView.onPageChanged = { [weak self] page in
            guard let self else { return }
            self.topBar.setPage(page, of: self.scrollView.pageCount)
        }
        scrollView.onEscape = { [weak self] in
            guard let self else { return }
            if self.folderPopoverView != nil {
                self.dismissFolderPopover()
                return
            }
            if self.isSelectionMode {
                self.exitSelectionMode()
                return
            }
            if self.isPseudoFullScreen {
                self.togglePseudoFullScreen()
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange), name: ConfigStore.didChange, object: nil)

        startScan()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func wireTopBar() {
        topBar.onRed = { [weak self] in self?.hide() }
        topBar.onYellow = { [weak self] in self?.window?.miniaturize(nil) }
        topBar.onGreen = { [weak self] in self?.togglePseudoFullScreen() }
        topBar.onSearchChanged = { [weak self] q in self?.applySearch(q) }
        topBar.onPrevPage = { [weak self] in
            guard let self else { return }
            self.scrollView.scrollToPage(self.scrollView.currentPage - 1, animated: true)
        }
        topBar.onNextPage = { [weak self] in
            guard let self else { return }
            self.scrollView.scrollToPage(self.scrollView.currentPage + 1, animated: true)
        }
        topBar.onSettings = { [weak self] in self?.openSettings() }
        topBar.onBackToMain = { [weak self] in self?.backToMain() }
        topBar.onRefresh = { [weak self] in self?.rescan() }
    }

    private func wireSelectionTray() {
        selectionTray.onRemoveItem = { [weak self] item in self?.removeSelectedItem(item) }
        selectionTray.onCancelAll = { [weak self] in self?.exitSelectionMode() }
        selectionTray.onPlaceAction = { [weak self] in self?.handleTrayPlaceAction() }
        selectionTray.onCreateFolder = { [weak self] in self?.createFolderFromSelectedApps() }
    }

    // MARK: - 扫描

    private var scanGeneration = 0

    func startScan() {
        scanGeneration += 1
        let gen = scanGeneration
        AppScanner.scan(paths: config.scanPaths, maxDepth: config.recursionDepth) { [weak self] apps in
            guard let self, gen == self.scanGeneration else { return }
            self.apps = apps
            NSLog("Rlaunch: 扫描完成，共 %d 个应用", apps.count)
            self.reloadData()
        }
    }

    private func rescan() {
        IconCache.shared.clear()
        startScan()
    }

    // MARK: - 数据组装

    private func allAvailableItems() -> [GridItem] {
        if !searchQuery.isEmpty {
            return apps.filter { FuzzySearch.matches(name: $0.name, query: searchQuery) }.map { .app($0) }
        }
        let inFolders = config.appPathsInAllFolders()
        var items: [GridItem] = config.folders.map { .folder($0) }
        items += apps.filter { !inFolders.contains($0.path) }.map { .app($0) }
        return items
    }

    /// 分页面数据：主桌面优先使用 pageOrders，各页独立、移走后不跨页填补
    private func currentPagesItems() -> [[GridItem]] {
        let perPage = max(config.columns * config.rows, 1)
        let all = allAvailableItems()

        if !searchQuery.isEmpty {
            if all.isEmpty { return [[]] }
            var res: [[GridItem]] = []
            var i = 0
            while i < all.count {
                res.append(Array(all[i..<min(i + perPage, all.count)]))
                i += perPage
            }
            return res
        }

        var itemMap: [String: GridItem] = [:]
        for item in all { itemMap[item.identifier] = item }
        var appMap: [String: AppInfo] = [:]
        for a in apps { appMap[a.path] = a }

        if !config.pageOrders.isEmpty {
            var pages: [[GridItem]] = []
            var visited = Set<String>()

            for savedPage in config.pageOrders {
                var pItems: [GridItem] = []
                for key in savedPage {
                    if let item = resolveGridItem(orderKey: key, itemMap: itemMap, appMap: appMap) {
                        if !visited.contains(item.identifier) {
                            pItems.append(item)
                            visited.insert(item.identifier)
                        }
                    }
                }
                pages.append(pItems)
            }

            let unvisited = all.filter { !visited.contains($0.identifier) }
            if !unvisited.isEmpty {
                var remaining = unvisited
                if var last = pages.last, last.count < perPage {
                    pages.removeLast()
                    let canTake = min(perPage - last.count, remaining.count)
                    last.append(contentsOf: remaining.prefix(canTake))
                    remaining.removeFirst(canTake)
                    pages.append(last)
                }
                while !remaining.isEmpty {
                    let take = min(perPage, remaining.count)
                    pages.append(Array(remaining.prefix(take)))
                    remaining.removeFirst(take)
                }
            }

            while pages.count > 1 && pages.last?.isEmpty == true {
                pages.removeLast()
            }
            return pages.isEmpty ? [[]] : pages
        }

        if all.isEmpty { return [[]] }
        var res: [[GridItem]] = []
        var i = 0
        while i < all.count {
            res.append(Array(all[i..<min(i + perPage, all.count)]))
            i += perPage
        }
        return res
    }

    private func savePagesOrder(_ newPages: [[GridItem]]) {
        guard searchQuery.isEmpty else { return }
        config.pageOrders = newPages.map { $0.map { $0.identifier } }
        config.itemOrder = config.pageOrders.flatMap { $0 }
        ConfigStore.save(config)
    }

    /// 解析 pageOrders 中的键：兼容 `app:<path>` / `folder:<id>` 与旧版直接存路径
    private func resolveGridItem(
        orderKey: String,
        itemMap: [String: GridItem],
        appMap: [String: AppInfo]
    ) -> GridItem? {
        if let item = itemMap[orderKey] { return item }
        if orderKey.hasPrefix("app:") {
            let path = String(orderKey.dropFirst(4))
            return appMap[path].map { .app($0) }
        }
        if orderKey.hasPrefix("folder:") { return itemMap[orderKey] }
        if let app = appMap[orderKey] { return .app(app) }
        return itemMap["app:\(orderKey)"]
    }

    private var currentFolder: FolderConfig? {
        guard let id = currentFolderID else { return nil }
        return config.folders.first { $0.id == id }
    }

    private func gridConfig() -> GridLayoutConfig {
        if isPseudoFullScreen, let screen = window?.screen ?? NSScreen.main {
            let W = screen.frame.width
            let H = screen.frame.height
            let cols = CGFloat(config.columns)
            let rows = CGFloat(config.rows)
            let scale = CGFloat(config.fullscreenSpacingScale)
            let colSpacing = max(14, CGFloat(config.columnSpacing) * scale)
            let rowSpacing = max(14, CGFloat(config.rowSpacing) * scale)
            let labelH: CGFloat = 36
            let iconForW = (W * 0.88 - (cols - 1) * colSpacing) / cols - 16
            let iconForH = (H * 0.84 - (rows - 1) * rowSpacing) / rows - labelH - 8
            let icon = min(160, max(CGFloat(config.iconSize), min(iconForW, iconForH)))
            return GridLayoutConfig(
                columns: config.columns, rows: config.rows,
                columnSpacing: colSpacing, rowSpacing: rowSpacing, iconSize: icon
            )
        }
        return GridLayoutConfig(
            columns: config.columns, rows: config.rows,
            columnSpacing: CGFloat(config.columnSpacing),
            rowSpacing: CGFloat(config.rowSpacing),
            iconSize: CGFloat(config.iconSize)
        )
    }

    // MARK: - 分页与布局

    private func reloadData(keepPage: Int? = nil) {
        let pageList = currentPagesItems()
        let pageCount = max(pageList.count, 1)
        scrollView.setPageCount(pageCount)

        for page in pages { page.removeFromSuperview() }
        pages.removeAll()

        let ids = selectedIdentifiers
        let isLimitReached = selectedItems.count >= Self.maxSelectionCount

        for (pIndex, pItems) in pageList.enumerated() {
            let page = GridPageView()
            page.layoutConfig = gridConfig()
            page.items = pItems
            page.isSelectionMode = isSelectionMode
            page.selectedIdentifiers = ids
            page.isSelectionDisabled = isLimitReached

            page.onAppClick = { [weak self] info in self?.activateApp(info) }
            page.onFolderClick = { [weak self] folder in self?.openFolder(folder) }
            page.onBlankClick = { [weak self] in self?.handleBlankClick() }
            page.onDropAppToBlank = { [weak self] path in self?.removeAppFromFolder(path) }
            page.onDropAppToFolder = { [weak self] path, folder in self?.addApp(path, to: folder) }
            page.onDropAppsToFolder = { [weak self] paths, folder in self?.addApps(paths, to: folder) }
            page.onContextMenu = { [weak self] item in self?.contextMenu(for: item) }
            page.onLongPressItem = { [weak self] item in self?.handleLongPress(item) }
            page.onToggleSelectItem = { [weak self] item in self?.toggleSelectItem(item) }
            page.onSelectionLimitReached = { [weak self] in
                self?.showToast("最多只能添加 \(Self.maxSelectionCount) 个")
            }
            page.onResizeFolder = { [weak self] folder, cols, rows in
                self?.resizeFolder(folder, cols: cols, rows: rows)
            }
            page.getSelectedItemsForDrag = { [weak self] in
                self?.selectedItems ?? []
            }
            let targetPage = pIndex
            page.onReorderDrop = { [weak self] itemIds, targetIndex in
                self?.handleReorderDrop(itemIds: itemIds, targetPageIndex: targetPage, targetIndex: targetIndex)
            }

            pages.append(page)
            pagesContainer.addSubview(page)
        }

        lastLayoutSize = .zero
        layoutPages()

        let target = min(max(keepPage ?? scrollView.currentPage, 0), pageCount - 1)
        scrollView.scrollToPage(target, animated: false)
        topBar.setPage(target, of: pageCount)
        topBar.setFolderMode(name: nil)
    }

    private func applyGridConfig() {
        let cfg = gridConfig()
        for page in pages { page.layoutConfig = cfg }
        lastLayoutSize = .zero
        didLayoutRoot()
    }

    private func layoutPages() {
        let w = max(scrollView.contentSize.width, 1)
        let h = max(scrollView.contentSize.height, 1)
        pagesContainer.frame = NSRect(x: 0, y: 0, width: CGFloat(pages.count) * w, height: h)
        for (i, page) in pages.enumerated() {
            page.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
        }
    }

    private func didLayoutRoot() {
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0, size != lastLayoutSize else { return }
        lastLayoutSize = size
        let page = scrollView.currentPage
        layoutPages()
        scrollView.scrollToPage(min(page, scrollView.pageCount - 1), animated: false)
        topBar.setPage(scrollView.currentPage, of: scrollView.pageCount)
    }

    // MARK: - 动作

    private func activateApp(_ info: AppInfo) {
        NSWorkspace.shared.open(URL(fileURLWithPath: info.path))
        if config.hideOnLaunch || prefersNormalWindowStacking() || isPseudoFullScreen {
            hide()
        }
    }

    private func openFolder(_ folder: FolderConfig) {
        dismissFolderPopover()

        let appCount = selectedItems.filter { $0.isApp }.count
        let isLimitReached = selectedItems.count >= Self.maxSelectionCount
        let popover = FolderPopoverView(
            folder: folder,
            allApps: apps,
            isSelectionMode: isSelectionMode,
            selectedIdentifiers: selectedIdentifiers,
            pendingPlaceAppsCount: appCount,
            isSelectionDisabled: isLimitReached
        )
        popover.frame = window?.contentView?.bounds ?? .zero
        popover.autoresizingMask = [.width, .height]
        popover.onLaunchApp = { [weak self] app in
            self?.dismissFolderPopover()
            self?.activateApp(app)
        }
        popover.onRemoveApp = { [weak self] app in
            self?.removeAppFromFolder(app.path, folderID: folder.id)
        }
        popover.onRenameFolder = { [weak self] newName in
            self?.renameFolder(folder, newName: newName)
        }
        popover.onDissolveFolder = { [weak self] in
            self?.dismissFolderPopover()
            self?.dissolveFolder(folder)
        }
        popover.onClose = { [weak self] in
            self?.dismissFolderPopover()
        }
        popover.onLongPressApp = { [weak self] app in
            self?.handleLongPress(.app(app))
        }
        popover.onToggleSelectApp = { [weak self] app in
            self?.toggleSelectItem(.app(app))
        }
        popover.onSelectionLimitReached = { [weak self] in
            self?.showToast("最多只能添加 \(Self.maxSelectionCount) 个")
        }
        popover.onPlacePendingApps = { [weak self] in
            self?.placeSelectedAppsToOpenFolder(folderID: folder.id)
        }

        folderPopoverView = popover
        if let root = window?.contentView {
            root.addSubview(popover, positioned: .below, relativeTo: selectionTray)
        }
        selectionTray.setTargetMode(isFolder: appCount > 0)
    }

    private func dismissFolderPopover() {
        guard let popover = folderPopoverView else { return }
        folderPopoverView = nil
        selectionTray.setTargetMode(isFolder: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            popover.animator().alphaValue = 0
        } completionHandler: {
            popover.removeFromSuperview()
        }
    }

    private func backToMain() {
        dismissFolderPopover()
        if currentFolderID != nil {
            currentFolderID = nil
            reloadData()
        }
    }

    private func applySearch(_ query: String) {
        if isSelectionMode { exitSelectionMode() }
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchQuery.isEmpty { currentFolderID = nil }
        reloadData()
    }

    private func handleBlankClick() {
        if let s = settingsController?.window, s.isVisible {
            settingsController?.close()
            return
        }
        if folderPopoverView != nil {
            dismissFolderPopover()
            return
        }
        if isSelectionMode {
            exitSelectionMode()
            return
        }
        if isPseudoFullScreen {
            hide()
            return
        }
        guard !prefersNormalWindowStacking() else { return }
        hide()
    }

    // MARK: - 多选与放置

    private func handleLongPress(_ item: GridItem) {
        if !isSelectionMode {
            enterSelectionMode(initial: item)
        } else {
            toggleSelectItem(item)
        }
    }

    private func enterSelectionMode(initial: GridItem) {
        isSelectionMode = true
        selectedItems = [initial]
        selectionTray.setItems(selectedItems)
        selectionTray.isHidden = false
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
    }

    private func toggleSelectItem(_ item: GridItem) {
        if let idx = selectedItems.firstIndex(where: { $0.identifier == item.identifier }) {
            selectedItems.remove(at: idx)
        } else {
            if selectedItems.count >= Self.maxSelectionCount {
                showToast("最多只能添加 \(Self.maxSelectionCount) 个")
                return
            }

            switch item {
            case .folder(let folder):
                // 选中文件夹：互斥移除该文件夹内部包含的所有应用
                let internalAppIds = Set(folder.appPaths.map { "app:\($0)" })
                selectedItems.removeAll { internalAppIds.contains($0.identifier) }
                selectedItems.append(item)

            case .app(let app):
                // 选中应用：如果选中的文件夹包含了此应用，则互斥移除该文件夹
                selectedItems.removeAll {
                    if case .folder(let f) = $0 {
                        return f.appPaths.contains(app.path)
                    }
                    return false
                }
                selectedItems.append(item)
            }
        }
        selectionTray.setItems(selectedItems)
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
        if selectedItems.isEmpty { exitSelectionMode() }
    }

    private func removeSelectedItem(_ item: GridItem) {
        selectedItems.removeAll { $0.identifier == item.identifier }
        selectionTray.setItems(selectedItems)
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
        if selectedItems.isEmpty { exitSelectionMode() }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedItems.removeAll()
        selectionTray.isHidden = true
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
    }

    private func syncPagesSelectionState() {
        let ids = selectedIdentifiers
        let isLimitReached = selectedItems.count >= Self.maxSelectionCount
        for page in pages {
            page.isSelectionMode = isSelectionMode
            page.selectedIdentifiers = ids
            page.isSelectionDisabled = isLimitReached
        }
        if let pop = folderPopoverView {
            let appCount = selectedItems.filter { $0.isApp }.count
            pop.update(
                folder: pop.folder,
                allApps: apps,
                isSelectionMode: isSelectionMode,
                selectedIdentifiers: ids,
                pendingPlaceAppsCount: appCount,
                isSelectionDisabled: isLimitReached
            )
        }
    }

    private func handleTrayPlaceAction() {
        if let pop = folderPopoverView {
            placeSelectedAppsToOpenFolder(folderID: pop.folder.id)
        } else {
            placeSelectedToCurrentPage()
        }
    }

    private func placeSelectedAppsToOpenFolder(folderID: String) {
        guard let fIdx = config.folders.firstIndex(where: { $0.id == folderID }) else { return }
        let appPaths = selectedItems.compactMap { $0.appPath }
        guard !appPaths.isEmpty else { return }

        // 加入当前文件夹
        for path in appPaths {
            if !config.folders[fIdx].appPaths.contains(path) {
                config.folders[fIdx].appPaths.append(path)
            }
        }

        // 从桌面页面中移除
        let selectedIds = Set(appPaths.map { "app:\($0)" })
        var pageList = currentPagesItems()
        for i in 0..<pageList.count {
            pageList[i].removeAll { item in
                guard let path = item.appPath else { return false }
                return selectedIds.contains("app:\(path)")
            }
        }
        savePagesOrder(pageList)
        compactEmptyPages()

        // 从其他包含这些 App 的文件夹中移出（避免重复）
        for idx in 0..<config.folders.count where config.folders[idx].id != folderID {
            config.folders[idx].appPaths.removeAll { selectedIds.contains("app:\($0)") }
        }
        ConfigStore.save(config)

        // 中转站中移除已放入的 App，保留可能选中的文件夹
        selectedItems.removeAll { selectedIds.contains($0.identifier) }
        selectionTray.setItems(selectedItems)
        syncPagesSelectionState()

        // 刷新当前弹窗
        let remainingApps = selectedItems.filter { $0.isApp }.count
        folderPopoverView?.update(
            folder: config.folders[fIdx],
            allApps: apps,
            isSelectionMode: isSelectionMode,
            selectedIdentifiers: selectedIdentifiers,
            pendingPlaceAppsCount: remainingApps
        )

        reloadData(keepPage: scrollView.currentPage)

        if selectedItems.isEmpty {
            exitSelectionMode()
        }
    }

    private func placeSelectedToCurrentPage() {
        guard isSelectionMode, !selectedItems.isEmpty else { return }
        guard searchQuery.isEmpty else { return }

        var pageList = currentPagesItems()
        let p = scrollView.currentPage
        let perPage = max(config.columns * config.rows, 1)

        while pageList.count <= p { pageList.append([]) }

        let idsToRemove = Set(selectedItems.map { $0.identifier })
        for i in 0..<pageList.count {
            pageList[i].removeAll { idsToRemove.contains($0.identifier) }
        }

        // 选中的 App 和 文件夹 一同放置到当前页
        pageList[p].append(contentsOf: selectedItems)

        var curP = p
        while curP < pageList.count && pageList[curP].count > perPage {
            let overflow = pageList[curP].removeLast()
            let nextP = curP + 1
            if nextP < pageList.count {
                pageList[nextP].insert(overflow, at: 0)
            } else {
                pageList.append([overflow])
            }
            curP += 1
        }

        savePagesOrder(pageList)
        compactEmptyPages()
        exitSelectionMode()
        reloadData(keepPage: p)
    }

    /// 拖动重排序放置：无论文件夹还是app，均严格按照选中的先后顺序插入到目标页的指定位置
    private func handleReorderDrop(itemIds: [String], targetPageIndex: Int, targetIndex: Int) {
        guard searchQuery.isEmpty else { return }

        // 待排序条目：无论和文件夹还是app，顺序均严格按照选中的先后顺序
        let movingItems: [GridItem]
        if isSelectionMode && !selectedItems.isEmpty {
            movingItems = selectedItems
        } else {
            let itemMap = allAvailableItemsMap()
            movingItems = itemIds.compactMap { itemMap[$0] }
        }

        guard !movingItems.isEmpty else { return }

        var pageList = currentPagesItems()
        let p = min(max(0, targetPageIndex), max(0, pageList.count - 1))
        while pageList.count <= p { pageList.append([]) }

        let perPage = max(config.columns * config.rows, 1)

        // 找到目标页移动前的参考物，以保证插入位置精准
        let movingIds = Set(movingItems.map { $0.identifier })
        let curItems = pageList[p]
        let refItem: GridItem? = (targetIndex < curItems.count) ? curItems[targetIndex] : nil

        // 从所有页面中移除这些待移动条目
        for pi in 0..<pageList.count {
            pageList[pi].removeAll { movingIds.contains($0.identifier) }
        }

        // 如果包含从文件夹内拖出来的应用，从该文件夹内剔除
        for path in movingItems.compactMap({ $0.appPath }) {
            for fi in 0..<config.folders.count {
                config.folders[fi].appPaths.removeAll { $0 == path }
            }
        }

        // 计算目标页最终插入索引
        var insertIdx = pageList[p].count
        if let ref = refItem, let foundIdx = pageList[p].firstIndex(where: { $0.identifier == ref.identifier }) {
            insertIdx = foundIdx
        } else {
            insertIdx = min(targetIndex, pageList[p].count)
        }

        // 严格按照选中的先后顺序一次性插入
        pageList[p].insert(contentsOf: movingItems, at: insertIdx)

        // 页面容量顺延溢出处理
        var curP = p
        while curP < pageList.count && pageList[curP].count > perPage {
            let overflow = pageList[curP].removeLast()
            let nextP = curP + 1
            if nextP < pageList.count {
                pageList[nextP].insert(overflow, at: 0)
            } else {
                pageList.append([overflow])
            }
            curP += 1
        }

        savePagesOrder(pageList)
        compactEmptyPages()
        exitSelectionMode()
        reloadData(keepPage: p)
    }

    private func allAvailableItemsMap() -> [String: GridItem] {
        var map: [String: GridItem] = [:]
        for item in allAvailableItems() {
            map[item.identifier] = item
        }
        for a in apps {
            map["app:\(a.path)"] = .app(a)
        }
        for f in config.folders {
            map["folder:\(f.id)"] = .folder(f)
        }
        return map
    }

    // MARK: - 文件夹管理与创建

    /// 选中至少 2 个 App 创建新文件夹（默认名称“文件夹”，名称显示在下方）
    private func createFolderFromSelectedApps() {
        let appPaths = selectedItems.compactMap { $0.appPath }
        guard appPaths.count >= 2 else { return }

        let newFolder = FolderConfig(
            id: UUID().uuidString,
            name: "文件夹",
            appPaths: appPaths,
            spanColumns: 1,
            spanRows: 1
        )

        // 关键：在加入 config.folders 之前先获取现存页面列表，避免 currentPagesItems 把新文件夹作为 unvisited 重复追加到最后一页
        var pageList = currentPagesItems()
        let selectedIds = Set(appPaths.map { "app:\($0)" })
        let p = scrollView.currentPage

        while pageList.count <= p { pageList.append([]) }

        for i in 0..<pageList.count {
            pageList[i].removeAll { item in
                guard let path = item.appPath else { return false }
                return selectedIds.contains("app:\(path)")
            }
        }

        pageList[p].append(.folder(newFolder))

        // 将新文件夹正式纳入配置并持久化
        config.folders.append(newFolder)
        savePagesOrder(pageList)
        compactEmptyPages()
        exitSelectionMode()
        reloadData(keepPage: p)
    }


    private func addApp(_ path: String, to folder: FolderConfig) {
        addApps([path], to: folder)
    }

    private func addApps(_ paths: [String], to folder: FolderConfig) {
        guard let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let validPaths = paths.filter { p in self.apps.contains(where: { $0.path == p }) }
        guard !validPaths.isEmpty else { return }

        let pathSet = Set(validPaths)
        for p in validPaths {
            if !config.folders[idx].appPaths.contains(p) {
                config.folders[idx].appPaths.append(p)
            }
        }

        // 从桌面页面中移除这些 App
        var pageList = currentPagesItems()
        for i in 0..<pageList.count {
            pageList[i].removeAll { item in
                guard let p = item.appPath else { return false }
                return pathSet.contains(p)
            }
        }
        savePagesOrder(pageList)
        compactEmptyPages()
        ConfigStore.save(config)

        // 同步从中转站移除已放入的 App
        selectedItems.removeAll { item in
            guard let p = item.appPath else { return false }
            return pathSet.contains(p)
        }
        selectionTray.setItems(selectedItems)
        syncPagesSelectionState()
        if selectedItems.isEmpty && isSelectionMode {
            exitSelectionMode()
        }

        reloadData(keepPage: scrollView.currentPage)
    }

    private func removeAppFromFolder(_ path: String, folderID: String? = nil) {
        let fID = folderID ?? config.folder(containing: path)?.id
        guard let id = fID, let idx = config.folders.firstIndex(where: { $0.id == id }) else { return }
        config.folders[idx].appPaths.removeAll { $0 == path }

        // 释放回当前页
        var pageList = currentPagesItems()
        var curP = min(scrollView.currentPage, max(0, pageList.count - 1))
        if pageList.isEmpty { pageList = [[]] }
        let perPage = max(config.columns * config.rows, 1)

        while curP < pageList.count && pageList[curP].count >= perPage {
            curP += 1
        }
        if curP >= pageList.count {
            pageList.append([])
        }
        if let appInfo = apps.first(where: { $0.path == path }) {
            pageList[curP].append(.app(appInfo))
        }

        savePagesOrder(pageList)
        compactEmptyPages()
        ConfigStore.save(config)
        reloadData(keepPage: scrollView.currentPage)

        if let pop = folderPopoverView, pop.folder.id == id {
            let remainingApps = selectedItems.filter { $0.isApp }.count
            pop.update(
                folder: config.folders[idx],
                allApps: apps,
                isSelectionMode: isSelectionMode,
                selectedIdentifiers: selectedIdentifiers,
                pendingPlaceAppsCount: remainingApps
            )
        }
    }

    /// 解散文件夹：释放里面的所有应用，从当前页开始放置，放不下放到下一页，不够放新建页；若某页变空则释放该页
    private func dissolveFolder(_ folder: FolderConfig) {
        guard let fIdx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let releasedPaths = config.folders[fIdx].appPaths
        config.folders.remove(at: fIdx)

        var pageList = currentPagesItems()
        let startPage = min(scrollView.currentPage, max(0, pageList.count - 1))
        if pageList.isEmpty { pageList = [[]] }

        // 移除文件夹项
        for i in 0..<pageList.count {
            pageList[i].removeAll { $0.folderID == folder.id }
        }

        let perPage = max(config.columns * config.rows, 1)

        var curP = startPage
        for path in releasedPaths {
            guard let appInfo = apps.first(where: { $0.path == path }) else { continue }
            while curP < pageList.count && pageList[curP].count >= perPage {
                curP += 1
            }
            if curP >= pageList.count {
                pageList.append([])
            }
            pageList[curP].append(.app(appInfo))
        }

        savePagesOrder(pageList)
        compactEmptyPages()
        reloadData(keepPage: startPage)
    }

    private func createFolder() {
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.informativeText = "输入文件夹名称，之后可以把应用拖入该文件夹"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "文件夹"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            let name = trimmed.isEmpty ? "文件夹" : trimmed
            let folder = FolderConfig(id: UUID().uuidString, name: name, appPaths: [])

            let p = scrollView.currentPage
            var pageList = currentPagesItems()
            while pageList.count <= p { pageList.append([]) }
            pageList[p].append(.folder(folder))

            config.folders.append(folder)
            savePagesOrder(pageList)
            ConfigStore.save(config)
            reloadData(keepPage: p)
            openFolder(folder)
        }
    }

    private func renameFolder(_ folder: FolderConfig, newName: String? = nil) {
        if let newName = newName {
            guard let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            config.folders[idx].name = newName.isEmpty ? "文件夹" : newName
            ConfigStore.save(config)
            reloadData(keepPage: scrollView.currentPage)
            return
        }

        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = folder.name
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            config.folders[idx].name = name.isEmpty ? "文件夹" : name
            ConfigStore.save(config)
            reloadData(keepPage: scrollView.currentPage)
        }
    }

    private func resizeFolder(_ folder: FolderConfig, cols: Int, rows: Int) {
        guard let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        config.folders[idx].spanColumns = max(1, cols)
        config.folders[idx].spanRows = max(1, rows)
        ConfigStore.save(config)
        reloadData(keepPage: scrollView.currentPage)
    }

    private func deleteFolder(_ folder: FolderConfig) {
        let alert = NSAlert()
        alert.messageText = "删除文件夹"
        alert.informativeText = "确定删除「\(folder.name)」吗？里面的应用将被释放回主界面。"
        alert.addButton(withTitle: "删除并释放")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            dissolveFolder(folder)
        }
    }

    /// 回收清空的页面（至少保留首页）
    private func compactEmptyPages() {
        guard config.pageOrders.count > 1 else { return }
        let nonEmpty = config.pageOrders.filter { !$0.isEmpty }
        config.pageOrders = nonEmpty.isEmpty ? [[]] : nonEmpty
        config.itemOrder = config.pageOrders.flatMap { $0 }
        ConfigStore.save(config)
    }

    // MARK: - 右键菜单

    private final class MenuPayload {
        let path: String
        let folderID: String
        init(path: String, folderID: String) { self.path = path; self.folderID = folderID }
    }

    private final class FolderSizePayload {
        let folderID: String
        let cols: Int
        let rows: Int
        init(folderID: String, cols: Int, rows: Int) {
            self.folderID = folderID
            self.cols = cols
            self.rows = rows
        }
    }

    private func contextMenu(for item: GridItem?) -> NSMenu? {
        let menu = NSMenu()
        if let item {
            switch item {
            case .app(let info):
                if let folder = config.folder(containing: info.path) {
                    let remove = NSMenuItem(title: "从「\(folder.name)」移出", action: #selector(menuRemoveFromFolder(_:)), keyEquivalent: "")
                    remove.representedObject = info.path
                    menu.addItem(remove)
                } else if !config.folders.isEmpty {
                    let sub = NSMenuItem(title: "移动到文件夹", action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    for f in config.folders {
                        let mi = NSMenuItem(title: f.name, action: #selector(menuMoveToFolder(_:)), keyEquivalent: "")
                        mi.representedObject = MenuPayload(path: info.path, folderID: f.id)
                        submenu.addItem(mi)
                    }
                    sub.submenu = submenu
                    menu.addItem(sub)
                }
            case .folder(let folder):
                let sizeItem = NSMenuItem(title: "网格大小", action: nil, keyEquivalent: "")
                let sizeSub = NSMenu()
                let sizes: [(String, Int, Int)] = [
                    ("1 × 1 (标准)", 1, 1),
                    ("2 × 1 (横向双格)", 2, 1),
                    ("1 × 2 (纵向双格)", 1, 2),
                    ("2 × 2 (大卡片)", 2, 2)
                ]
                for (t, c, r) in sizes {
                    let mi = NSMenuItem(title: t, action: #selector(menuResizeFolderAction(_:)), keyEquivalent: "")
                    mi.representedObject = FolderSizePayload(folderID: folder.id, cols: c, rows: r)
                    if folder.spanColumns == c && folder.spanRows == r {
                        mi.state = .on
                    }
                    sizeSub.addItem(mi)
                }
                sizeItem.submenu = sizeSub
                menu.addItem(sizeItem)

                let rename = NSMenuItem(title: "重命名", action: #selector(menuRenameFolder(_:)), keyEquivalent: "")
                rename.representedObject = folder.id
                menu.addItem(rename)

                let dissolve = NSMenuItem(title: "解散文件夹", action: #selector(menuDissolveFolder(_:)), keyEquivalent: "")
                dissolve.representedObject = folder.id
                menu.addItem(dissolve)

                let del = NSMenuItem(title: "删除文件夹", action: #selector(menuDeleteFolder(_:)), keyEquivalent: "")
                del.representedObject = folder.id
                menu.addItem(del)
            }
        } else {
            let new = NSMenuItem(title: "新建文件夹", action: #selector(menuNewFolder(_:)), keyEquivalent: "")
            menu.addItem(new)
            let rescan = NSMenuItem(title: "重新扫描应用", action: #selector(menuRescan(_:)), keyEquivalent: "")
            menu.addItem(rescan)
        }
        menu.items.forEach { $0.target = self }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func menuNewFolder(_ sender: Any?) { createFolder() }
    @objc private func menuRescan(_ sender: Any?) { rescan() }
    @objc private func menuRemoveFromFolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { removeAppFromFolder(path) }
    }
    @objc private func menuMoveToFolder(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload,
              let folder = config.folders.first(where: { $0.id == payload.folderID }) else { return }
        addApp(payload.path, to: folder)
    }
    @objc private func menuRenameFolder(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String,
           let folder = config.folders.first(where: { $0.id == id }) {
            renameFolder(folder)
        }
    }
    @objc private func menuResizeFolderAction(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? FolderSizePayload,
              let folder = config.folders.first(where: { $0.id == p.folderID }) else { return }
        resizeFolder(folder, cols: p.cols, rows: p.rows)
    }
    @objc private func menuDissolveFolder(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String,
           let folder = config.folders.first(where: { $0.id == id }) {
            dissolveFolder(folder)
        }
    }
    @objc private func menuDeleteFolder(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String,
           let folder = config.folders.first(where: { $0.id == id }) {
            deleteFolder(folder)
        }
    }

    // MARK: - 设置

    func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onRescan = { [weak self] in self?.rescan() }
            settingsController = controller
        }
        settingsController?.show(relativeTo: window)
        settingsController?.window?.level = window?.level ?? .normal
    }

    // MARK: - 显示 / 隐藏

    var isVisible: Bool { window?.isVisible == true }

    var isFrontmost: Bool {
        guard isVisible else { return false }
        return NSApp.isActive && window?.isKeyWindow == true
    }

    func show() {
        guard let window else { return }
        applyWindowLevel()
        if !isPseudoFullScreen {
            window.contentView?.layer?.cornerRadius = 18
        }
        // 在让窗口显示在屏幕上之前，先确保透明度为 0 并完成全部布局，彻底杜绝闪烁残影
        window.alphaValue = 0
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 1
        }
        window.makeFirstResponder(scrollView)
    }

    func showFullScreen() {
        guard let window else { return }
        if !isPseudoFullScreen {
            if let screen = window.screen ?? NSScreen.main {
                frameBeforeFullScreen = window.frame
                window.setFrame(Self.pseudoFullScreenFrame(for: screen), display: false)
            }
            isPseudoFullScreen = true
            window.isMovableByWindowBackground = false
            window.contentView?.layer?.cornerRadius = 0
            topBar.traffic.isHidden = true
            topBar.setFullscreen(true)
            applyWindowLevel()
            window.contentView?.layoutSubtreeIfNeeded()
            applyGridConfig()
        }
        show()
    }

    func hide() {
        if folderPopoverView != nil { dismissFolderPopover() }
        if isPseudoFullScreen { restoreFromFullScreen() }
        if isSelectionMode { exitSelectionMode() }
        window?.orderOut(nil)
        window?.alphaValue = 0
    }

    private func restoreFromFullScreen() {
        guard let window else { return }
        if frameBeforeFullScreen != .zero {
            window.setFrame(frameBeforeFullScreen, display: false)
        }
        isPseudoFullScreen = false
        window.isMovableByWindowBackground = false
        window.contentView?.layer?.cornerRadius = 18
        window.contentView?.layer?.masksToBounds = true
        topBar.traffic.isHidden = false
        topBar.setFullscreen(false)
        applyWindowLevel()
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        applyGridConfig()
    }

    func toggle() {
        if isFrontmost { hide() } else { show() }
    }

    @objc private func configDidChange() {
        let page = scrollView.currentPage
        config = ConfigStore.load()
        ThemeManager.current = config.theme
        background.setConfig(config)
        topBar.setFolderMode(name: currentFolder?.name)
        reloadData(keepPage: page)
    }

    // MARK: - 窗口层级

    private func prefersNormalWindowStacking() -> Bool {
        guard let window, let screen = window.screen ?? NSScreen.main else { return false }
        let vf = screen.visibleFrame
        if vf.height <= 1200 || vf.width <= 1600 { return true }
        let windowArea = window.frame.width * window.frame.height
        let screenArea = max(vf.width * vf.height, 1)
        return windowArea / screenArea >= 0.7
    }

    private static func windowLevel(isFullscreen: Bool, screen: NSScreen?, windowFrame: NSRect) -> NSWindow.Level {
        if isFullscreen {
            return NSWindow.Level(
                rawValue: NSWindow.Level.RawValue(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        }
        let s = screen ?? NSScreen.main
        let useNormal: Bool = {
            guard let s else { return false }
            let vf = s.visibleFrame
            if vf.height <= 1200 || vf.width <= 1600 { return true }
            let windowArea = windowFrame.width * windowFrame.height
            let screenArea = max(vf.width * vf.height, 1)
            return windowArea / screenArea >= 0.7
        }()
        return useNormal ? .normal : .floating
    }

    private static func pseudoFullScreenFrame(for screen: NSScreen) -> NSRect {
        screen.frame
    }

    func fullscreenTopInset() -> CGFloat {
        guard isPseudoFullScreen, let screen = window?.screen ?? NSScreen.main else { return 0 }
        return screen.safeAreaInsets.top
    }

    private func applyWindowLevel() {
        guard let window else { return }
        window.level = Self.windowLevel(
            isFullscreen: isPseudoFullScreen, screen: window.screen, windowFrame: window.frame)
        if let settingsWindow = settingsController?.window, settingsWindow.isVisible {
            settingsWindow.level = window.level
        }
    }

    private func setupActivationObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(otherAppDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func otherAppDidActivate(_ note: Notification) {
        guard window?.isVisible == true else { return }
        guard isPseudoFullScreen || prefersNormalWindowStacking() else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        deferToOtherApps()
    }

    private func deferToOtherApps() {
        guard window?.isVisible == true else { return }
        if settingsController?.window?.isVisible == true {
            settingsController?.close()
        }
        if isPseudoFullScreen || (window.map { w in
            guard let screen = w.screen ?? NSScreen.main else { return false }
            let vf = screen.visibleFrame
            let ratio = (w.frame.width * w.frame.height) / max(vf.width * vf.height, 1)
            return ratio >= 0.7
        } ?? false) {
            hide()
            return
        }
        window?.level = .normal
        window?.orderBack(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        guard isPseudoFullScreen || prefersNormalWindowStacking() else { return }
        if shouldSkipDeferOnFocusLoss() { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible, !window.isKeyWindow else { return }
            guard self.isPseudoFullScreen || self.prefersNormalWindowStacking(),
                  !self.shouldSkipDeferOnFocusLoss() else { return }
            self.deferToOtherApps()
        }
    }

    private func shouldSkipDeferOnFocusLoss() -> Bool {
        if settingsController?.window?.isVisible == true { return true }
        if NSApp.modalWindow != nil { return true }
        if window?.attachedSheet != nil { return true }
        if window?.isMiniaturized == true { return true }
        return false
    }

    func togglePseudoFullScreen() {
        guard let window, !isScreenTransitioning else { return }
        isScreenTransitioning = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, let window = self.window else { return }
            if self.isPseudoFullScreen {
                window.setFrame(self.frameBeforeFullScreen, display: false)
                self.isPseudoFullScreen = false
                self.applyWindowLevel()
                window.isMovableByWindowBackground = false
                window.contentView?.layer?.cornerRadius = 18
                self.topBar.traffic.isHidden = false
                self.topBar.setFullscreen(false)
            } else {
                self.frameBeforeFullScreen = window.frame
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(Self.pseudoFullScreenFrame(for: screen), display: false)
                }
                self.isPseudoFullScreen = true
                self.applyWindowLevel()
                window.isMovableByWindowBackground = false
                window.contentView?.layer?.cornerRadius = 0
                self.topBar.traffic.isHidden = true
                self.topBar.setFullscreen(true)
            }
            window.contentView?.layoutSubtreeIfNeeded()
            self.applyGridConfig()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                self?.isScreenTransitioning = false
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let w = window, !isPseudoFullScreen else { return }
        config.windowWidth = Double(w.frame.width)
        config.windowHeight = Double(w.frame.height)
        ConfigStore.save(config)
        applyWindowLevel()
    }
}
