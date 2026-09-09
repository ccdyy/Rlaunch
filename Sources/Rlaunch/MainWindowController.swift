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

    private(set) var isSelectionMode = false
    private var selectedApps: [AppInfo] = []
    private var selectedAppPaths: Set<String> { Set(selectedApps.map { $0.path }) }
    private static let maxSelectionCount = SelectionTrayView.maxSelectionCount

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
                let trayW: CGFloat = 72
                let maxTrayH = max(120, scrollH - 32)
                let trayH = c.selectionTray.preferredHeight(maxHeight: maxTrayH)
                let trayX = b.width - trayW - 16
                let trayY = max(16, (scrollH - trayH) / 2)
                c.selectionTray.frame = NSRect(x: trayX, y: trayY, width: trayW, height: trayH)
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
        window.isMovableByWindowBackground = true
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
        selectionTray.onRemoveItem = { [weak self] app in self?.removeSelectedApp(app) }
        selectionTray.onCancelAll = { [weak self] in self?.exitSelectionMode() }
        selectionTray.onPlaceToPage = { [weak self] in self?.placeSelectedToCurrentPage() }
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
        if let folder = currentFolder {
            let inFolder = Set(folder.appPaths)
            return apps.filter { inFolder.contains($0.path) }.map { .app($0) }
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

        if !searchQuery.isEmpty || currentFolderID != nil {
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
                        pItems.append(item)
                        visited.insert(item.identifier)
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
        guard currentFolderID == nil && searchQuery.isEmpty else { return }
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

        let paths = selectedAppPaths

        for pItems in pageList {
            let page = GridPageView()
            page.layoutConfig = gridConfig()
            page.items = pItems
            page.isSelectionMode = isSelectionMode
            page.selectedAppPaths = paths

            page.onAppClick = { [weak self] info in self?.activateApp(info) }
            page.onFolderClick = { [weak self] folder in self?.openFolder(folder) }
            page.onBlankClick = { [weak self] in self?.handleBlankClick() }
            page.onDropAppToBlank = { [weak self] path in self?.removeAppFromFolder(path) }
            page.onDropAppToFolder = { [weak self] path, folder in self?.addApp(path, to: folder) }
            page.onContextMenu = { [weak self] item in self?.contextMenu(for: item) }
            page.onLongPressItem = { [weak self] item in self?.handleLongPress(item) }
            page.onToggleSelectItem = { [weak self] item in self?.toggleSelectItem(item) }

            pages.append(page)
            pagesContainer.addSubview(page)
        }

        lastLayoutSize = .zero
        layoutPages()

        let target = min(max(keepPage ?? scrollView.currentPage, 0), pageCount - 1)
        scrollView.scrollToPage(target, animated: false)
        topBar.setPage(target, of: pageCount)
        topBar.setFolderMode(name: currentFolder?.name)
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
        if isSelectionMode { exitSelectionMode() }
        currentFolderID = folder.id
        searchQuery = ""
        topBar.searchField.stringValue = ""
        reloadData()
    }

    private func backToMain() {
        guard currentFolderID != nil else { return }
        currentFolderID = nil
        reloadData()
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
        if isSelectionMode {
            exitSelectionMode()
            return
        }
        if currentFolderID != nil {
            backToMain()
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
        guard case .app(let info) = item else { return }
        if !isSelectionMode {
            enterSelectionMode(initial: info)
        } else {
            toggleSelectItem(item)
        }
    }

    private func enterSelectionMode(initial: AppInfo) {
        isSelectionMode = true
        selectedApps = [initial]
        selectionTray.setItems(selectedApps)
        selectionTray.isHidden = false
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
    }

    private func toggleSelectItem(_ item: GridItem) {
        guard case .app(let info) = item else { return }
        if let idx = selectedApps.firstIndex(where: { $0.path == info.path }) {
            selectedApps.remove(at: idx)
        } else {
            guard selectedApps.count < Self.maxSelectionCount else { return }
            selectedApps.append(info)
        }
        selectionTray.setItems(selectedApps)
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
        if selectedApps.isEmpty { exitSelectionMode() }
    }

    private func removeSelectedApp(_ app: AppInfo) {
        selectedApps.removeAll { $0.path == app.path }
        selectionTray.setItems(selectedApps)
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
        if selectedApps.isEmpty { exitSelectionMode() }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedApps.removeAll()
        selectionTray.isHidden = true
        syncPagesSelectionState()
        window?.contentView?.needsLayout = true
    }

    private func syncPagesSelectionState() {
        let paths = selectedAppPaths
        for page in pages {
            page.isSelectionMode = isSelectionMode
            page.selectedAppPaths = paths
        }
    }

    private func placeSelectedToCurrentPage() {
        guard isSelectionMode, !selectedApps.isEmpty else { return }
        guard currentFolderID == nil, searchQuery.isEmpty else { return }

        var pageList = currentPagesItems()
        let p = scrollView.currentPage
        let perPage = max(config.columns * config.rows, 1)

        while pageList.count <= p { pageList.append([]) }

        let selectedIds = Set(selectedApps.map { "app:\($0.path)" })
        for i in 0..<pageList.count {
            pageList[i].removeAll { item in
                guard let path = item.appPath else { return false }
                return selectedIds.contains("app:\(path)")
            }
        }

        pageList[p].append(contentsOf: selectedApps.map { .app($0) })

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

        while pageList.count > 1 && pageList.last?.isEmpty == true {
            pageList.removeLast()
        }

        savePagesOrder(pageList)
        exitSelectionMode()
        reloadData(keepPage: p)
    }

    // MARK: - 文件夹管理

    private func addApp(_ path: String, to folder: FolderConfig) {
        guard apps.contains(where: { $0.path == path }) else { return }
        guard let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        if !config.folders[idx].appPaths.contains(path) {
            config.folders[idx].appPaths.append(path)
            ConfigStore.save(config)
            reloadData()
        }
    }

    private func removeAppFromFolder(_ path: String) {
        guard let folder = config.folder(containing: path),
              let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        config.folders[idx].appPaths.removeAll { $0 == path }
        ConfigStore.save(config)
        reloadData()
    }

    private func createFolder() {
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.informativeText = "输入文件夹名称，之后可以把应用拖入该文件夹"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "文件夹名称"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let folder = FolderConfig(id: UUID().uuidString, name: name, appPaths: [])
            config.folders.append(folder)
            ConfigStore.save(config)
            reloadData()
            openFolder(folder)
        }
    }

    private func renameFolder(_ folder: FolderConfig) {
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
            guard !name.isEmpty, let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            config.folders[idx].name = name
            ConfigStore.save(config)
            reloadData()
        }
    }

    private func deleteFolder(_ folder: FolderConfig) {
        config.folders.removeAll { $0.id == folder.id }
        if currentFolderID == folder.id { currentFolderID = nil }
        ConfigStore.save(config)
        reloadData()
    }

    // MARK: - 右键菜单

    private final class MenuPayload {
        let path: String
        let folderID: String
        init(path: String, folderID: String) { self.path = path; self.folderID = folderID }
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
                let rename = NSMenuItem(title: "重命名", action: #selector(menuRenameFolder(_:)), keyEquivalent: "")
                rename.representedObject = folder.id
                menu.addItem(rename)
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
        window.isMovableByWindowBackground = true
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
                window.isMovableByWindowBackground = true
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
