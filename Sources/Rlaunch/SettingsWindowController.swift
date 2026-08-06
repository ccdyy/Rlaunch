import Cocoa
import UniformTypeIdentifiers
import RlaunchCore

fileprivate func makeStepper(value: Double, min: Double, max: Double) -> NSStepper {
    let s = NSStepper()
    s.minValue = min
    s.maxValue = max
    s.increment = 1
    s.doubleValue = value
    return s
}

fileprivate func makeValueLabel(_ width: CGFloat) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    l.textColor = .secondaryLabelColor
    l.alignment = .right
    l.widthAnchor.constraint(equalToConstant: width).isActive = true
    return l
}

/// 设置面板：独立无边框圆角窗口，可拖动；改动即时生效并防抖保存。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onRescan: (() -> Void)?

    private var config = ConfigStore.load()
    private var saveDebounce: Timer?
    private var keyMonitor: Any?

    // MARK: 控件

    private let themeControl = NSSegmentedControl(
        labels: ["明亮", "深黑", "跟随系统"], trackingMode: .selectOne, target: nil, action: nil)
    private let bgPathLabel = NSTextField(labelWithString: "无")
    private let opacitySlider = NSSlider(value: 0.85, minValue: 0.15, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = makeValueLabel(44)
    private let blurSlider = NSSlider(value: 0, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let blurValue = makeValueLabel(44)
    private let columnsStepper: NSStepper = makeStepper(value: 7, min: 3, max: 10)
    private let columnsValue = makeValueLabel(44)
    private let rowsStepper: NSStepper = makeStepper(value: 5, min: 3, max: 8)
    private let rowsValue = makeValueLabel(44)
    private let spacingSlider = NSSlider(value: 24, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let spacingValue = makeValueLabel(44)
    private let columnSpacingSlider = NSSlider(value: 24, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let columnSpacingValue = makeValueLabel(44)
    private let rowSpacingSlider = NSSlider(value: 24, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let rowSpacingValue = makeValueLabel(44)
    private let fullscreenScaleSlider = NSSlider(value: 1.6, minValue: 1.0, maxValue: 3.0, target: nil, action: nil)
    private let fullscreenScaleValue = makeValueLabel(44)
    private let iconSizeSlider = NSSlider(value: 64, minValue: 32, maxValue: 128, target: nil, action: nil)
    private let iconSizeValue = makeValueLabel(44)
    private let depthStepper: NSStepper = makeStepper(value: 3, min: 1, max: 6)
    private let depthValue = makeValueLabel(44)
    private let gestureSwitch = NSSwitch()
    private let gestureSwitchLabel = NSTextField(labelWithString: "启用捏合手势唤起")
    private let gestureSlider = NSSlider(value: 0.7, minValue: 0.3, maxValue: 2.0, target: nil, action: nil)
    private let gestureValue = makeValueLabel(44)
    private let scanRowsStack = NSStackView()
    private let rescanButton = NSButton(title: "重新扫描应用", target: nil, action: nil)

    // 手动布局引用（不用 Auto Layout，见 init 注释）
    private var scrollView: NSScrollView!
    private var containerView: NSView!
    private var headerView: NSView!
    private var tabBarView: NSView!
    private var tabButtons: [TabButton] = []
    private var contentPages: [NSView] = []
    private var contentStacks: [NSStackView] = []
    private var currentTab = 0
    private let headerGrip = NSView()
    private let headerTitle = NSTextField(labelWithString: "Rlaunch 设置")

    /// 手动布局内容：标题栏 + 左侧 Tab 栏 + 右侧内容页
    private func layoutContent() {
        guard let scrollView, let containerView, let headerView, let tabBarView else { return }
        // 以 effect（superview）为固定基准，避免自身 frame 变化导致布局漂移
        let area = scrollView.superview?.bounds ?? scrollView.bounds
        let width = max(area.width, 500)
        let height = max(area.height, 400)

        // 顶部标题栏（把手 + 标题）
        headerView.frame = NSRect(x: 0, y: height - 56, width: width, height: 56)
        headerGrip.frame = NSRect(x: (width - 40) / 2, y: 10, width: 40, height: 5)
        headerGrip.wantsLayer = true
        headerGrip.layer?.cornerRadius = 2.5
        headerGrip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
        headerTitle.sizeToFit()
        headerTitle.frame = NSRect(x: (width - headerTitle.frame.width) / 2, y: 22,
                                   width: headerTitle.frame.width, height: 18)

        // 左 Tab 栏 + 右内容区（限制在标题栏下方，避免顶部控件被标题遮挡）
        let bodyTop: CGFloat = 56
        let bodyH = height - bodyTop
        let contentH_ = max(bodyH - 32, 0)
        tabBarView.frame = NSRect(x: 16, y: 16, width: 132, height: contentH_)
        let scrollX: CGFloat = 16 + 132 + 14
        scrollView.frame = NSRect(x: scrollX, y: 16,
                                  width: max(width - scrollX - 16, 0), height: contentH_)

        // Tab 按钮竖排
        let btnH: CGFloat = 34
        let btnGap: CGFloat = 6
        var y = tabBarView.bounds.height - 8
        for btn in tabButtons {
            y -= btnH
            btn.frame = NSRect(x: 8, y: y, width: tabBarView.bounds.width - 16, height: btnH)
            y -= btnGap
        }

        // 当前内容页
        guard currentTab < contentPages.count, currentTab < contentStacks.count else { return }
        let page = contentPages[currentTab]
        let stack = contentStacks[currentTab]
        let pageW = max(scrollView.frame.width, 300)
        stack.layoutSubtreeIfNeeded()
        let contentH = max(stack.fittingSize.height + 8, scrollView.bounds.height)
        // 内容从顶部对齐（documentView 原点在左下）
        stack.frame = NSRect(x: 4, y: contentH - stack.fittingSize.height - 8,
                             width: pageW - 8, height: stack.fittingSize.height)
        page.frame = NSRect(x: 0, y: 0, width: pageW, height: contentH)
        containerView.frame = NSRect(x: 0, y: 0, width: pageW, height: contentH)
    }

    // MARK: 初始化

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.isRestorable = false // 防止系统恢复自动弹出设置窗口
        super.init(window: window)
        window.delegate = self

        let drag = DraggableView()
        drag.windowToMove = window
        window.contentView = drag

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        // 手动布局：Auto Layout 约束（锚定 contentView edges）会在窗口首次显示时
        // 与 NSWindow 的布局系统冲突，把窗口压成 0×0 —— 这里全部用 autoresizing
        effect.autoresizingMask = [.width, .height]
        effect.frame = drag.bounds
        drag.addSubview(effect)

        // 左侧 Tab 栏
        let tabBar = NSView()
        effect.addSubview(tabBar)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = effect.bounds
        effect.addSubview(scroll)

        // 顶部标题栏（拖动把手 + 标题）
        let header = NSView()
        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitle.textColor = .secondaryLabelColor
        headerTitle.alignment = .center
        header.addSubview(headerGrip)
        header.addSubview(headerTitle)
        effect.addSubview(header)

        let container = NSView()
        scroll.documentView = container

        self.headerView = header
        self.tabBarView = tabBar
        self.scrollView = scroll
        self.containerView = container

        buildTabsAndPages()
        refreshValues()
        layoutContent()

        // Esc 关闭
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.window?.isKeyWindow == true {
                self.close()
                return nil
            }
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - 控件构建

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 10
        s.alignment = .centerY
        return s
    }

    private func controlRow(_ labelText: String, _ control: NSView, _ value: NSTextField? = nil) -> NSStackView {
        let l = NSTextField(labelWithString: labelText)
        l.font = .systemFont(ofSize: 13)
        l.textColor = .labelColor
        l.widthAnchor.constraint(equalToConstant: 66).isActive = true
        l.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = [l, control]
        if let value { views.append(value) }
        let r = row(views)
        if let slider = control as? NSSlider {
            // Tab 内容区靠左布局：滑杆固定宽度，不拉伸
            slider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        }
        return r
    }

    // MARK: - Tab 构建

    private func buildTabsAndPages() {
        let titles = ["外观", "网格", "扫描目录", "手势", "操作"]
        for (i, title) in titles.enumerated() {
            let btn = TabButton(title: title)
            btn.onSelect = { [weak self] in self?.selectTab(i) }
            btn.isTabSelected = (i == 0)
            tabButtons.append(btn)
            tabBarView.addSubview(btn)

            let page = NSView()
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            page.addSubview(stack)
            contentPages.append(page)
            contentStacks.append(stack)
            containerView.addSubview(page)
        }

        buildAppearancePage(contentStacks[0])
        buildGridPage(contentStacks[1])
        buildScanPage(contentStacks[2])
        buildGesturePage(contentStacks[3])
        buildActionPage(contentStacks[4])

        // 公共 action
        let controls: [NSControl] = [themeControl, opacitySlider, blurSlider, columnsStepper,
                                     rowsStepper, columnSpacingSlider, rowSpacingSlider, fullscreenScaleSlider,
                                     iconSizeSlider, depthStepper, gestureSlider, gestureSwitch]
        for c in controls {
            c.target = self
            c.action = #selector(controlChanged)
            if let slider = c as? NSSlider { slider.isContinuous = true }
        }
        selectTab(0)
    }

    private func buildAppearancePage(_ stack: NSStackView) {
        stack.addArrangedSubview(controlRow("主题", themeControl))
        bgPathLabel.lineBreakMode = .byTruncatingMiddle
        bgPathLabel.font = .systemFont(ofSize: 12)
        bgPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bgPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        let chooseButton = NSButton(title: "选择图片…", target: self, action: #selector(chooseBackground))
        let clearButton = NSButton(title: "清除", target: self, action: #selector(clearBackground))
        stack.addArrangedSubview(row([bgPathLabel, chooseButton, clearButton]))
        stack.addArrangedSubview(controlRow("透明度", opacitySlider, opacityValue))
        stack.addArrangedSubview(controlRow("模糊程度", blurSlider, blurValue))
    }

    private func buildGridPage(_ stack: NSStackView) {
        stack.addArrangedSubview(controlRow("列数", columnsStepper, columnsValue))
        stack.addArrangedSubview(controlRow("行数", rowsStepper, rowsValue))
        stack.addArrangedSubview(controlRow("列间距", columnSpacingSlider, columnSpacingValue))
        stack.addArrangedSubview(controlRow("行间距", rowSpacingSlider, rowSpacingValue))
        stack.addArrangedSubview(controlRow("全屏间距", fullscreenScaleSlider, fullscreenScaleValue))
        stack.addArrangedSubview(controlRow("图标大小", iconSizeSlider, iconSizeValue))
    }

    private func buildScanPage(_ stack: NSStackView) {
        scanRowsStack.orientation = .vertical
        scanRowsStack.spacing = 6
        scanRowsStack.alignment = .leading
        scanRowsStack.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(scanRowsStack)
        let addPathButton = NSButton(title: "添加扫描目录…", target: self, action: #selector(addScanPath))
        stack.addArrangedSubview(row([addPathButton]))
        stack.addArrangedSubview(controlRow("递归层级", depthStepper, depthValue))
    }

    private func buildGesturePage(_ stack: NSStackView) {
        gestureSwitch.controlSize = .small
        gestureSwitchLabel.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(row([gestureSwitch, gestureSwitchLabel]))
        stack.addArrangedSubview(controlRow("捏合灵敏度", gestureSlider, gestureValue))
    }

    private func buildActionPage(_ stack: NSStackView) {
        rescanButton.target = self
        rescanButton.action = #selector(rescanClicked)
        let doneButton = NSButton(title: "完成", target: self, action: #selector(doneClicked))
        doneButton.keyEquivalent = "\r"
        stack.addArrangedSubview(row([rescanButton, doneButton]))
    }

    /// 切换 Tab：隐藏其他页、滚动回顶部
    private func selectTab(_ index: Int) {
        currentTab = index
        for (i, btn) in tabButtons.enumerated() {
            btn.isTabSelected = (i == index)
        }
        for (i, page) in contentPages.enumerated() {
            page.isHidden = (i != index)
        }
        layoutContent()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - 值刷新

    private func refreshValues() {
        themeControl.selectedSegment = config.theme == .light ? 0 : (config.theme == .dark ? 1 : 2)
        bgPathLabel.stringValue = config.backgroundImagePath ?? "无（系统毛玻璃）"
        opacitySlider.doubleValue = config.bgOpacity
        opacityValue.stringValue = String(format: "%.0f%%", config.bgOpacity * 100)
        blurSlider.doubleValue = config.bgBlur
        blurValue.stringValue = "\(Int(config.bgBlur))"
        columnsStepper.intValue = Int32(config.columns)
        columnsValue.stringValue = "\(config.columns)"
        rowsStepper.intValue = Int32(config.rows)
        rowsValue.stringValue = "\(config.rows)"
        spacingSlider.doubleValue = config.spacing
        spacingValue.stringValue = "\(Int(config.spacing))"
        columnSpacingSlider.doubleValue = config.columnSpacing
        columnSpacingValue.stringValue = "\(Int(config.columnSpacing))"
        rowSpacingSlider.doubleValue = config.rowSpacing
        rowSpacingValue.stringValue = "\(Int(config.rowSpacing))"
        fullscreenScaleSlider.doubleValue = config.fullscreenSpacingScale
        fullscreenScaleValue.stringValue = String(format: "%.1f×", config.fullscreenSpacingScale)
        iconSizeSlider.doubleValue = config.iconSize
        iconSizeValue.stringValue = "\(Int(config.iconSize))"
        depthStepper.intValue = Int32(config.recursionDepth)
        depthValue.stringValue = "\(config.recursionDepth)"
        gestureSwitch.state = config.gestureEnabled ? .on : .off
        gestureSlider.doubleValue = config.gestureThreshold
        gestureValue.stringValue = String(format: "%.2f", config.gestureThreshold)
        rebuildScanRows()
    }

    private func rebuildScanRows() {
        scanRowsStack.arrangedSubviews.forEach {
            scanRowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for path in config.scanPaths {
            let label = NSTextField(labelWithString: path)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = .labelColor
            // 允许长路径在容器内压缩截断；注意：不能给行加 width==stack.width
            // 约束（会与 NSStackView 内部布局约束冲突导致崩溃）
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let del = NSButton(title: "✕", target: self, action: #selector(removeScanPath(_:)))
            del.isBordered = false
            del.font = .systemFont(ofSize: 11)
            del.contentTintColor = .secondaryLabelColor
            del.bezelStyle = .inline
            del.setContentHuggingPriority(.required, for: .horizontal)
            let r = row([label, del])
            scanRowsStack.addArrangedSubview(r)
        }
        layoutContent()
    }

    // MARK: - 动作

    @objc private func controlChanged(_ sender: Any?) {
        config.theme = themeControl.selectedSegment == 0 ? .light : (themeControl.selectedSegment == 1 ? .dark : .system)
        config.bgOpacity = opacitySlider.doubleValue
        config.bgBlur = blurSlider.doubleValue
        config.columns = columnsStepper.intValue > 0 ? Int(columnsStepper.intValue) : config.columns
        config.rows = rowsStepper.intValue > 0 ? Int(rowsStepper.intValue) : config.rows
        config.spacing = spacingSlider.doubleValue
        config.columnSpacing = columnSpacingSlider.doubleValue
        config.rowSpacing = rowSpacingSlider.doubleValue
        config.fullscreenSpacingScale = fullscreenScaleSlider.doubleValue
        config.iconSize = iconSizeSlider.doubleValue
        config.recursionDepth = depthStepper.intValue > 0 ? Int(depthStepper.intValue) : config.recursionDepth
        config.gestureEnabled = gestureSwitch.state == .on
        config.gestureThreshold = gestureSlider.doubleValue

        ThemeManager.current = config.theme // 主题即时生效
        refreshValues()
        scheduleSave()
    }

    @objc private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            self.config.backgroundImagePath = url.path
            self.refreshValues()
            self.scheduleSave()
        }
    }

    @objc private func clearBackground() {
        config.backgroundImagePath = nil
        refreshValues()
        scheduleSave()
    }

    @objc private func addScanPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要扫描的应用目录"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard let self, resp == .OK else { return }
            for url in panel.urls {
                if !self.config.scanPaths.contains(url.path) {
                    self.config.scanPaths.append(url.path)
                }
            }
            self.refreshValues()
            self.scheduleSave()
        }
    }

    @objc private func removeScanPath(_ sender: NSButton) {
        // 从所在行的 label 取路径
        guard let rowView = sender.superview as? NSStackView,
              let label = rowView.arrangedSubviews.first as? NSTextField else { return }
        config.scanPaths.removeAll { $0 == label.stringValue }
        refreshValues()
        scheduleSave()
    }

    @objc private func rescanClicked() {
        onRescan?()
    }

    @objc private func doneClicked() {
        close()
    }

    // MARK: - 保存

    /// 写盘：以磁盘最新配置为基准，仅覆盖设置面板可编辑的字段，
    /// 避免覆盖设置打开期间主窗口独立写盘的字段（folders / 窗口尺寸）
    private func persist() {
        var latest = ConfigStore.load()
        latest.scanPaths = config.scanPaths
        latest.recursionDepth = config.recursionDepth
        latest.theme = config.theme
        latest.backgroundImagePath = config.backgroundImagePath
        latest.bgOpacity = config.bgOpacity
        latest.bgBlur = config.bgBlur
        latest.columns = config.columns
        latest.rows = config.rows
        latest.spacing = config.spacing
        latest.columnSpacing = config.columnSpacing
        latest.rowSpacing = config.rowSpacing
        latest.fullscreenSpacingScale = config.fullscreenSpacingScale
        latest.iconSize = config.iconSize
        latest.gestureEnabled = config.gestureEnabled
        latest.gestureThreshold = config.gestureThreshold
        ConfigStore.save(latest)
    }

    private func scheduleSave() {
        saveDebounce?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.persist()
            NotificationCenter.default.post(name: ConfigStore.didChange, object: nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        saveDebounce = timer
    }

    override func close() {
        saveDebounce?.invalidate()
        persist()
        NotificationCenter.default.post(name: ConfigStore.didChange, object: nil)
        super.close()
    }

    func show(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if let parent {
            let pf = parent.frame
            let f = window.frame
            window.setFrameOrigin(NSPoint(x: pf.midX - f.width / 2, y: pf.midY - f.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Tab 按钮

/// 左侧选项卡按钮：选中高亮（accent 圆角），悬停轻微高亮
final class TabButton: NSButton {
    var isTabSelected = false {
        didSet { updateStyle() }
    }
    var onSelect: (() -> Void)?
    private var hovered = false

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .medium)
        alignment = .left
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        target = self
        action = #selector(clicked)
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onSelect?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if !isTabSelected { updateStyle() }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if !isTabSelected { updateStyle() }
    }

    private func updateStyle() {
        let title = self.title
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 10
        paragraph.firstLineHeadIndent = 10
        if isTabSelected {
            // 柔和选中：半透明 accent + 白字，避免过于突兀
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
        } else {
            layer?.backgroundColor = hovered
                ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
                : .clear
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
        }
    }
}

// MARK: - 可拖动根视图

final class DraggableView: NSView {
    weak var windowToMove: NSWindow?
    private var lastLocation: NSPoint?

    override func mouseDown(with event: NSEvent) {
        lastLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastLocation else { return }
        let p = event.locationInWindow
        let dx = p.x - last.x
        let dy = p.y - last.y
        if let w = windowToMove {
            var f = w.frame
            f.origin.x += dx
            f.origin.y += dy
            w.setFrame(f, display: true)
        }
        lastLocation = p
    }

    override func mouseUp(with event: NSEvent) {
        lastLocation = nil
    }
}
