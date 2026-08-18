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
            let topInset: CGFloat = isFullscreen ? c.fullscreenTopInset() : 0
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
        // 全屏时按屏幕尺寸自适应：图标、文字、间距整体放大并铺满屏幕，
        // 避免大屏全屏时内容缩在中间。
        if isPseudoFullScreen, let screen = window?.screen ?? NSScreen.main {
            let W = screen.frame.width
            let H = screen.frame.height
            let cols = CGFloat(config.columns)
            let rows = CGFloat(config.rows)
            let scale = CGFloat(config.fullscreenSpacingScale)
            let colSpacing = max(14, CGFloat(config.columnSpacing) * scale)
            let rowSpacing = max(14, CGFloat(config.rowSpacing) * scale)
            let labelH: CGFloat = 36 // 估算标签高度（实际按图标大小缩放）
            // 图标尺寸：宽高双向适配（宽度占 88%、高度占 84%），上限 160
            let iconForW = (W * 0.88 - (cols - 1) * colSpacing) / cols - 16
            let iconForH = (H * 0.84 - (rows - 1) * rowSpacing) / rows - labelH - 8
            let icon = min(160, max(CGFloat(config.iconSize), min(iconForW, iconForH)))
            return GridLayoutConfig(
                columns: config.columns,
                rows: config.rows,
                columnSpacing: colSpacing,
                rowSpacing: rowSpacing,
                iconSize: icon
            )
        }
        return GridLayoutConfig(
            columns: config.columns,
            rows: config.rows,
            columnSpacing: CGFloat(config.columnSpacing),
            rowSpacing: CGFloat(config.rowSpacing),
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
        if config.hideOnLaunch || prefersNormalWindowStacking() || isPseudoFullScreen {
            hide()
        }
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

    /// 设置打开时点空白关闭设置；文件夹模式下点空白回到主界面；
    /// 全屏时点空白关闭界面（并恢复窗口尺寸）；大屏浮动模式下点空白关闭展示
    private func handleBlankClick() {
        if let s = settingsController?.window, s.isVisible {
            settingsController?.close()
            return
        }
        if currentFolderID != nil {
            backToMain()
            return
        }
        if isPseudoFullScreen {
            hide() // 全屏时点击空白处关闭界面
            return
        }
        guard !prefersNormalWindowStacking() else { return }
        hide()
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
        settingsController?.window?.level = window?.level ?? .normal
    }

    // MARK: - 显示 / 隐藏

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        guard let window else { return }
        applyWindowLevel()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 1
        }
        window.makeFirstResponder(scrollView)
    }

    /// 捏合手势唤起：显示并直接进入全屏（隐藏状态下窗口保持普通尺寸，先铺满再淡入）
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
        window?.orderOut(nil)
    }

    /// 关闭界面时若处于全屏：先恢复普通尺寸与状态，下次唤起从普通窗口开始
    private func restoreFromFullScreen() {
        guard let window else { return }
        if frameBeforeFullScreen != .zero {
            window.setFrame(frameBeforeFullScreen, display: false)
        }
        isPseudoFullScreen = false
        window.isMovableByWindowBackground = true
        window.contentView?.layer?.cornerRadius = 18
        topBar.traffic.isHidden = false
        topBar.setFullscreen(false)
        applyWindowLevel()
        window.contentView?.layoutSubtreeIfNeeded() // 先按普通尺寸完成根布局
        applyGridConfig()                           // 再恢复普通间距并重排页面
    }

    func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    // MARK: - 配置变更

    @objc private func configDidChange() {
        let page = scrollView.currentPage
        config = ConfigStore.load()
        ThemeManager.current = config.theme
        background.setConfig(config)
        topBar.setFolderMode(name: currentFolder?.name)
        reloadData()
        // reloadData 会回到第一页：设置变更/关闭设置时保持用户所在页
        if scrollView.pageCount > 1 {
            scrollView.scrollToPage(min(page, scrollView.pageCount - 1), animated: false)
            topBar.setPage(scrollView.currentPage, of: scrollView.pageCount)
        }
    }

    // MARK: - 窗口层级（小屏 / 占满屏幕时与普通应用一样参与切换）

    /// 窗口占可见区域 ≥ 70%，或笔记本级屏幕 —— 非全屏时不浮动置顶
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
            // 抬高至菜单栏之上，隐藏系统菜单栏，实现真正全屏
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

    /// 全屏顶栏下移，为刘海/安全区留白
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

    /// 失焦或切到其他应用时让出前台：占满屏幕则直接隐藏（类 Launchpad），否则置后
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
        // 延迟一帧，避免弹窗/Sheet 切换 key 窗口时误隐藏
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
                window.setFrame(self.frameBeforeFullScreen, display: false)
                self.isPseudoFullScreen = false
                self.applyWindowLevel() // 先恢复全屏状态再套层级，避免残留全屏层级
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
        applyWindowLevel()
    }
}
