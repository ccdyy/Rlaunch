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
    private var searchQuery = ""
    private var pages: [GridPageView] = []
    private var lastLayoutSize: NSSize = .zero
    private(set) var isPseudoFullScreen = false
    private var frameBeforeFullScreen: NSRect = .zero
    private var isScreenTransitioning = false
    private var frameSaveTimer: Timer?

    private let background = BackgroundView()
    private let topBar = TopBarView()
    private let selectionTray = SelectionTrayView()
    private let scrollView = SnapScrollView()
    private let pagesContainer = NSView()
    private var settingsController: SettingsWindowController?
    private var folderPopoverView: FolderPopoverView?
    private let toastView = ToastView()
    private let emptyStateView = EmptyStateView()

    private(set) var isSelectionMode = false
    private var selectedItems: [GridItem] = []
    private var selectedIdentifiers: Set<String> { Set(selectedItems.map { $0.identifier }) }
    private static let maxSelectionCount = SelectionTrayView.maxSelectionCount
    /// 当前运行中的应用 bundleID（用于在图标上显示运行小圆点）
    private var runningBundleIDs: Set<String> = []
    /// 键盘焦点（方向键导航）
    private var focusPage: Int?
    private var focusedIdentifier: String?

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
            // 用 .common 模式：窗口拖动/滚动等 tracking 期间计时器依然生效
            let timer = Timer(timeInterval: 1.8, repeats: false) { [weak self] _ in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    self.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    guard let self, self.alphaValue == 0 else { return }
                    self.removeFromSuperview()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            hideTimer = timer
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
        let rect = Self.initialWindowFrame(config: config)
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
        scrollView.onTextInput = { [weak self] text in self?.beginSearch(with: text) }
        scrollView.onFocusSearch = { [weak self] in self?.focusSearchField() }
        scrollView.onConfirm = { [weak self] in self?.activateFocusedOrFirstResult() }
        scrollView.onMoveFocus = { [weak self] dx, dy in self?.moveFocus(dx: dx, dy: dy) }

        emptyStateView.onAction = { [weak self] in self?.rescan() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange), name: ConfigStore.didChange, object: nil)
        observeRunningApplications()

        startScan()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        frameSaveTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - 运行中应用指示

    private func observeRunningApplications() {
        refreshRunningApplications()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(runningAppsChanged), name: name, object: nil)
        }
    }

    @objc private func runningAppsChanged() {
        refreshRunningApplications()
    }

    private func refreshRunningApplications() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        guard ids != runningBundleIDs else { return }
        runningBundleIDs = ids
        syncRunningState()
    }

    private func syncRunningState() {
        for page in pages { page.runningBundleIDs = runningBundleIDs }
    }

    /// 窗口初始位置：优先恢复上次位置，位置失效（显示器变更/越界）或首次启动时居中显示。
    private static func initialWindowFrame(config: AppConfig) -> NSRect {
        let size = NSSize(
            width: max(config.windowWidth, 620),
            height: max(config.windowHeight, 440)
        )
        if let x = config.windowX, let y = config.windowY {
            let saved = NSRect(x: x, y: y, width: size.width, height: size.height)
            let isReachable = NSScreen.screens.contains { screen in
                let overlap = screen.visibleFrame.intersection(saved)
                return overlap.width >= 160 && overlap.height >= 120
            }
            if isReachable { return saved }
        }
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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
        topBar.onRefresh = { [weak self] in self?.rescan() }
        topBar.onSearchSubmit = { [weak self] in self?.activateFocusedOrFirstResult() }
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
        let visible = config.visibleApps(from: apps)
        if !searchQuery.isEmpty {
            return visible.filter { FuzzySearch.matches(name: $0.name, query: searchQuery) }.map { .app($0) }
        }
        let inFolders = config.appPathsInAllFolders()
        var items: [GridItem] = config.folders.map { .folder($0) }
        items += visible.filter { !inFolders.contains($0.path) }.map { .app($0) }
        return items
    }

    /// 分页面数据：主桌面优先使用 pageOrders，各页独立、移走后不跨页填补。
    /// 分页容量统一交给 `PageComposer`（按网格实际格数计算），与布局使用同一套装箱算法。
    private func currentPagesItems() -> [[GridItem]] {
        let cols = max(config.columns, 1)
        let rows = max(config.rows, 1)
        let all = allAvailableItems()

        // 搜索结果是临时视图，直接按容量切页，不参与 pageOrders 布局
        if !searchQuery.isEmpty {
            return PageComposer.chunk(all, columns: cols, rows: rows)
        }

        var itemMap: [String: GridItem] = [:]
        for item in all { itemMap[item.identifier] = item }
        var appMap: [String: AppInfo] = [:]
        for a in apps { appMap[a.path] = a }

        guard !config.pageOrders.isEmpty else {
            return PageComposer.chunk(all, columns: cols, rows: rows)
        }

        // 按 pageOrders 解析出各页（空数组表示用户刻意留白的页面）
        var pages: [[GridItem]] = []
        var visited = Set<String>()
        for savedPage in config.pageOrders {
            var pItems: [GridItem] = []
            for key in savedPage {
                guard let item = resolveGridItem(orderKey: key, itemMap: itemMap, appMap: appMap),
                      !visited.contains(item.identifier) else { continue }
                pItems.append(item)
                visited.insert(item.identifier)
            }
            pages.append(pItems)
        }

        let unvisited = all.filter { !visited.contains($0.identifier) }
        return PageComposer.compose(savedPages: pages, unvisited: unvisited, columns: cols, rows: rows)
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

        // 焦点条目已不存在（搜索、隐藏、删除等）时清除焦点，避免高亮停留在不存在的条目上
        if let id = focusedIdentifier,
           !pageList.contains(where: { page in page.contains(where: { $0.identifier == id }) }) {
            focusPage = nil
            focusedIdentifier = nil
        }

        let ids = selectedIdentifiers
        let isLimitReached = selectedItems.count >= Self.maxSelectionCount
        let cfg = gridConfig()

        // 复用已有页面视图（页面索引与页号一一对应且只从尾部增删）：
        // 搜索输入、设置变更只需更新内容，避免整页重建导致的卡顿与瞬时闪烁。
        while pages.count > pageList.count {
            pages.removeLast().removeFromSuperview()
        }
        while pages.count < pageList.count {
            let page = makePage(at: pages.count)
            pages.append(page)
            pagesContainer.addSubview(page)
        }
        for (pIndex, pItems) in pageList.enumerated() {
            let page = pages[pIndex]
            page.layoutConfig = cfg
            page.items = pItems
            page.runningBundleIDs = runningBundleIDs
            page.isSelectionMode = isSelectionMode
            page.selectedIdentifiers = ids
            page.isSelectionDisabled = isLimitReached
            page.focusedIdentifier = (pIndex == focusPage) ? focusedIdentifier : nil
        }

        lastLayoutSize = .zero
        layoutPages()

        let target = min(max(keepPage ?? scrollView.currentPage, 0), pageCount - 1)
        scrollView.scrollToPage(target, animated: false)
        topBar.setPage(target, of: pageCount)
        updateEmptyState(pageList: pageList)
    }

    /// 空状态提示：全部无应用 / 搜索无结果时给出明确指引
    private func updateEmptyState(pageList: [[GridItem]]) {
        let totalItems = pageList.reduce(0) { $0 + $1.count }
        guard totalItems == 0 else {
            emptyStateView.hide()
            return
        }
        guard let root = window?.contentView else { return }

        if !searchQuery.isEmpty {
            emptyStateView.show(
                symbol: "magnifyingglass",
                title: L10n.t("没有匹配的应用"),
                detail: L10n.t("换个关键词试试，或按 Esc 清空搜索"),
                actionTitle: nil,
                in: root)
        } else {
            emptyStateView.show(
                symbol: "square.grid.2x2",
                title: L10n.t("还没有扫描到应用"),
                detail: L10n.t("请检查「设置 → 应用扫描」中的目录是否正确"),
                actionTitle: L10n.t("重新扫描"),
                in: root)
        }
    }

    /// 创建一页网格视图并接好全部回调；页面索引在复用期间保持不变，故可安全捕获。
    private func makePage(at index: Int) -> GridPageView {
        let page = GridPageView()
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
            self?.showToast(L10n.f("最多只能添加 %d 个", Self.maxSelectionCount))
        }
        page.onResizeFolder = { [weak self] folder, cols, rows in
            self?.resizeFolder(folder, cols: cols, rows: rows)
        }
        page.getSelectedItemsForDrag = { [weak self] in
            self?.selectedItems ?? []
        }
        page.onReorderDrop = { [weak self] itemIds, targetIndex in
            self?.handleReorderDrop(itemIds: itemIds, targetPageIndex: index, targetIndex: targetIndex)
        }
        return page
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
        guard FileManager.default.fileExists(atPath: info.path) else {
            // 应用已被移动或删除：给出反馈并自动重扫，避免「点了没反应」
            showToast(L10n.f("「%@」已不存在，正在重新扫描…", info.name))
            rescan()
            return
        }
        NSWorkspace.shared.open(
            URL(fileURLWithPath: info.path),
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard let error else { return }
            self?.showToast(L10n.f("无法打开「%@」：%@", info.name, error.localizedDescription))
        }
        if config.hideOnLaunch || prefersNormalWindowStacking() || isPseudoFullScreen {
            hide()
        }
    }

    /// 回车：优先打开键盘焦点条目；搜索状态下退化为打开首个结果
    private func activateFocusedOrFirstResult() {
        if let id = focusedIdentifier,
           let item = currentPagesItems().flatMap({ $0 }).first(where: { $0.identifier == id }) {
            switch item {
            case .app(let info): activateApp(info)
            case .folder(let folder): openFolder(folder)
            }
            return
        }
        guard !searchQuery.isEmpty else { return }
        guard let first = currentPagesItems().first?.first else { return }
        switch first {
        case .app(let info): activateApp(info)
        case .folder(let folder): openFolder(folder)
        }
    }

    // MARK: - 键盘焦点导航

    /// 方向键导航：已有焦点时在网格中移动（横向到边界则翻页）；
    /// 尚无焦点时 `↑/↓` 建立焦点，`←/→` 保持原有的翻页手感。
    private func moveFocus(dx: Int, dy: Int) {
        let cols = max(config.columns, 1)
        let rows = max(config.rows, 1)
        let pageList = currentPagesItems()
        guard !pageList.isEmpty else { return }

        let page = min(max(focusPage ?? scrollView.currentPage, 0), pageList.count - 1)
        let items = pageList[page]
        guard !items.isEmpty else { return }

        guard focusPage == page,
              let id = focusedIdentifier,
              let current = items.firstIndex(where: { $0.identifier == id }) else {
            if dy != 0 {
                setFocus(page: page, identifier: (dy < 0 ? items.last : items.first)?.identifier)
            } else {
                scrollView.scrollToPage(page + dx, animated: true)
            }
            return
        }

        let placements = GridPacker.placements(for: items, columns: cols, rows: rows)
        if let target = GridPacker.neighborIndex(from: current, dx: dx, dy: dy, placements: placements) {
            setFocus(page: page, identifier: items[target].identifier)
            return
        }
        // 横向到边界则翻页，纵向到边界保持不动
        if dx > 0, page + 1 < pageList.count {
            setFocus(page: page + 1, identifier: pageList[page + 1].first?.identifier)
        } else if dx < 0, page > 0 {
            setFocus(page: page - 1, identifier: pageList[page - 1].last?.identifier)
        }
    }

    private func setFocus(page: Int, identifier: String?) {
        focusPage = identifier == nil ? nil : page
        focusedIdentifier = identifier
        for (i, p) in pages.enumerated() {
            p.focusedIdentifier = (i == focusPage) ? focusedIdentifier : nil
        }
        if identifier != nil, page != scrollView.currentPage {
            scrollView.scrollToPage(page, animated: true)
        }
    }

    private func clearFocus() {
        guard focusedIdentifier != nil else { return }
        setFocus(page: 0, identifier: nil)
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
            self?.confirmDissolveFolder(folder)
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
            self?.showToast(L10n.f("最多只能添加 %d 个", Self.maxSelectionCount))
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

    private func applySearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchQuery else { return }
        if isSelectionMode { exitSelectionMode() }
        clearFocus()
        searchQuery = trimmed
        reloadData(keepPage: 0)
    }

    /// 直接输入即搜索：把焦点交给搜索框，并带上已输入的首个字符
    private func beginSearch(with initialText: String) {
        let field = topBar.searchField
        window?.makeFirstResponder(field)
        field.stringValue = initialText
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (initialText as NSString).length, length: 0)
        }
        applySearch(initialText)
    }

    /// ⌘F：聚焦搜索框并全选已有内容
    private func focusSearchField() {
        let field = topBar.searchField
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
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
                showToast(L10n.f("最多只能添加 %d 个", Self.maxSelectionCount))
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
        let pageList = PageComposer.removing(selectedIds, from: currentPagesItems())
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

        let p = scrollView.currentPage
        let pageList = PageComposer.appending(
            selectedItems,
            toPage: p,
            in: currentPagesItems(),
            columns: max(config.columns, 1),
            rows: max(config.rows, 1)
        )

        savePagesOrder(pageList)
        compactEmptyPages()
        exitSelectionMode()
        reloadData(keepPage: p)
    }

    /// 拖动重排序放置：无论文件夹还是应用，均严格按照选中的先后顺序插入到目标页的指定位置
    private func handleReorderDrop(itemIds: [String], targetPageIndex: Int, targetIndex: Int) {
        guard searchQuery.isEmpty else { return }

        // 待排序条目：无论文件夹还是应用，顺序均严格按照选中的先后顺序
        let movingItems: [GridItem]
        if isSelectionMode && !selectedItems.isEmpty {
            movingItems = selectedItems
        } else {
            let itemMap = allAvailableItemsMap()
            movingItems = itemIds.compactMap { itemMap[$0] }
        }
        guard !movingItems.isEmpty else { return }

        let p = max(0, targetPageIndex)
        let pageList = PageComposer.move(
            movingItems,
            toPage: p,
            at: targetIndex,
            in: currentPagesItems(),
            columns: max(config.columns, 1),
            rows: max(config.rows, 1)
        )

        // 如果包含从文件夹内拖出来的应用，从该文件夹内剔除
        for path in movingItems.compactMap({ $0.appPath }) {
            for fi in 0..<config.folders.count {
                config.folders[fi].appPaths.removeAll { $0 == path }
            }
        }

        savePagesOrder(pageList)
        compactEmptyPages()
        exitSelectionMode()
        reloadData(keepPage: min(p, max(pageList.count - 1, 0)))
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
            name: L10n.t("文件夹"),
            appPaths: appPaths,
            spanColumns: 1,
            spanRows: 1
        )

        // 关键：在加入 config.folders 之前先获取现存页面列表，避免 currentPagesItems 把新文件夹作为 unvisited 重复追加到最后一页
        let selectedIds = Set(appPaths.map { "app:\($0)" })
        let p = scrollView.currentPage
        let pageList = PageComposer.appending(
            [.folder(newFolder)],
            toPage: p,
            in: PageComposer.removing(selectedIds, from: currentPagesItems()),
            columns: max(config.columns, 1),
            rows: max(config.rows, 1)
        )

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
        let appIds = Set(validPaths.map { "app:\($0)" })
        let pageList = PageComposer.removing(appIds, from: currentPagesItems())
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

        // 释放回当前页（逐页找空位，放不下自动新建页）
        var pageList = PageComposer.removing(["app:\(path)"], from: currentPagesItems())
        if let appInfo = apps.first(where: { $0.path == path }) {
            pageList = PageComposer.release(
                [.app(appInfo)],
                fromPage: scrollView.currentPage,
                in: pageList,
                columns: max(config.columns, 1),
                rows: max(config.rows, 1)
            )
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

        let startPage = max(scrollView.currentPage, 0)
        // 先移除文件夹本身，再把内部应用按容量释放到当前页及后续页
        var pageList = PageComposer.removing(["folder:\(folder.id)"], from: currentPagesItems())
        let released = releasedPaths.compactMap { path in
            apps.first(where: { $0.path == path }).map { GridItem.app($0) }
        }
        pageList = PageComposer.release(
            released,
            fromPage: startPage,
            in: pageList,
            columns: max(config.columns, 1),
            rows: max(config.rows, 1)
        )

        savePagesOrder(pageList)
        compactEmptyPages()
        reloadData(keepPage: max(startPage, 0))
    }

    private func createFolder() {
        let p = scrollView.currentPage
        presentPrompt(
            title: L10n.t("新建文件夹"),
            message: L10n.t("输入文件夹名称，之后可以把应用拖入该文件夹"),
            placeholder: L10n.t("文件夹"),
            confirmTitle: L10n.t("创建")
        ) { [weak self] input in
            guard let self else { return }
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            let folder = FolderConfig(id: UUID().uuidString,
                                      name: trimmed.isEmpty ? L10n.t("文件夹") : trimmed,
                                      appPaths: [])

            var pageList = self.currentPagesItems()
            while pageList.count <= p { pageList.append([]) }
            pageList[p].append(.folder(folder))

            self.config.folders.append(folder)
            self.savePagesOrder(pageList)
            ConfigStore.save(self.config)
            self.reloadData(keepPage: p)
            self.openFolder(folder)
        }
    }

    private func renameFolder(_ folder: FolderConfig, newName: String? = nil) {
        if let newName = newName {
            guard let idx = config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            config.folders[idx].name = newName.isEmpty ? L10n.t("文件夹") : newName
            ConfigStore.save(config)
            reloadData(keepPage: scrollView.currentPage)
            return
        }

        presentPrompt(
            title: L10n.t("重命名文件夹"),
            placeholder: L10n.t("文件夹"),
            defaultValue: folder.name,
            confirmTitle: L10n.t("确定")
        ) { [weak self] input in
            guard let self, let idx = self.config.folders.firstIndex(where: { $0.id == folder.id }) else { return }
            let name = input.trimmingCharacters(in: .whitespaces)
            self.config.folders[idx].name = name.isEmpty ? L10n.t("文件夹") : name
            ConfigStore.save(self.config)
            self.reloadData(keepPage: self.scrollView.currentPage)
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
        presentPrompt(
            title: L10n.t("删除文件夹"),
            message: L10n.f("确定删除「%@」吗？里面的应用将被释放回主界面。", folder.name),
            confirmTitle: L10n.t("删除并释放"),
            showsTextField: false
        ) { [weak self] _ in
            self?.dissolveFolder(folder)
        }
    }

    /// 文件夹弹窗里的「解散文件夹」：先收起弹窗，再用窗口内浮层确认
    private func confirmDissolveFolder(_ folder: FolderConfig) {
        presentPrompt(
            title: L10n.t("解散文件夹"),
            message: L10n.f("确定要解散「%@」吗？里面的应用将被释放回主界面。", folder.name),
            confirmTitle: L10n.t("解散"),
            showsTextField: false
        ) { [weak self] _ in
            guard let self else { return }
            self.dismissFolderPopover()
            self.dissolveFolder(folder)
        }
    }

    // MARK: - 窗口内浮层（替代 NSAlert.runModal）

    private var activePrompt: PromptOverlayView?

    /// 在启动台窗口内弹出输入 / 确认浮层。
    ///
    /// 伪全屏时启动台窗口层级高于 `.modalPanel`，`NSAlert.runModal()` 会被压在窗口后面
    /// 且阻塞主线程（表现为“界面卡住、弹框点不到”），所以统一改用窗口内浮层。
    private func presentPrompt(title: String,
                               message: String? = nil,
                               placeholder: String? = nil,
                               defaultValue: String = "",
                               confirmTitle: String,
                               showsTextField: Bool = true,
                               onConfirm: @escaping (String) -> Void) {
        dismissPrompt()
        guard let root = window?.contentView else { return }
        let prompt = PromptOverlayView(
            title: title,
            message: message,
            placeholder: placeholder,
            defaultValue: defaultValue,
            confirmTitle: confirmTitle,
            showsTextField: showsTextField
        )
        prompt.onConfirm = { [weak self] value in
            guard let self else { return }
            self.activePrompt = nil
            self.window?.makeFirstResponder(self.scrollView)
            onConfirm(value)
        }
        prompt.onCancel = { [weak self] in
            guard let self else { return }
            self.activePrompt = nil
            self.window?.makeFirstResponder(self.scrollView)
        }
        activePrompt = prompt
        prompt.present(in: root)
    }

    private func dismissPrompt() {
        guard let prompt = activePrompt else { return }
        activePrompt = nil
        prompt.dismiss()
    }

    /// 回收清空的页面（至少保留首页）
    private func compactEmptyPages() {
        guard config.pageOrders.count > 1 else { return }
        config.pageOrders = PageComposer.compact(config.pageOrders)
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
                    let remove = NSMenuItem(title: L10n.f("从「%@」移出", folder.name), action: #selector(menuRemoveFromFolder(_:)), keyEquivalent: "")
                    remove.representedObject = info.path
                    menu.addItem(remove)
                } else if !config.folders.isEmpty {
                    let sub = NSMenuItem(title: L10n.t("移动到文件夹"), action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    for f in config.folders {
                        let mi = NSMenuItem(title: f.name, action: #selector(menuMoveToFolder(_:)), keyEquivalent: "")
                        mi.representedObject = MenuPayload(path: info.path, folderID: f.id)
                        submenu.addItem(mi)
                    }
                    sub.submenu = submenu
                    menu.addItem(sub)
                }

                menu.addItem(.separator())

                let reveal = NSMenuItem(title: L10n.t("在访达中显示"), action: #selector(menuRevealInFinder(_:)), keyEquivalent: "")
                reveal.representedObject = info.path
                menu.addItem(reveal)

                if runningBundleIDs.contains(info.bundleID) {
                    let quit = NSMenuItem(title: L10n.t("退出应用"), action: #selector(menuQuitApp(_:)), keyEquivalent: "")
                    quit.representedObject = info.bundleID
                    menu.addItem(quit)
                }

                let hide = NSMenuItem(title: L10n.t("从启动台隐藏"), action: #selector(menuHideApp(_:)), keyEquivalent: "")
                hide.representedObject = info.path
                menu.addItem(hide)
            case .folder(let folder):
                let sizeItem = NSMenuItem(title: L10n.t("网格大小"), action: nil, keyEquivalent: "")
                let sizeSub = NSMenu()
                let sizes: [(String, Int, Int)] = [
                    (L10n.t("1 × 1 (标准)"), 1, 1),
                    (L10n.t("2 × 1 (横向双格)"), 2, 1),
                    (L10n.t("1 × 2 (纵向双格)"), 1, 2),
                    (L10n.t("2 × 2 (大卡片)"), 2, 2)
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

                let rename = NSMenuItem(title: L10n.t("重命名"), action: #selector(menuRenameFolder(_:)), keyEquivalent: "")
                rename.representedObject = folder.id
                menu.addItem(rename)

                let dissolve = NSMenuItem(title: L10n.t("解散文件夹"), action: #selector(menuDissolveFolder(_:)), keyEquivalent: "")
                dissolve.representedObject = folder.id
                menu.addItem(dissolve)

                let del = NSMenuItem(title: L10n.t("删除文件夹"), action: #selector(menuDeleteFolder(_:)), keyEquivalent: "")
                del.representedObject = folder.id
                menu.addItem(del)
            }
        } else {
            let new = NSMenuItem(title: L10n.t("新建文件夹"), action: #selector(menuNewFolder(_:)), keyEquivalent: "")
            menu.addItem(new)
            let rescan = NSMenuItem(title: L10n.t("重新扫描应用"), action: #selector(menuRescan(_:)), keyEquivalent: "")
            menu.addItem(rescan)
        }
        menu.items.forEach { $0.target = self }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func menuNewFolder(_ sender: Any?) { createFolder() }
    @objc private func menuRescan(_ sender: Any?) { rescan() }

    @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func menuQuitApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
    }

    @objc private func menuHideApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        hideApp(path: path)
    }

    /// 从启动台隐藏应用：同时从所有文件夹中移出，避免「隐藏了却还在文件夹里」
    private func hideApp(path: String) {
        guard !config.isHidden(appPath: path) else { return }
        config.hiddenAppPaths.append(path)
        for i in 0..<config.folders.count {
            config.folders[i].appPaths.removeAll { $0 == path }
        }
        let pageList = PageComposer.removing(["app:\(path)"], from: currentPagesItems())
        savePagesOrder(pageList)
        compactEmptyPages()
        ConfigStore.save(config)
        exitSelectionMode()
        reloadData(keepPage: scrollView.currentPage)
        showToast(L10n.f("已隐藏「%@」，可在设置中恢复", (apps.first { $0.path == path }?.name) ?? path))
    }
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
    //
    // 关键约束：窗口背景是 `NSVisualEffectView`(.behindWindow) 毛玻璃。
    // 一旦对「整个窗口」做 alphaValue 动画，系统在 alpha < 1 期间无法正确采样桌面背景，
    // 窗口四边/四角会在动画首帧渲染成黑色（即“黑边一闪而过”）。
    // 因此这里改为：窗口始终保持 alpha = 1 整帧呈现，仅对窗口内容做淡入淡出。

    var isVisible: Bool { window?.isVisible == true }

    var isFrontmost: Bool {
        guard isVisible else { return false }
        return NSApp.isActive && window?.isKeyWindow == true
    }

    /// 参与淡入淡出的窗口内容（背景毛玻璃始终不透明，避免采样异常）
    private var contentViews: [NSView] { [topBar, scrollView, selectionTray] }

    private func setContentAlpha(_ alpha: CGFloat,
                                 animated: Bool,
                                 duration: TimeInterval = 0.14,
                                 completion: (() -> Void)? = nil) {
        guard animated else {
            for v in contentViews { v.alphaValue = alpha }
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for v in contentViews { v.animator().alphaValue = alpha }
        } completionHandler: {
            completion?()
        }
    }

    private func fadeInContent() {
        for v in contentViews { v.alphaValue = 0 }
        setContentAlpha(1, animated: true)
    }

    func show() {
        guard let window else { return }
        applyWindowLevel()
        if !isPseudoFullScreen {
            window.contentView?.layer?.cornerRadius = 18
            background.setCornerRadius(18)
        }
        let wasVisible = window.isVisible
        // 整窗不做 alpha 动画（毛玻璃在 alpha < 1 时无法正确采样桌面背景）
        window.alphaValue = 1
        // 上屏前铺好兜底底色，避免毛玻璃首帧采样不到桌面而整块发黑（表现为边框一圈黑线）
        background.prepareForDisplay()
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        // 阴影先按最终（圆角后）形状重算，再上屏，避免首帧残留直角阴影边
        window.invalidateShadow()
        window.displayIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 窗口完成首次合成后再揭开毛玻璃
        background.revealGlassAfterFirstFrame()
        if !wasVisible { fadeInContent() }
        else { setContentAlpha(1, animated: false) }
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
            window.contentView?.layer?.masksToBounds = true
            background.setCornerRadius(0)
            topBar.traffic.isHidden = true
            topBar.setFullscreen(true)
            applyWindowLevel()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            applyGridConfig()
            window.invalidateShadow()
        }
        show()
    }

    func hide() {
        dismissPrompt()
        if folderPopoverView != nil { dismissFolderPopover() }
        if isSelectionMode { exitSelectionMode() }
        clearFocus()
        clearSearch()
        persistWindowFrame()
        // 先移出屏幕再做全屏状态还原：避免还原尺寸的过程被用户看到
        window?.orderOut(nil)
        if isPseudoFullScreen { restoreFromFullScreen() }
    }

    /// 收起窗口时清空搜索：下次唤起重回完整应用列表，避免“看起来空空如也”的困惑
    private func clearSearch() {
        guard !searchQuery.isEmpty || !topBar.searchField.stringValue.isEmpty else { return }
        topBar.clearSearchField()
        searchQuery = ""
        reloadData(keepPage: 0)
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
        background.setCornerRadius(18)
        topBar.traffic.isHidden = false
        topBar.setFullscreen(false)
        applyWindowLevel()
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        // 必须立刻按新尺寸重绘：否则缩小后的窗口会短暂显示被拉伸的全屏旧画面（边缘一圈黑）
        window.displayIfNeeded()
        applyGridConfig()
        window.invalidateShadow()
    }

    func toggle() {
        if isFrontmost { hide() } else { show() }
    }

    /// 菜单栏图标左键：始终以「窗口化小屏」形态呈现（已在窗口化前台时则收起）。
    func toggleWindowed() {
        guard let window else { return }
        if window.isVisible, !isPseudoFullScreen, isScreenTransitioning == false,
           NSApp.isActive, window.isKeyWindow {
            hide()
            return
        }
        if isPseudoFullScreen { restoreFromFullScreen() }
        show()
    }

    @objc private func configDidChange() {
        let page = scrollView.currentPage
        let previous = config
        config = ConfigStore.load()
        ThemeManager.current = config.theme
        if previous.language != config.language {
            L10n.setLanguage(config.language)
            applyLanguage()
            // 设置窗口就地刷新文案，不重建（重建会闪烁并丢失滚动位置与当前标签页）
            settingsController?.retranslateInterface()
        }
        // 背景毛玻璃重建（含高斯模糊重算）代价高，且会瞬时闪一下；
        // 只有背景相关设置真的变了才重建，拖动列间距/图标大小等滑块时保持稳定。
        if previous.backgroundImagePath != config.backgroundImagePath
            || previous.bgOpacity != config.bgOpacity
            || previous.bgBlur != config.bgBlur {
            background.setConfig(config)
        }
        reloadData(keepPage: page)
    }

    // MARK: - 界面语言

    /// 语言切换后刷新主窗口内的静态文案（搜索占位符、按钮提示等）。
    /// 条目文案是应用名，与语言无关；空状态与右键菜单都是按需构建/渲染，无需整体重刷。
    func applyLanguage() {
        topBar.applyLanguage()
        if emptyStateView.superview != nil {
            reloadData(keepPage: scrollView.currentPage)
        }
    }

    // MARK: - 窗口位置记忆

    /// 退出应用前落盘窗口位置（不依赖 hide()）
    func persistFrameForTermination() {
        persistWindowFrame()
    }

    private func persistWindowFrame() {
        guard let window, !isScreenTransitioning else { return }
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        // 全屏时窗口铺满屏幕，应记忆进入全屏前的窗口化位置
        let frame = (isPseudoFullScreen && frameBeforeFullScreen != .zero)
            ? frameBeforeFullScreen
            : window.frame
        let width = Double(frame.width)
        let height = Double(frame.height)
        let x = Double(frame.origin.x)
        let y = Double(frame.origin.y)
        // 位置未变化就不落盘：hide() 会在每次启动应用时触发，避免无意义的写文件
        guard config.windowWidth != width || config.windowHeight != height
                || config.windowX != x || config.windowY != y else { return }
        config.windowWidth = width
        config.windowHeight = height
        config.windowX = x
        config.windowY = y
        ConfigStore.save(config)
    }

    private func scheduleFrameSave() {
        frameSaveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.persistWindowFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameSaveTimer = timer
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
        guard self.window != nil, !isScreenTransitioning else { return }
        isScreenTransitioning = true
        let targetFullscreen = !isPseudoFullScreen

        // 用「内容淡出 → 切换尺寸 → 内容淡入」替代整窗 alpha 动画，原因同 show()：
        // 整窗 alpha 会让 .behindWindow 毛玻璃在边缘采样异常而发黑。
        setContentAlpha(0, animated: true, duration: 0.09) { [weak self] in
            guard let self, let window = self.window else {
                self?.isScreenTransitioning = false
                return
            }

            if targetFullscreen {
                self.frameBeforeFullScreen = window.frame
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(Self.pseudoFullScreenFrame(for: screen), display: false)
                }
            } else {
                window.setFrame(self.frameBeforeFullScreen, display: false)
            }

            self.isPseudoFullScreen = targetFullscreen
            self.applyWindowLevel()
            window.isMovableByWindowBackground = false
            let radius: CGFloat = targetFullscreen ? 0 : 18
            window.contentView?.layer?.cornerRadius = radius
            window.contentView?.layer?.masksToBounds = true
            self.background.setCornerRadius(radius)
            self.topBar.traffic.isHidden = targetFullscreen
            self.topBar.setFullscreen(targetFullscreen)

            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            self.applyGridConfig()
            window.invalidateShadow()

            self.setContentAlpha(1, animated: true, duration: 0.16) { [weak self] in
                self?.isScreenTransitioning = false
            }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let w = window, !isPseudoFullScreen else { return }
        config.windowWidth = Double(w.frame.width)
        config.windowHeight = Double(w.frame.height)
        config.windowX = Double(w.frame.origin.x)
        config.windowY = Double(w.frame.origin.y)
        ConfigStore.save(config)
        applyWindowLevel()
        w.invalidateShadow()
    }

    /// 拖动窗口后防抖保存位置，下次启动回到原处
    func windowDidMove(_ notification: Notification) {
        guard !isScreenTransitioning, !isPseudoFullScreen else { return }
        scheduleFrameSave()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyWindowLevel()
        window?.invalidateShadow()
    }
}
