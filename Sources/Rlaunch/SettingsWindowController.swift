import Cocoa
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import RlaunchCore

// MARK: - 统一表单样式规范

private enum FormMetrics {
    static let labelWidth: CGFloat = 80          // 标签统一固定宽度（右对齐）
    static let controlSpacing: CGFloat = 12      // 标签与控件间距
    static let sliderWidth: CGFloat = 210        // 滑块统一定宽
    static let valueWidth: CGFloat = 46          // 数值展示标签统一定宽
    static let controlAreaWidth: CGFloat = sliderWidth + controlSpacing + valueWidth // 268pt 控件标准总宽度
    static let rowSpacing: CGFloat = 12          // 控件行间距
    static let sectionSpacing: CGFloat = 18      // 分组垂直间距
}

fileprivate func makeFormLabel(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: 13, weight: .regular)
    l.textColor = .secondaryLabelColor
    l.alignment = .right
    l.widthAnchor.constraint(equalToConstant: FormMetrics.labelWidth).isActive = true
    l.setContentHuggingPriority(.required, for: .horizontal)
    l.setContentCompressionResistancePriority(.required, for: .horizontal)
    return l
}

fileprivate func makeValueLabel() -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    l.textColor = .secondaryLabelColor
    l.alignment = .right
    l.widthAnchor.constraint(equalToConstant: FormMetrics.valueWidth).isActive = true
    return l
}

fileprivate func makeSectionHeader(_ title: String, isFirst: Bool = false) -> NSView {
    let container = NSStackView()
    container.orientation = .vertical
    container.spacing = 8
    container.alignment = .leading

    if !isFirst {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: FormMetrics.labelWidth + FormMetrics.controlSpacing + FormMetrics.controlAreaWidth).isActive = true
        container.addArrangedSubview(line)
    }

    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .tertiaryLabelColor
    container.addArrangedSubview(label)

    return container
}

/// 统一风格的数字步进输入框：左侧可输入/展示数值 + 右侧紧密贴合的 NSStepper
final class NumberStepperBox: NSView, NSTextFieldDelegate {
    let textField = NSTextField()
    var label: NSTextField { textField }
    let stepper: NSStepper
    var onValueChanged: ((Int) -> Void)?

    init(stepper: NSStepper, width: CGFloat = 46) {
        self.stepper = stepper
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor

        stepper.controlSize = .small
        stepper.sizeToFit()

        textField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        textField.textColor = .labelColor
        textField.alignment = .center
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .none
        textField.stringValue = "\(stepper.intValue)"
        textField.delegate = self

        addSubview(textField)
        addSubview(stepper)
        textField.translatesAutoresizingMaskIntoConstraints = false
        stepper.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            textField.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -1),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            stepper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.widthAnchor.constraint(equalToConstant: 16),
            stepper.heightAnchor.constraint(equalToConstant: 22),

            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidEndEditing(_ obj: Notification) {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let val = Int(text) {
            let clamped = max(Int(stepper.minValue), min(Int(stepper.maxValue), val))
            stepper.intValue = Int32(clamped)
            textField.stringValue = "\(clamped)"
            onValueChanged?(clamped)
        } else {
            textField.stringValue = "\(stepper.intValue)"
        }
    }
}

fileprivate func makeStepper(value: Double, min: Double, max: Double) -> NSStepper {
    let s = NSStepper()
    s.minValue = min
    s.maxValue = max
    s.increment = 1
    s.doubleValue = value
    return s
}

// MARK: - 设置窗口控制器

/// 设置面板：独立无边框圆角窗口，可拖动；改动即时生效并防抖保存。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onRescan: (() -> Void)?

    private var config = ConfigStore.load()
    private var saveDebounce: Timer?
    private var keyMonitor: Any?
    private var recordMonitor: Any?
    private var isRecordingShortcut = false

    // MARK: - 控件定义

    // 外观
    private let themeControl = NSSegmentedControl(
        labels: ["明亮", "深黑", "跟随系统"], trackingMode: .selectOne, target: nil, action: nil)
    private let bgPathLabel = NSTextField(labelWithString: "默认（系统毛玻璃）")
    private let chooseBgButton = NSButton(title: "选择图片…", target: nil, action: nil)
    private let clearBgButton = NSButton(title: "清除", target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.85, minValue: 0.15, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = makeValueLabel()
    private let blurSlider = NSSlider(value: 0, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let blurValue = makeValueLabel()
    private let blurHintLabel = NSTextField(labelWithString: "")

    // 网格
    private let columnsStepper: NSStepper = makeStepper(value: 7, min: 3, max: 10)
    private var columnsBox: NumberStepperBox!
    private let rowsStepper: NSStepper = makeStepper(value: 5, min: 3, max: 8)
    private var rowsBox: NumberStepperBox!
    private let columnSpacingSlider = NSSlider(value: 24, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let columnSpacingValue = makeValueLabel()
    private let rowSpacingSlider = NSSlider(value: 24, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let rowSpacingValue = makeValueLabel()
    private let fullscreenScaleSlider = NSSlider(value: 1.6, minValue: 1.0, maxValue: 3.0, target: nil, action: nil)
    private let fullscreenScaleValue = makeValueLabel()
    private let iconSizeSlider = NSSlider(value: 64, minValue: 32, maxValue: 128, target: nil, action: nil)
    private let iconSizeValue = makeValueLabel()

    // 应用扫描
    private let scanPathsContainer = NSView()
    private let scanRowsStack = NSStackView()
    private let addPathButton = NSButton(title: "添加目录…", target: nil, action: nil)
    private let hiddenPathsContainer = NSView()
    private let hiddenRowsStack = NSStackView()
    private let depthStepper: NSStepper = makeStepper(value: 3, min: 1, max: 6)
    private var depthBox: NumberStepperBox!
    private let rescanButtonScanTab = NSButton(title: "立即重新扫描", target: nil, action: nil)
    private let rescanStatusScanTab = NSTextField(labelWithString: "")

    // 快捷键与手势
    private let hotKeySwitch = NSSwitch()
    private let hotKeySwitchLabel = NSTextField(labelWithString: "启用全局快捷键唤起")
    private let hotKeyBadge = NSView()
    private let hotKeyLabel = NSTextField(labelWithString: "未设置")
    private let recordButton = NSButton(title: "录制快捷键…", target: nil, action: nil)
    private let clearShortcutButton = NSButton(title: "清除", target: nil, action: nil)
    private let hotKeyControlRow = NSStackView()

    private let pinchSwitch = NSSwitch()
    private let pinchSwitchLabel = NSTextField(labelWithString: "四指/五指捏合：打开并全屏")
    private let pinchSlider = NSSlider(value: 0.7, minValue: 0.3, maxValue: 2.0, target: nil, action: nil)
    private let pinchValue = makeValueLabel()
    private let pinchControlRow = NSStackView()

    private let axStatusLabel = NSTextField(labelWithString: "辅助功能：未授权")
    private let axButton = NSButton(title: "打开权限设置…", target: nil, action: nil)
    private let trackpadButton = NSButton(title: "触控板手势设置…", target: nil, action: nil)

    // 通用
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginLabel = NSTextField(labelWithString: "登录时自动启动 Rlaunch")
    private let launchAtLoginStatus = NSTextField(labelWithString: "")
    private let rescanButtonGeneralTab = NSButton(title: "重新扫描应用", target: nil, action: nil)
    private let rescanStatusGeneralTab = NSTextField(labelWithString: "")
    private let openConfigButton = NSButton(title: "打开配置目录", target: nil, action: nil)
    private let exportConfigButton = NSButton(title: "导出…", target: nil, action: nil)
    private let importConfigButton = NSButton(title: "导入…", target: nil, action: nil)
    private let resetButton = NSButton(title: "恢复默认设置", target: nil, action: nil)
    private let resetLayoutButton = NSButton(title: "重置桌面布局", target: nil, action: nil)
    private let resetStatusLabel = NSTextField(labelWithString: "")
    private var isConfirmingReset = false
    private var isConfirmingLayoutReset = false

    // 关于
    private let appNameLabel = NSTextField(labelWithString: "Rlaunch")
    private let githubLinkButton = LinkButton(url: AppVersion.repositoryURL)
    private let copyRepoButton = NSButton(title: "复制地址", target: nil, action: nil)
    private let copyRepoFeedback = NSTextField(labelWithString: "")

    // 窗口元素
    private var scrollView: NSScrollView!
    private var containerView: NSView!
    /// 背景玻璃视图（铺满窗口）与其内容承载视图
    private var glassView: NSView!
    private var contentHost: NSView!
    private var headerView: NSView!
    private var tabBarView: NSView!
    private var tabButtons: [TabButton] = []
    private var contentPages: [NSView] = []
    private var contentStacks: [NSStackView] = []
    private var currentTab = 0
    private let headerGrip = NSView()
    private let headerTitle = NSTextField(labelWithString: "Rlaunch 设置")
    private let closeButton = CloseButton()

    // MARK: - 布局与对齐核心辅助

    /// 创建统一对齐的标准表单行：[固定宽标签] + [控件] + (可选后置内容)
    private func formRow(label: String, control: NSView, trailing: NSView? = nil) -> NSStackView {
        let lbl = makeFormLabel(label)
        var views: [NSView] = [lbl, control]
        if let trailing { views.append(trailing) }
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = FormMetrics.controlSpacing
        s.alignment = .centerY
        return s
    }

    /// 滑块行：统一滑块宽度并对齐右侧数值展示
    private func sliderRow(label: String, slider: NSSlider, valueLabel: NSTextField) -> NSStackView {
        slider.widthAnchor.constraint(equalToConstant: FormMetrics.sliderWidth).isActive = true
        return formRow(label: label, control: slider, trailing: valueLabel)
    }

    /// 说明提示行：左侧自动留出标签列的宽度，确保提示内容与右侧控件列绝对对齐
    private func formHintRow(_ text: String, textColor: NSColor = .secondaryLabelColor) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: FormMetrics.labelWidth).isActive = true

        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = textColor
        hint.preferredMaxLayoutWidth = FormMetrics.controlAreaWidth

        let s = NSStackView(views: [spacer, hint])
        s.orientation = .horizontal
        s.spacing = FormMetrics.controlSpacing
        s.alignment = .firstBaseline
        return s
    }

    /// 统一布局计算
    private func layoutContent() {
        guard let scrollView, let containerView, let headerView, let tabBarView,
              let glassView, let contentHost else { return }
        // 原生玻璃的内容由 contentView 承载，需显式与玻璃视图对齐
        contentHost.frame = glassView.bounds
        let area = glassView.bounds
        let width = max(area.width, 540)
        let height = max(area.height, 420)

        // 顶部标题栏（把手 + 标题 + 右上角关闭按钮）
        headerView.frame = NSRect(x: 0, y: height - 52, width: width, height: 52)
        headerGrip.frame = NSRect(x: (width - 36) / 2, y: 38, width: 36, height: 4)
        headerGrip.wantsLayer = true
        headerGrip.layer?.cornerRadius = 2
        headerGrip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor

        headerTitle.sizeToFit()
        headerTitle.frame = NSRect(x: (width - headerTitle.frame.width) / 2, y: 14,
                                   width: headerTitle.frame.width, height: 18)

        closeButton.frame = NSRect(x: width - 36, y: 14, width: 22, height: 22)

        // 左侧 Tab 栏 + 右侧内容区
        let bodyTop: CGFloat = 52
        let bodyH = height - bodyTop
        let contentH_ = max(bodyH - 24, 0)
        tabBarView.frame = NSRect(x: 16, y: 14, width: 126, height: contentH_)
        let scrollX: CGFloat = 16 + 126 + 14
        scrollView.frame = NSRect(x: scrollX, y: 14,
                                  width: max(width - scrollX - 16, 0), height: contentH_)

        // Tab 按钮垂直排列
        let btnH: CGFloat = 34
        let btnGap: CGFloat = 4
        var y = tabBarView.bounds.height - 4
        for btn in tabButtons {
            y -= btnH
            btn.frame = NSRect(x: 4, y: y, width: tabBarView.bounds.width - 8, height: btnH)
            y -= btnGap
        }

        // 当前页内容高度与对齐
        guard currentTab < contentPages.count, currentTab < contentStacks.count else { return }
        let page = contentPages[currentTab]
        let stack = contentStacks[currentTab]
        let pageW = max(scrollView.frame.width, 320)
        stack.layoutSubtreeIfNeeded()
        let contentH = max(stack.fittingSize.height + 16, scrollView.bounds.height)
        stack.frame = NSRect(x: 4, y: contentH - stack.fittingSize.height - 8,
                             width: pageW - 8, height: stack.fittingSize.height)
        page.frame = NSRect(x: 0, y: 0, width: pageW, height: contentH)
        containerView.frame = NSRect(x: 0, y: 0, width: pageW, height: contentH)
    }

    // MARK: - 初始化

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 630, height: 530),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        let drag = DraggableView()
        drag.windowToMove = window
        window.contentView = drag

        // 背景玻璃：macOS 26+ 用原生 Liquid Glass，更早系统回退到 NSVisualEffectView(.popover)
        let (glassView, contentHost) = SystemGlass.makeContainer(cornerRadius: 14, material: .popover)
        glassView.autoresizingMask = [.width, .height]
        glassView.frame = drag.bounds
        drag.addSubview(glassView)

        contentHost.autoresizingMask = [.width, .height]
        contentHost.frame = glassView.bounds
        self.glassView = glassView
        self.contentHost = contentHost

        // 左侧 Tab 栏
        let tabBar = NSView()
        contentHost.addSubview(tabBar)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = contentHost.bounds
        contentHost.addSubview(scroll)

        // 顶部标题栏
        let header = NSView()
        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitle.textColor = .secondaryLabelColor
        headerTitle.alignment = .center
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        header.addSubview(headerGrip)
        header.addSubview(headerTitle)
        header.addSubview(closeButton)
        contentHost.addSubview(header)

        let container = NSView()
        scroll.documentView = container

        self.headerView = header
        self.tabBarView = tabBar
        self.scrollView = scroll
        self.containerView = container

        columnsBox = NumberStepperBox(stepper: columnsStepper)
        columnsBox.onValueChanged = { [weak self] _ in
            self?.controlChanged(self?.columnsStepper)
        }
        rowsBox = NumberStepperBox(stepper: rowsStepper)
        rowsBox.onValueChanged = { [weak self] _ in
            self?.controlChanged(self?.rowsStepper)
        }
        depthBox = NumberStepperBox(stepper: depthStepper)
        depthBox.onValueChanged = { [weak self] _ in
            self?.controlChanged(self?.depthStepper)
        }

        buildTabsAndPages()
        refreshValues()
        layoutContent()

        // 监听 Esc 键关闭
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.window?.isKeyWindow == true {
                if self.isRecordingShortcut {
                    self.finishRecording(cancelled: true)
                } else {
                    self.close()
                }
                return nil
            }
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
    }

    // MARK: - Tab 构建

    private func buildTabsAndPages() {
        let titles = ["外观", "网格", "应用扫描", "快捷键", "通用"]
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
            stack.spacing = FormMetrics.rowSpacing
            page.addSubview(stack)
            contentPages.append(page)
            contentStacks.append(stack)
            containerView.addSubview(page)
        }

        buildAppearancePage(contentStacks[0])
        buildGridPage(contentStacks[1])
        buildScanPage(contentStacks[2])
        buildShortcutPage(contentStacks[3])
        buildGeneralPage(contentStacks[4])

        // 注册常规配置变更事件
        let controls: [NSControl] = [themeControl, opacitySlider, blurSlider, columnsStepper,
                                     rowsStepper, columnSpacingSlider, rowSpacingSlider, fullscreenScaleSlider,
                                     iconSizeSlider, depthStepper, pinchSlider, pinchSwitch, hotKeySwitch]
        for c in controls {
            c.target = self
            c.action = #selector(controlChanged)
            if let slider = c as? NSSlider { slider.isContinuous = true }
        }
        selectTab(0)
    }

    // MARK: 1. 外观设置
    private func buildAppearancePage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("界面样式", isFirst: true))
        stack.addArrangedSubview(formRow(label: "主题模式", control: themeControl))

        // 背景图控件组
        bgPathLabel.lineBreakMode = .byTruncatingMiddle
        bgPathLabel.font = .systemFont(ofSize: 12)
        bgPathLabel.textColor = .labelColor
        bgPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bgPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true

        chooseBgButton.bezelStyle = .rounded
        chooseBgButton.controlSize = .small
        chooseBgButton.target = self
        chooseBgButton.action = #selector(chooseBackground)

        clearBgButton.bezelStyle = .rounded
        clearBgButton.controlSize = .small
        clearBgButton.target = self
        clearBgButton.action = #selector(clearBackground)

        let bgControlRow = NSStackView(views: [bgPathLabel, chooseBgButton, clearBgButton])
        bgControlRow.orientation = .horizontal
        bgControlRow.spacing = 8
        bgControlRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "背景图片", control: bgControlRow))

        // 背景效果
        stack.addArrangedSubview(makeSectionHeader("背景效果"))
        stack.addArrangedSubview(sliderRow(label: "透明度", slider: opacitySlider, valueLabel: opacityValue))
        stack.addArrangedSubview(sliderRow(label: "模糊程度", slider: blurSlider, valueLabel: blurValue))

        blurHintLabel.font = .systemFont(ofSize: 11)
        blurHintLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(formHintRow("提示：高斯模糊仅在使用自定义背景图片时生效。"))
        stack.addArrangedSubview(formHintRow("当前背景渲染方式：\(SystemGlass.rendererName)。"))
    }

    // MARK: 2. 网格设置
    private func buildGridPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("布局规格", isFirst: true))
        stack.addArrangedSubview(formRow(label: "列数", control: columnsBox))
        stack.addArrangedSubview(formRow(label: "行数", control: rowsBox))

        stack.addArrangedSubview(makeSectionHeader("间距与尺寸"))
        stack.addArrangedSubview(sliderRow(label: "列间距", slider: columnSpacingSlider, valueLabel: columnSpacingValue))
        stack.addArrangedSubview(sliderRow(label: "行间距", slider: rowSpacingSlider, valueLabel: rowSpacingValue))
        stack.addArrangedSubview(sliderRow(label: "全屏缩放", slider: fullscreenScaleSlider, valueLabel: fullscreenScaleValue))
        stack.addArrangedSubview(sliderRow(label: "图标大小", slider: iconSizeSlider, valueLabel: iconSizeValue))
    }

    // MARK: 3. 应用扫描设置
    private func buildScanPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("扫描目录", isFirst: true))

        // 目录列表容器（卡片样式）
        scanPathsContainer.wantsLayer = true
        scanPathsContainer.layer?.cornerRadius = 8
        scanPathsContainer.layer?.borderWidth = 1
        scanPathsContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        scanPathsContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        scanPathsContainer.translatesAutoresizingMaskIntoConstraints = false
        scanPathsContainer.widthAnchor.constraint(equalToConstant: FormMetrics.controlAreaWidth).isActive = true

        scanRowsStack.orientation = .vertical
        scanRowsStack.spacing = 4
        scanRowsStack.alignment = .leading
        scanRowsStack.translatesAutoresizingMaskIntoConstraints = false
        scanPathsContainer.addSubview(scanRowsStack)

        NSLayoutConstraint.activate([
            scanRowsStack.leadingAnchor.constraint(equalTo: scanPathsContainer.leadingAnchor, constant: 8),
            scanRowsStack.trailingAnchor.constraint(equalTo: scanPathsContainer.trailingAnchor, constant: -8),
            scanRowsStack.topAnchor.constraint(equalTo: scanPathsContainer.topAnchor, constant: 6),
            scanRowsStack.bottomAnchor.constraint(equalTo: scanPathsContainer.bottomAnchor, constant: -6),
        ])

        stack.addArrangedSubview(formRow(label: "目录列表", control: scanPathsContainer))

        // 添加目录按钮
        addPathButton.bezelStyle = .rounded
        addPathButton.controlSize = .small
        addPathButton.target = self
        addPathButton.action = #selector(addScanPath)
        stack.addArrangedSubview(formRow(label: "", control: addPathButton))

        // 递归层级
        stack.addArrangedSubview(makeSectionHeader("扫描参数与操作"))
        stack.addArrangedSubview(formRow(label: "递归层级", control: depthBox))
        stack.addArrangedSubview(formHintRow("搜索应用时的最大目录深度（建议保持为 3）。"))

        // 重新扫描操作（整合至扫描面板）
        rescanButtonScanTab.bezelStyle = .rounded
        rescanButtonScanTab.target = self
        rescanButtonScanTab.action = #selector(rescanClicked)

        rescanStatusScanTab.font = .systemFont(ofSize: 12)
        rescanStatusScanTab.textColor = .secondaryLabelColor

        let scanActionRow = NSStackView(views: [rescanButtonScanTab, rescanStatusScanTab])
        scanActionRow.orientation = .horizontal
        scanActionRow.spacing = 10
        scanActionRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "应用索引", control: scanActionRow))

        buildHiddenAppsSection(stack)
    }

    // MARK: 3b. 已隐藏的应用

    private func buildHiddenAppsSection(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("已隐藏的应用"))

        hiddenPathsContainer.wantsLayer = true
        hiddenPathsContainer.layer?.cornerRadius = 8
        hiddenPathsContainer.layer?.borderWidth = 1
        hiddenPathsContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        hiddenPathsContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        hiddenPathsContainer.translatesAutoresizingMaskIntoConstraints = false
        hiddenPathsContainer.widthAnchor.constraint(equalToConstant: FormMetrics.controlAreaWidth).isActive = true

        hiddenRowsStack.orientation = .vertical
        hiddenRowsStack.spacing = 4
        hiddenRowsStack.alignment = .leading
        hiddenRowsStack.translatesAutoresizingMaskIntoConstraints = false
        hiddenPathsContainer.addSubview(hiddenRowsStack)

        NSLayoutConstraint.activate([
            hiddenRowsStack.leadingAnchor.constraint(equalTo: hiddenPathsContainer.leadingAnchor, constant: 8),
            hiddenRowsStack.trailingAnchor.constraint(equalTo: hiddenPathsContainer.trailingAnchor, constant: -8),
            hiddenRowsStack.topAnchor.constraint(equalTo: hiddenPathsContainer.topAnchor, constant: 6),
            hiddenRowsStack.bottomAnchor.constraint(equalTo: hiddenPathsContainer.bottomAnchor, constant: -6),
        ])

        stack.addArrangedSubview(formRow(label: "隐藏列表", control: hiddenPathsContainer))
        stack.addArrangedSubview(formHintRow("在启动台中右键应用选择「从启动台隐藏」后，可在这里恢复显示。"))
    }

    // MARK: 4. 快捷键与手势设置
    private func buildShortcutPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("全局快捷键", isFirst: true))

        hotKeySwitch.controlSize = .small
        hotKeySwitchLabel.font = .systemFont(ofSize: 13)
        let hotKeyToggleRow = NSStackView(views: [hotKeySwitch, hotKeySwitchLabel])
        hotKeyToggleRow.orientation = .horizontal
        hotKeyToggleRow.spacing = 8
        hotKeyToggleRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "全局唤起", control: hotKeyToggleRow))

        // 快捷键按键显示胶囊
        hotKeyBadge.wantsLayer = true
        hotKeyBadge.layer?.cornerRadius = 6
        hotKeyBadge.layer?.borderWidth = 1
        hotKeyBadge.layer?.borderColor = NSColor.separatorColor.cgColor
        hotKeyBadge.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor

        hotKeyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        hotKeyLabel.textColor = .labelColor
        hotKeyLabel.alignment = .center
        hotKeyBadge.addSubview(hotKeyLabel)
        hotKeyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hotKeyLabel.leadingAnchor.constraint(equalTo: hotKeyBadge.leadingAnchor, constant: 10),
            hotKeyLabel.trailingAnchor.constraint(equalTo: hotKeyBadge.trailingAnchor, constant: -10),
            hotKeyLabel.centerYAnchor.constraint(equalTo: hotKeyBadge.centerYAnchor),
        ])
        hotKeyBadge.translatesAutoresizingMaskIntoConstraints = false
        hotKeyBadge.heightAnchor.constraint(equalToConstant: 26).isActive = true
        hotKeyBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .small
        recordButton.target = self
        recordButton.action = #selector(recordShortcut)

        clearShortcutButton.bezelStyle = .rounded
        clearShortcutButton.controlSize = .small
        clearShortcutButton.target = self
        clearShortcutButton.action = #selector(clearShortcut)

        hotKeyControlRow.setViews([hotKeyBadge, recordButton, clearShortcutButton], in: .leading)
        hotKeyControlRow.orientation = .horizontal
        hotKeyControlRow.spacing = 8
        hotKeyControlRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "快捷键", control: hotKeyControlRow))

        // 触控板手势
        stack.addArrangedSubview(makeSectionHeader("触控板手势"))

        pinchSwitch.controlSize = .small
        pinchSwitchLabel.font = .systemFont(ofSize: 13)
        let pinchToggleRow = NSStackView(views: [pinchSwitch, pinchSwitchLabel])
        pinchToggleRow.orientation = .horizontal
        pinchToggleRow.spacing = 8
        pinchToggleRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "捏合唤起", control: pinchToggleRow))

        pinchSlider.widthAnchor.constraint(equalToConstant: FormMetrics.sliderWidth).isActive = true
        pinchControlRow.setViews([pinchSlider, pinchValue], in: .leading)
        pinchControlRow.orientation = .horizontal
        pinchControlRow.spacing = FormMetrics.controlSpacing
        pinchControlRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "灵敏度", control: pinchControlRow))

        // 权限与系统手势设置
        stack.addArrangedSubview(makeSectionHeader("系统权限与手势"))

        axStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        axButton.bezelStyle = .rounded
        axButton.controlSize = .small
        axButton.target = self
        axButton.action = #selector(openAccessibilitySettings)
        let axRow = NSStackView(views: [axStatusLabel, axButton])
        axRow.orientation = .horizontal
        axRow.spacing = 10
        axRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "辅助功能", control: axRow))

        trackpadButton.bezelStyle = .rounded
        trackpadButton.controlSize = .small
        trackpadButton.target = self
        trackpadButton.action = #selector(openTrackpadSettings)
        stack.addArrangedSubview(formRow(label: "触控板", control: trackpadButton))

        stack.addArrangedSubview(formHintRow(
            "手势说明：四指/五指捏合通过系统触摸点间距收缩算法识别（需要辅助功能权限）。若系统已授权仍无法使用，可在「辅助功能」中先移除 Rlaunch 再重新添加，并在「触控板手势设置」中检查是否被系统默认手势占用。"))
    }

    // MARK: 5. 通用设置
    private func buildGeneralPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("系统启动", isFirst: true))

        launchAtLoginSwitch.controlSize = .small
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged)
        launchAtLoginLabel.font = .systemFont(ofSize: 13)

        let loginRow = NSStackView(views: [launchAtLoginSwitch, launchAtLoginLabel])
        loginRow.orientation = .horizontal
        loginRow.spacing = 8
        loginRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "开机启动", control: loginRow))

        launchAtLoginStatus.font = .systemFont(ofSize: 11)
        launchAtLoginStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(formRow(label: "", control: launchAtLoginStatus))
        stack.addArrangedSubview(formHintRow("可在「系统设置 → 通用 → 登录项与扩展」中管理。"))

        stack.addArrangedSubview(makeSectionHeader("应用维护"))

        rescanButtonGeneralTab.bezelStyle = .rounded
        rescanButtonGeneralTab.target = self
        rescanButtonGeneralTab.action = #selector(rescanClicked)

        rescanStatusGeneralTab.font = .systemFont(ofSize: 12)
        rescanStatusGeneralTab.textColor = .secondaryLabelColor

        let generalRescanRow = NSStackView(views: [rescanButtonGeneralTab, rescanStatusGeneralTab])
        generalRescanRow.orientation = .horizontal
        generalRescanRow.spacing = 10
        generalRescanRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "应用索引", control: generalRescanRow))

        // 配置维护：打开配置目录 / 导出导入 / 恢复默认（二次点击确认，避免弹出会被全屏窗口遮挡的模态框）
        for button in [openConfigButton, exportConfigButton, importConfigButton, resetButton, resetLayoutButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        openConfigButton.action = #selector(openConfigFolder)
        exportConfigButton.action = #selector(exportConfig)
        importConfigButton.action = #selector(importConfig)
        resetButton.action = #selector(resetClicked)
        resetLayoutButton.action = #selector(resetLayoutClicked)

        let fileRow = NSStackView(views: [openConfigButton, exportConfigButton, importConfigButton])
        fileRow.orientation = .horizontal
        fileRow.spacing = 8
        fileRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "配置文件", control: fileRow))

        resetStatusLabel.font = .systemFont(ofSize: 11)
        resetStatusLabel.textColor = .systemOrange

        let resetRow = NSStackView(views: [resetButton, resetLayoutButton, resetStatusLabel])
        resetRow.orientation = .horizontal
        resetRow.spacing = 8
        resetRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "重置", control: resetRow))

        buildAboutSection(stack)
    }

    // MARK: 6. 关于
    private func buildAboutSection(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionHeader("关于"))

        appNameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        appNameLabel.textColor = .labelColor
        stack.addArrangedSubview(formRow(label: "应用", control: appNameLabel))

        githubLinkButton.toolTip = "在浏览器中打开 \(AppVersion.repositoryURL)"

        copyRepoButton.bezelStyle = .rounded
        copyRepoButton.controlSize = .small
        copyRepoButton.target = self
        copyRepoButton.action = #selector(copyRepositoryURL)

        copyRepoFeedback.font = .systemFont(ofSize: 11)
        copyRepoFeedback.textColor = .systemGreen

        let repoRow = NSStackView(views: [githubLinkButton, copyRepoButton, copyRepoFeedback])
        repoRow.orientation = .horizontal
        repoRow.spacing = 10
        repoRow.alignment = .centerY
        stack.addArrangedSubview(formRow(label: "GitHub", control: repoRow))

        stack.addArrangedSubview(formHintRow("Rlaunch · 轻量高效的 macOS 启动台平替。点击 GitHub 地址可在浏览器中打开项目主页。"))
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

    // MARK: - 值刷新与状态联动

    /// 刷新全部界面状态。
    /// - Parameter heavy: 是否同时刷新「耗时状态」（扫描目录行、登录项、辅助功能权限）。
    ///   滑块/开关连续变化时传 `false`，避免每帧重建目录行、反复查询系统服务造成掉帧。
    private func refreshValues(heavy: Bool = true) {
        refreshControlValues()
        if heavy {
            refreshLaunchAtLogin()
            refreshPermissionStatus()
            rebuildScanRows()
            rebuildHiddenRows()
        }
    }

    private func refreshControlValues() {
        themeControl.selectedSegment = config.theme == .light ? 0 : (config.theme == .dark ? 1 : 2)

        // 背景图与模糊联动
        if let path = config.backgroundImagePath, !path.isEmpty {
            bgPathLabel.stringValue = (path as NSString).lastPathComponent
            clearBgButton.isEnabled = true
            blurSlider.isEnabled = true
            blurValue.textColor = .secondaryLabelColor
        } else {
            bgPathLabel.stringValue = "默认（系统毛玻璃）"
            clearBgButton.isEnabled = false
            blurSlider.isEnabled = false
            blurValue.textColor = .tertiaryLabelColor
        }

        opacitySlider.doubleValue = config.bgOpacity
        opacityValue.stringValue = String(format: "%.0f%%", config.bgOpacity * 100)
        blurSlider.doubleValue = config.bgBlur
        blurValue.stringValue = "\(Int(config.bgBlur))"

        columnsStepper.intValue = Int32(config.columns)
        columnsBox.label.stringValue = "\(config.columns)"
        rowsStepper.intValue = Int32(config.rows)
        rowsBox.label.stringValue = "\(config.rows)"

        columnSpacingSlider.doubleValue = config.columnSpacing
        columnSpacingValue.stringValue = "\(Int(config.columnSpacing)) pt"
        rowSpacingSlider.doubleValue = config.rowSpacing
        rowSpacingValue.stringValue = "\(Int(config.rowSpacing)) pt"
        fullscreenScaleSlider.doubleValue = config.fullscreenSpacingScale
        fullscreenScaleValue.stringValue = String(format: "%.1f×", config.fullscreenSpacingScale)
        iconSizeSlider.doubleValue = config.iconSize
        iconSizeValue.stringValue = "\(Int(config.iconSize)) pt"

        depthStepper.intValue = Int32(config.recursionDepth)
        depthBox.label.stringValue = "\(config.recursionDepth)"

        // 快捷键联动逻辑
        hotKeySwitch.state = config.hotKeyEnabled ? .on : .off
        let hotKeyDisplay = ShortcutFormatter.displayString(
            keyCode: config.hotKeyKeyCode, carbonModifiers: config.hotKeyModifiers)
        hotKeyLabel.stringValue = hotKeyDisplay
        let isHotKeyConfigured = config.hotKeyKeyCode != nil
        hotKeyLabel.textColor = isHotKeyConfigured ? .labelColor : .tertiaryLabelColor

        let hotKeyActive = config.hotKeyEnabled
        recordButton.isEnabled = hotKeyActive
        clearShortcutButton.isEnabled = hotKeyActive && isHotKeyConfigured
        hotKeyBadge.layer?.opacity = hotKeyActive ? 1.0 : 0.45

        // 捏合手势联动逻辑
        pinchSwitch.state = config.pinchEnabled ? .on : .off
        pinchSlider.doubleValue = config.pinchThreshold
        pinchValue.stringValue = String(format: "%.2f", config.pinchThreshold)
        pinchSlider.isEnabled = config.pinchEnabled
        pinchValue.textColor = config.pinchEnabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// 与系统登录项状态同步（以系统状态为准）
    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            launchAtLoginSwitch.state = .on
            launchAtLoginStatus.stringValue = "状态：已开启（登录时自动启动）"
            launchAtLoginStatus.textColor = .systemGreen
        case .requiresApproval:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatus.stringValue = "状态：需要系统授权（请在系统设置中允许）"
            launchAtLoginStatus.textColor = .systemOrange
        case .notRegistered:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatus.stringValue = "状态：未开启"
            launchAtLoginStatus.textColor = .secondaryLabelColor
        case .notFound:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatus.stringValue = "状态：未找到应用副本，请放入「应用程序」文件夹"
            launchAtLoginStatus.textColor = .systemRed
        @unknown default:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatus.stringValue = ""
            launchAtLoginStatus.textColor = .secondaryLabelColor
        }
        config.launchAtLogin = (status == .enabled)
    }

    @objc private func launchAtLoginChanged() {
        let service = SMAppService.mainApp
        do {
            if launchAtLoginSwitch.state == .on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("Rlaunch: 开机启动设置失败 %@", error.localizedDescription)
        }
        refreshLaunchAtLogin()
        scheduleSave()
    }

    private func refreshPermissionStatus() {
        let trusted = AXIsProcessTrusted()
        axStatusLabel.stringValue = trusted ? "辅助功能：已授权 ✓" : "辅助功能：未授权"
        axStatusLabel.textColor = trusted ? .systemGreen : .systemRed
    }

    private func rebuildScanRows() {
        scanRowsStack.arrangedSubviews.forEach {
            scanRowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if config.scanPaths.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "未配置扫描目录")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .tertiaryLabelColor
            scanRowsStack.addArrangedSubview(emptyLabel)
        } else {
            for path in config.scanPaths {
                let rowView = NSStackView()
                rowView.orientation = .horizontal
                rowView.spacing = 6
                rowView.alignment = .centerY

                let icon = NSImageView()
                icon.image = NSWorkspace.shared.icon(forFile: NSString(string: path).expandingTildeInPath)
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

                let label = NSTextField(labelWithString: path)
                label.font = .systemFont(ofSize: 12)
                label.lineBreakMode = .byTruncatingMiddle
                label.textColor = .labelColor
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                let del = NSButton(title: "✕", target: self, action: #selector(removeScanPath(_:)))
                del.isBordered = false
                del.font = .systemFont(ofSize: 10, weight: .bold)
                del.contentTintColor = .secondaryLabelColor
                del.bezelStyle = .inline
                del.setContentHuggingPriority(.required, for: .horizontal)

                rowView.addArrangedSubview(icon)
                rowView.addArrangedSubview(label)
                rowView.addArrangedSubview(del)
                rowView.translatesAutoresizingMaskIntoConstraints = false
                rowView.widthAnchor.constraint(equalToConstant: FormMetrics.controlAreaWidth - 16).isActive = true

                scanRowsStack.addArrangedSubview(rowView)
            }
        }
        layoutContent()
    }

    /// 重建「已隐藏的应用」列表
    private func rebuildHiddenRows() {
        hiddenRowsStack.arrangedSubviews.forEach {
            hiddenRowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if config.hiddenAppPaths.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "没有被隐藏的应用")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .tertiaryLabelColor
            hiddenRowsStack.addArrangedSubview(emptyLabel)
        } else {
            for path in config.hiddenAppPaths {
                let rowView = NSStackView()
                rowView.orientation = .horizontal
                rowView.spacing = 6
                rowView.alignment = .centerY

                let icon = NSImageView()
                icon.image = NSWorkspace.shared.icon(forFile: path)
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

                let label = NSTextField(labelWithString: FileManager.default.displayName(atPath: path))
                label.font = .systemFont(ofSize: 12)
                label.lineBreakMode = .byTruncatingMiddle
                label.textColor = .labelColor
                label.toolTip = path
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                let restore = NSButton(title: "恢复", target: self, action: #selector(restoreHiddenApp(_:)))
                restore.bezelStyle = .inline
                restore.isBordered = false
                restore.font = .systemFont(ofSize: 11, weight: .medium)
                restore.contentTintColor = .controlAccentColor
                restore.setContentHuggingPriority(.required, for: .horizontal)
                restore.toolTip = "恢复显示"

                rowView.addArrangedSubview(icon)
                rowView.addArrangedSubview(label)
                rowView.addArrangedSubview(restore)
                rowView.translatesAutoresizingMaskIntoConstraints = false
                rowView.widthAnchor.constraint(equalToConstant: FormMetrics.controlAreaWidth - 16).isActive = true

                hiddenRowsStack.addArrangedSubview(rowView)
            }
        }
        layoutContent()
    }

    // MARK: - 事件处理

    @objc private func controlChanged(_ sender: Any?) {
        config.theme = themeControl.selectedSegment == 0 ? .light : (themeControl.selectedSegment == 1 ? .dark : .system)
        config.bgOpacity = opacitySlider.doubleValue
        config.bgBlur = blurSlider.doubleValue
        config.columns = columnsStepper.intValue > 0 ? Int(columnsStepper.intValue) : config.columns
        config.rows = rowsStepper.intValue > 0 ? Int(rowsStepper.intValue) : config.rows
        config.columnSpacing = columnSpacingSlider.doubleValue
        config.rowSpacing = rowSpacingSlider.doubleValue
        config.fullscreenSpacingScale = fullscreenScaleSlider.doubleValue
        config.iconSize = iconSizeSlider.doubleValue
        config.recursionDepth = depthStepper.intValue > 0 ? Int(depthStepper.intValue) : config.recursionDepth
        config.hotKeyEnabled = hotKeySwitch.state == .on
        config.pinchEnabled = pinchSwitch.state == .on
        config.pinchThreshold = pinchSlider.doubleValue

        // 开启捏合但未授权时，主动拉起系统授权弹窗
        if sender as? NSSwitch === pinchSwitch, config.pinchEnabled, !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        ThemeManager.current = config.theme
        refreshValues(heavy: false)
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
            self.refreshValues(heavy: false)
            self.scheduleSave()
        }
    }

    @objc private func clearBackground() {
        config.backgroundImagePath = nil
        refreshValues(heavy: false)
        scheduleSave()
    }

    // MARK: - 快捷键录制

    private static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    @objc private func recordShortcut() {
        if isRecordingShortcut {
            finishRecording(cancelled: true)
            return
        }
        isRecordingShortcut = true
        recordButton.title = "按下快捷键… (Esc 取消)"
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecordingShortcut else { return event }
            let code = Int(event.keyCode)
            if code == 53 { // Esc 取消
                self.finishRecording(cancelled: true)
                return nil
            }
            if code == 51 { // Delete 清除
                self.config.hotKeyKeyCode = nil
                self.config.hotKeyModifiers = 0
                self.finishRecording(cancelled: false)
                return nil
            }
            guard !Self.modifierKeyCodes.contains(code) else { return nil }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return nil }
            self.config.hotKeyKeyCode = code
            self.config.hotKeyModifiers = Int(ShortcutFormatter.carbonModifiers(from: mods))
            self.finishRecording(cancelled: false)
            return nil
        }
    }

    private func finishRecording(cancelled: Bool) {
        if let recordMonitor {
            NSEvent.removeMonitor(recordMonitor)
            self.recordMonitor = nil
        }
        isRecordingShortcut = false
        recordButton.title = "录制快捷键…"
        refreshValues(heavy: false)
        scheduleSave()
    }

    @objc private func clearShortcut() {
        config.hotKeyKeyCode = nil
        config.hotKeyModifiers = 0
        refreshValues(heavy: false)
        scheduleSave()
    }

    // MARK: - 权限与外部设置入口

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openTrackpadSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.trackpad")!)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissionStatus()
    }

    // MARK: - 扫描目录管理

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
        guard let rowView = sender.superview as? NSStackView,
              let label = rowView.arrangedSubviews.first(where: { $0 is NSTextField }) as? NSTextField else { return }
        config.scanPaths.removeAll { $0 == label.stringValue }
        refreshValues()
        scheduleSave()
    }

    /// 恢复被隐藏的应用（交互元素在重建行时动态创建，故用菜单/按钮的 hover 行反查路径）
    @objc private func restoreHiddenApp(_ sender: NSButton) {
        guard let rowView = sender.superview as? NSStackView,
              let index = hiddenRowsStack.arrangedSubviews.firstIndex(of: rowView),
              index < config.hiddenAppPaths.count else { return }
        config.hiddenAppPaths.remove(at: index)
        refreshValues()
        scheduleSave()
    }

    @objc private func rescanClicked() {
        onRescan?()
        rescanStatusScanTab.stringValue = "已触发重新扫描 ✓"
        rescanStatusGeneralTab.stringValue = "已触发重新扫描 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.rescanStatusScanTab.stringValue = ""
            self?.rescanStatusGeneralTab.stringValue = ""
        }
    }

    // MARK: - 配置维护

    @objc private func openConfigFolder() {
        let url = ConfigStore.configFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// 导出配置：把当前 config.json 另存一份，便于备份或分享桌面布局
    @objc private func exportConfig() {
        persist()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Rlaunch-config.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            do {
                try FileManager.default.copyItem(at: ConfigStore.configFileURL, to: url)
                self.showResetStatus("已导出 ✓", color: .systemGreen)
            } catch {
                self.showResetStatus("导出失败：\(error.localizedDescription)", color: .systemRed)
            }
        }
    }

    /// 导入配置：覆盖当前配置并立即生效
    @objc private func importConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择要导入的 Rlaunch 配置文件"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url),
                  let imported = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                self.showResetStatus("导入失败：文件格式不正确", color: .systemRed)
                return
            }
            ConfigStore.save(imported)
            ThemeManager.current = imported.theme
            self.config = imported
            self.refreshValues()
            NotificationCenter.default.post(name: ConfigStore.didChange, object: nil)
            self.showResetStatus("已导入 ✓", color: .systemGreen)
        }
    }

    /// 重置桌面布局：清空文件夹与分页编排，保留应用与设置
    @objc private func resetLayoutClicked() {
        guard isConfirmingLayoutReset else {
            isConfirmingLayoutReset = true
            resetLayoutButton.title = "确认重置？"
            showResetStatus("将清空所有文件夹与页面编排，应用不受影响", color: .systemOrange)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isConfirmingLayoutReset else { return }
                self.isConfirmingLayoutReset = false
                self.resetLayoutButton.title = "重置桌面布局"
                self.resetStatusLabel.stringValue = ""
            }
            return
        }
        isConfirmingLayoutReset = false
        resetLayoutButton.title = "重置桌面布局"

        var latest = ConfigStore.load()
        latest.folders = []
        latest.pageOrders = []
        latest.itemOrder = []
        ConfigStore.save(latest)
        config.folders = []
        config.pageOrders = []
        config.itemOrder = []
        NotificationCenter.default.post(name: ConfigStore.didChange, object: nil)
        showResetStatus("桌面布局已重置 ✓", color: .systemGreen)
    }

    private func showResetStatus(_ text: String, color: NSColor) {
        resetStatusLabel.stringValue = text
        resetStatusLabel.textColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.resetStatusLabel.stringValue = ""
        }
    }

    /// 恢复默认设置：首次点击进入确认态，3 秒内再次点击才真正执行。
    /// 只重置「设置项」，不动文件夹与桌面分页，避免误删用户的桌面布局。
    @objc private func resetClicked() {
        guard isConfirmingReset else {
            isConfirmingReset = true
            resetButton.title = "确认恢复？"
            resetStatusLabel.stringValue = "仅重置设置项，保留文件夹与桌面布局"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isConfirmingReset else { return }
                self.isConfirmingReset = false
                self.resetButton.title = "恢复默认设置"
                self.resetStatusLabel.stringValue = ""
            }
            return
        }
        isConfirmingReset = false
        resetButton.title = "恢复默认设置"

        let defaults = AppConfig.defaults
        config.theme = defaults.theme
        config.backgroundImagePath = defaults.backgroundImagePath
        config.bgOpacity = defaults.bgOpacity
        config.bgBlur = defaults.bgBlur
        config.columns = defaults.columns
        config.rows = defaults.rows
        config.columnSpacing = defaults.columnSpacing
        config.rowSpacing = defaults.rowSpacing
        config.fullscreenSpacingScale = defaults.fullscreenSpacingScale
        config.iconSize = defaults.iconSize
        config.recursionDepth = defaults.recursionDepth
        config.scanPaths = defaults.scanPaths
        config.hotKeyEnabled = false
        config.hotKeyKeyCode = nil
        config.hotKeyModifiers = 0
        config.pinchEnabled = defaults.pinchEnabled
        config.pinchThreshold = defaults.pinchThreshold

        ThemeManager.current = config.theme
        refreshValues()
        scheduleSave()
        resetStatusLabel.stringValue = "已恢复默认设置 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.resetStatusLabel.stringValue = ""
        }
    }

    // MARK: - 关于

    @objc private func copyRepositoryURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AppVersion.repositoryURL, forType: .string)
        copyRepoFeedback.stringValue = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyRepoFeedback.stringValue = ""
        }
    }

    @objc private func closeClicked() {
        close()
    }

    // MARK: - 保存

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
        latest.columnSpacing = config.columnSpacing
        latest.rowSpacing = config.rowSpacing
        latest.fullscreenSpacingScale = config.fullscreenSpacingScale
        latest.iconSize = config.iconSize
        latest.hotKeyEnabled = config.hotKeyEnabled
        latest.hotKeyKeyCode = config.hotKeyKeyCode
        latest.hotKeyModifiers = config.hotKeyModifiers
        latest.pinchEnabled = config.pinchEnabled
        latest.pinchThreshold = config.pinchThreshold
        latest.launchAtLogin = config.launchAtLogin
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
        if let recordMonitor {
            NSEvent.removeMonitor(recordMonitor)
            self.recordMonitor = nil
        }
        isRecordingShortcut = false
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

// MARK: - 关闭按钮组件

final class CloseButton: NSButton {
    private var hovered = false

    init() {
        super.init(frame: .zero)
        title = "✕"
        isBordered = false
        font = .systemFont(ofSize: 10, weight: .bold)
        contentTintColor = .secondaryLabelColor
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 11
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateStyle()
    }

    private func updateStyle() {
        layer?.backgroundColor = hovered
            ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : .clear
        contentTintColor = hovered ? .labelColor : .secondaryLabelColor
    }
}

// MARK: - 链接按钮组件

/// 展示型链接按钮：强调色文字 + 手型光标，悬停加下划线，点击后由系统在浏览器中打开。
final class LinkButton: NSButton {
    private let targetURL: URL?

    init(url: String) {
        self.targetURL = URL(string: url)
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        alignment = .left
        imagePosition = .noImage
        attributedTitle = Self.attributedTitle(for: url, underlined: false)
        target = self
        action = #selector(openLink)
        toolTip = url
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func attributedTitle(for text: String, underlined: Bool) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.linkColor,
        ]
        if underlined {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    @objc private func openLink() {
        guard let targetURL else { return }
        NSWorkspace.shared.open(targetURL)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        attributedTitle = Self.attributedTitle(for: title, underlined: true)
    }

    override func mouseExited(with event: NSEvent) {
        attributedTitle = Self.attributedTitle(for: title, underlined: false)
    }
}

// MARK: - Tab 按钮组件

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

/// 拖动设置窗口。
///
/// 位移必须基于**屏幕坐标**计算：早先的实现用 `event.locationInWindow` 逐帧累加位移，
/// 但窗口一旦移动，同一个物理位置在窗口内的坐标就随之改变，于是位移被反向叠加回来，
/// 窗口在两帧之间来回跳——表现为拖动时不停抖动。
/// 这里改为在 mouseDown 记录「鼠标屏幕坐标 + 窗口原点」作为锚点，拖动时按绝对偏移定位。
final class DraggableView: NSView {
    weak var windowToMove: NSWindow?

    private var anchorMouseLocation: NSPoint?
    private var anchorWindowOrigin: NSPoint?

    private var targetWindow: NSWindow? { windowToMove ?? window }

    override func mouseDown(with event: NSEvent) {
        guard let target = targetWindow else { return }
        anchorMouseLocation = target.convertPoint(toScreen: event.locationInWindow)
        anchorWindowOrigin = target.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let target = targetWindow,
              let anchorMouse = anchorMouseLocation,
              let anchorOrigin = anchorWindowOrigin else { return }
        let current = target.convertPoint(toScreen: event.locationInWindow)
        target.setFrameOrigin(NSPoint(x: anchorOrigin.x + (current.x - anchorMouse.x),
                                      y: anchorOrigin.y + (current.y - anchorMouse.y)))
    }

    override func mouseUp(with event: NSEvent) {
        anchorMouseLocation = nil
        anchorWindowOrigin = nil
    }
}
