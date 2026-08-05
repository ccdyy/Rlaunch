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
    /// 伪全屏状态：不用系统全屏（其过渡动画会把窗口内容变形拉伸、且与自定义布局冲突），
    /// 自实现「淡出 → 瞬间切尺寸并完成布局 → 淡入」，全程无变形、无重影。
    private(set) var isPseudoFullScreen = false
    private var frameBeforeFullScreen: NSRect = .zero
    private var isScreenTransitioning = false

    private let background = BackgroundView()
    private let topBar = TopBarView()
    private let scrollView = SnapScrollView()
    private let pagesContainer = NSView()
    private var settingsController: SettingsWindowController?

    // MARK: - 根视图（手动布局，避免 AutoLayout 开销）

    private final class RootView: NSView {
        weak var controller: MainWindowController?

        override func layout() {
            super.layout()
            guard let c = controller else { return }
            let b = bounds
            // 全屏时顶部留出安全区（刘海屏菜单栏区域），按系统安全区动态取值
            let isFullscreen = c.isPseudoFullScreen
            let topInset: CGFloat = isFullscreen ? (c.window?.screen?.safeAreaInsets.top ?? 18) : 0
            c.background.frame = b
            c.topBar.frame = NSRect(x: 0, y: b.height - 56 - topInset, width: b.width, height: 56)
            c.scrollView.frame = NSRect(x: 0, y: 0, width: b.width, height: max(b.height - 56 - topInset, 0))
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
        window.collectionBehavior = [] // 不启用系统全屏，全屏由伪全屏自实现
        window.titleVisibility = .hidden
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        let root = RootView()
        root.controller = self
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        window.contentView = root

        background.setConfig(config)
        root.addSubview(background)
        root.addSubview(topBar)
        root.addSubview(scrollView)
        scrollView.documentView = pagesContainer

        wireTopBar()
        scrollView.onPageChanged = { [weak self] page in
            guard let self else { return }
            self.topBar.setPage(page, of: self.scrollView.pageCount)
        }
        scrollView.onEscape = { [weak self] in
            guard let self, self.isPseudoFullScreen else { return }
            self.togglePseudoFullScreen()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange), name: ConfigStore.didChange, object: nil)
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

    private func currentItems() -> [GridItem] {
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

    private var currentFolder: FolderConfig? {
        guard let id = currentFolderID else { return nil }
        return config.folders.first { $0.id == id }
    }

    private func gridConfig() -> GridLayoutConfig {
        // 全屏时按配置放大列/行间距，避免大屏上显得紧凑
        let isFullscreen = isPseudoFullScreen
        let scale = isFullscreen ? CGFloat(config.fullscreenSpacingScale) : 1.0
        return GridLayoutConfig(
            columns: config.columns,
            rows: config.rows,
            columnSpacing: CGFloat(config.columnSpacing) * scale,
            rowSpacing: CGFloat(config.rowSpacing) * scale,
            iconSize: CGFloat(config.iconSize)
        )
    }

    // MARK: - 分页与布局

    private func reloadData() {
        let items = currentItems()
        let perPage = max(config.columns * config.rows, 1)
        let pageCount = max(Int(ceil(Double(items.count) / Double(perPage))), 1)
        scrollView.setPageCount(pageCount)

        for page in pages { page.removeFromSuperview() }
        pages.removeAll()

        for i in 0..<pageCount {
            let page = GridPageView()
            page.layoutConfig = gridConfig()
            page.items = Array(items.dropFirst(i * perPage).prefix(perPage))
            page.onAppClick = { [weak self] info in self?.activateApp(info) }
            page.onFolderClick = { [weak self] folder in self?.openFolder(folder) }
            page.onBlankClick = { [weak self] in self?.handleBlankClick() }
            page.onDropAppToBlank = { [weak self] path in self?.removeAppFromFolder(path) }
            page.onDropAppToFolder = { [weak self] path, folder in self?.addApp(path, to: folder) }
            page.onContextMenu = { [weak self] item in self?.contextMenu(for: item) }
            pages.append(page)
            pagesContainer.addSubview(page)
        }

        lastLayoutSize = .zero
        layoutPages()
        scrollView.scrollToPage(0, animated: false)
        topBar.setPage(0, of: pageCount)
        topBar.setFolderMode(name: currentFolder?.name)
    }

    /// 仅刷新网格布局参数（全屏切换仅间距变化，列行数与页数不变），避免 reloadData 重建页面的卡顿
    private func applyGridConfig() {
        let cfg = gridConfig()
        for page in pages { page.layoutConfig = cfg }
        lastLayoutSize = .zero
        didLayoutRoot()
    }

    private func layoutPages() {
        let w = max(scrollView.contentSize.width, 1)
        let h = max(scrollView.contentSize.height, 1)
        for (i, page) in pages.enumerated() {
            page.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
        }
        pagesContainer.frame = NSRect(x: 0, y: 0, width: CGFloat(pages.count) * w, height: h)
    }

    /// RootView 布局完成回调：窗口尺寸变化时重排页面并保持当前页
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
        if config.hideOnLaunch { hide() }
    }

    private func openFolder(_ folder: FolderConfig) {
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
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchQuery.isEmpty { currentFolderID = nil }
        reloadData()
    }

    /// 需求 8：设置打开时点空白关闭设置；文件夹模式下点空白回到主界面
    /// （搜索模式点击空白不做清空操作，避免误触导致"搜索失效"）
    private func handleBlankClick() {
        if let s = settingsController?.window, s.isVisible {
            settingsController?.close()
            return
        }
        if currentFolderID != nil {
            backToMain()
        }
    }

    // MARK: - 文件夹管理

    private func addApp(_ path: String, to folder: FolderConfig) {
        // 仅接受扫描确认的应用路径（防 pasteboard 注入污染配置）
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
        // 伪全屏时主窗口层级高于菜单栏，设置窗口需同步抬高否则被盖住
        if isPseudoFullScreen, let mw = window {
            settingsController?.window?.level = mw.level
        }
    }

    // MARK: - 显示 / 隐藏

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 1
        }
        window.makeFirstResponder(scrollView)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    // MARK: - 配置变更

    @objc private func configDidChange() {
        config = ConfigStore.load()
        ThemeManager.current = config.theme
        background.setConfig(config)
        topBar.setFolderMode(name: currentFolder?.name)
        reloadData()
    }

    // MARK: - NSWindowDelegate

    /// 伪全屏切换：淡出 → 瞬间切到目标尺寸并完成全部布局 → 淡入。
    /// 全程无窗口尺寸动画，因此不存在内容变形/拉伸/重影的可能。
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
                window.level = .floating
                window.setFrame(self.frameBeforeFullScreen, display: false)
                self.isPseudoFullScreen = false
                window.isMovableByWindowBackground = true
                window.contentView?.layer?.cornerRadius = 18
                self.topBar.traffic.isHidden = false
                self.topBar.setFullscreen(false)
            } else {
                self.frameBeforeFullScreen = window.frame
                // 抬高窗口层级以盖住菜单栏，达到真全屏的视觉效果
                window.level = NSWindow.Level(
                    rawValue: NSWindow.Level.RawValue(CGWindowLevelForKey(.mainMenuWindow)) + 1)
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.frame, display: false)
                }
                self.isPseudoFullScreen = true
                window.isMovableByWindowBackground = false // 防止全屏时被拖走
                window.contentView?.layer?.cornerRadius = 0
                self.topBar.traffic.isHidden = true
                self.topBar.setFullscreen(true)
            }
            window.contentView?.layoutSubtreeIfNeeded() // 先按新尺寸完成根布局（含安全区）
            self.applyGridConfig()                      // 再刷新全屏/普通间距并重排页面
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
    }
}
