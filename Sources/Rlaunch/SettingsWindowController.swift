import Cocoa
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import RlaunchCore

// MARK: - 统一表单样式规范

/// 系统设置风格：分组圆角卡片 +「标题 / 副标题」行，控件右对齐。
/// 说明文字收敛为一行副标题或 tooltip，避免整页都是大段文字。
private enum SettingsMetrics {
    static let cardCorner: CGFloat = 10
    static let cardInsetH: CGFloat = 14        // 卡片内左右留白
    static let cardRowMinHeight: CGFloat = 44
    static let cardRowInsetV: CGFloat = 11
    static let sectionSpacing: CGFloat = 22    // 分组之间的间距
    static let sectionTitleGap: CGFloat = 7    // 分组标题与卡片之间
    static let controlSpacing: CGFloat = 16    // 文字与控件之间
    static let sliderWidth: CGFloat = 190
    static let valueWidth: CGFloat = 52
    static let sidebarWidth: CGFloat = 140
    static let contentWidth: CGFloat = 496     // 卡片宽度（与内容列宽对齐）

    /// 副标题文字颜色：在毛玻璃上比系统 secondary 略亮一档，保证可读性。
    /// 用动态色（按外观解析）而不是固定色，切换明亮/深黑时会自动跟着变。
    static let secondaryTextColor = NSColor(name: "rlaunchSettingsSecondary") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.68)
            : NSColor.black.withAlphaComponent(0.62)
    }
}

/// 设置窗口玻璃之上的自适应底色：深色压暗、浅色提亮，保证正文与卡片在任意桌面背景下都清晰。
/// 用自绘 + effectiveAppearance，主题切换（含「跟随系统」）时自动重解析，无需外部同步。
final class SettingsBackdropTintView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = isDark
            ? NSColor.black.withAlphaComponent(0.30).cgColor
            : NSColor.white.withAlphaComponent(0.44).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 分组卡片：随明暗主题自适应的圆角背景（无需 NSBox 分隔线）
final class SettingsCardView: NSView {
    private var edgeStroke: EdgeStrokeView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // 连续曲率圆角 + 自身 1px 描边：卡片内容（stack）是子层，会盖住 border，
        // 因此描边由 makeCard 在最上层安装的 EdgeStrokeView 负责，这里只保留底色。
        layer?.cornerRadius = SettingsMetrics.cardCorner
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0
        layer?.backgroundColor = dark
            ? NSColor.white.withAlphaComponent(0.07).cgColor
            : NSColor.white.withAlphaComponent(0.62).cgColor
        layer?.borderColor = dark
            ? NSColor.white.withAlphaComponent(0.09).cgColor
            : NSColor.black.withAlphaComponent(0.06).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 卡片描边：卡片宽度由约束固定，`.width/.height` 自适应即可跟随尺寸
    func installEdgeStroke() {
        guard edgeStroke == nil else { return }
        edgeStroke = EdgeStrokeView.install(on: self,
                                            cornerRadius: SettingsMetrics.cardCorner,
                                            width: 1,
                                            continuous: true)
    }
}

fileprivate func makeValueLabel() -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    l.textColor = .secondaryLabelColor
    l.alignment = .right
    l.translatesAutoresizingMaskIntoConstraints = false
    l.widthAnchor.constraint(equalToConstant: SettingsMetrics.valueWidth).isActive = true
    return l
}

/// 分组标题：小号次级文字，左对齐到卡片内容缩进
fileprivate func makeSectionTitle(_ title: String, isFirst: Bool = false) -> NSView {
    let holder = NSView()
    holder.translatesAutoresizingMaskIntoConstraints = false
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: SettingsMetrics.cardInsetH),
        label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -SettingsMetrics.cardInsetH),
        label.topAnchor.constraint(equalTo: holder.topAnchor, constant: isFirst ? 0 : SettingsMetrics.sectionSpacing),
        label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
    ])
    return holder
}

/// 卡内分隔线：左右与卡片内容对齐
fileprivate func makeCardSeparator() -> NSView {
    let holder = NSView()
    holder.translatesAutoresizingMaskIntoConstraints = false
    // 1 物理像素 + 系统 separatorColor：与原生列表分隔线一致，不会显得突兀
    let line = HairlineView()
    holder.addSubview(line)
    NSLayoutConstraint.activate([
        line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: SettingsMetrics.cardInsetH),
        line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -SettingsMetrics.cardInsetH),
        line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        holder.heightAnchor.constraint(equalToConstant: 1.0 / max(NSScreen.main?.backingScaleFactor ?? 2, 1)),
    ])
    return holder
}

/// 一行设置：左「图标? + 标题（+ 副标题）」，右控件
fileprivate func makeRow(_ title: String?,
                         icon: NSImage? = nil,
                         subtitle: String? = nil,
                         subtitleLabel: NSTextField? = nil,
                         subtitleColor: NSColor = .secondaryLabelColor,
                         tooltip: String? = nil,
                         control: NSView? = nil) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.toolTip = tooltip

    let textStack = NSStackView()
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2

    if let title, !title.isEmpty {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(titleLabel)
    }

    var sub = subtitleLabel
    if sub == nil, let subtitle, !subtitle.isEmpty {
        let label = NSTextField(labelWithString: subtitle)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        sub = label
    }
    if let sub {
        sub.font = .systemFont(ofSize: 11)
        // 比系统 secondaryLabelColor 略提一档：设置窗口是毛玻璃，纯 secondary 会偏灰看不清
        sub.textColor = subtitleColor == .secondaryLabelColor ? SettingsMetrics.secondaryTextColor : subtitleColor
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(sub)
    }

    // 左侧整体（可选图标 + 文案）
    let leadingStack = NSStackView()
    leadingStack.orientation = .horizontal
    leadingStack.alignment = .centerY
    leadingStack.spacing = 9
    if let icon {
        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        leadingStack.addArrangedSubview(iconView)
    }
    leadingStack.addArrangedSubview(textStack)
    leadingStack.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(leadingStack)

    var constraints: [NSLayoutConstraint] = [
        leadingStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SettingsMetrics.cardInsetH),
        leadingStack.topAnchor.constraint(equalTo: row.topAnchor, constant: SettingsMetrics.cardRowInsetV),
        row.bottomAnchor.constraint(equalTo: leadingStack.bottomAnchor, constant: SettingsMetrics.cardRowInsetV),
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsMetrics.cardRowMinHeight),
    ]

    if let control {
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)
        constraints += [
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -SettingsMetrics.cardInsetH),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: leadingStack.trailingAnchor,
                                             constant: SettingsMetrics.controlSpacing),
        ]
    } else {
        constraints.append(leadingStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor,
                                                                 constant: -SettingsMetrics.cardInsetH))
    }
    NSLayoutConstraint.activate(constraints)
    return row
}

/// 滑块行：统一滑块宽度并对齐右侧数值
fileprivate func makeSliderRow(_ title: String,
                               subtitle: String? = nil,
                               slider: NSSlider,
                               valueLabel: NSTextField) -> NSView {
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: SettingsMetrics.sliderWidth).isActive = true
    return makeRow(title, subtitle: subtitle, control: makeControlGroup([slider, valueLabel], spacing: 10))
}

/// 右对齐的控件组
fileprivate func makeControlGroup(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = spacing
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

/// 分组下方的单行说明（尽量少用；细节说明优先放 tooltip）
fileprivate func makeFootnote(_ text: String,
                              tooltip: String? = nil,
                              label: NSTextField? = nil) -> NSView {
    let holder = NSView()
    holder.translatesAutoresizingMaskIntoConstraints = false
    holder.toolTip = tooltip
    let field = label ?? NSTextField(wrappingLabelWithString: text)
    if label == nil { field.stringValue = text }
    field.font = .systemFont(ofSize: 11)
    field.textColor = .tertiaryLabelColor
    field.preferredMaxLayoutWidth = SettingsMetrics.contentWidth - SettingsMetrics.cardInsetH * 2
    field.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(field)
    NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: SettingsMetrics.cardInsetH),
        field.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -SettingsMetrics.cardInsetH),
        field.topAnchor.constraint(equalTo: holder.topAnchor, constant: 7),
        field.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
    ])
    return holder
}

/// 把行组装成一张分组卡片
fileprivate func makeCard(_ rows: [NSView]) -> NSView {
    let card = SettingsCardView()
    card.translatesAutoresizingMaskIntoConstraints = false
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 0
    stack.alignment = .width
    stack.translatesAutoresizingMaskIntoConstraints = false
    for (i, row) in rows.enumerated() {
        if i > 0 { stack.addArrangedSubview(makeCardSeparator()) }
        stack.addArrangedSubview(row)
    }
    card.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        stack.topAnchor.constraint(equalTo: card.topAnchor),
        stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        card.widthAnchor.constraint(equalToConstant: SettingsMetrics.contentWidth),
    ])
    // 描边必须最后安装：它自身没有子层，border 才不会被行内容盖住
    card.installEdgeStroke()
    return card
}

/// 让 child 撑满 host（用于动态重建的卡片容器）
fileprivate func addFilling(_ child: NSView, to host: NSView) {
    child.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        child.topAnchor.constraint(equalTo: host.topAnchor),
        child.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
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

/// 预设颜色单选圆形色块按钮：带外环高光指示、微质感纹理标记与悬停提示
final class ColorSwatchButton: NSControl {
    let preset: BackgroundPreset
    var isSelected: Bool = false {
        didSet { if oldValue != isSelected { needsDisplay = true } }
    }
    var onSelect: ((BackgroundPreset) -> Void)?
    var onHoverChanged: ((Bool, BackgroundPreset) -> Void)?
    private var isHovered: Bool = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
                onHoverChanged?(isHovered, preset)
            }
        }
    }

    init(preset: BackgroundPreset) {
        self.preset = preset
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = preset.name
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect?(preset)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let color = NSColor(
            calibratedRed: CGFloat(preset.red),
            green: CGFloat(preset.green),
            blue: CGFloat(preset.blue),
            alpha: 1.0
        )

        let isDarkPreset = (preset.red + preset.green + preset.blue) / 3.0 < 0.5

        if isSelected {
            // 选中外环：系统 Accent 强调色
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.8)
            ctx.strokeEllipse(in: bounds.insetBy(dx: 1.0, dy: 1.0))

            // 内层色块
            let innerRect = bounds.insetBy(dx: 3.5, dy: 3.5)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: innerRect)

            // 精细微弱描边
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: innerRect)

            drawTextureBadge(in: innerRect, isDark: isDarkPreset, in: ctx)
        } else {
            // 未选中色块
            let circleRect = bounds.insetBy(dx: isHovered ? 1.5 : 2.5, dy: isHovered ? 1.5 : 2.5)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: circleRect)

            // 边缘描边
            let strokeColor = isHovered
                ? NSColor.secondaryLabelColor.withAlphaComponent(0.65)
                : NSColor.black.withAlphaComponent(0.18)
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(isHovered ? 1.0 : 0.6)
            ctx.strokeEllipse(in: circleRect)

            drawTextureBadge(in: circleRect, isDark: isDarkPreset, in: ctx)
        }
    }

    private func drawTextureBadge(in rect: NSRect, isDark: Bool, in ctx: CGContext) {
        guard preset.texture != .none else { return }
        let stroke = isDark
            ? NSColor.white.withAlphaComponent(0.65).cgColor
            : NSColor.black.withAlphaComponent(0.40).cgColor

        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()

        ctx.setStrokeColor(stroke)
        ctx.setFillColor(stroke)

        switch preset.texture {
        case .none:
            break
        case .twill:
            // 两条精致的 45° 微斜线
            ctx.setLineWidth(1.0)
            let cx = rect.midX
            let cy = rect.midY
            ctx.move(to: CGPoint(x: cx - 4, y: cy + 4))
            ctx.addLine(to: CGPoint(x: cx + 4, y: cy - 4))
            ctx.move(to: CGPoint(x: cx - 2, y: cy + 6))
            ctx.addLine(to: CGPoint(x: cx + 6, y: cy - 2))
            ctx.strokePath()
        case .noise:
            // 4 个精致微粒小点
            let cx = rect.midX
            let cy = rect.midY
            let r: CGFloat = 0.8
            ctx.fillEllipse(in: CGRect(x: cx - 3, y: cy + 2, width: r, height: r))
            ctx.fillEllipse(in: CGRect(x: cx + 2, y: cy + 3, width: r, height: r))
            ctx.fillEllipse(in: CGRect(x: cx - 1, y: cy - 2, width: r, height: r))
            ctx.fillEllipse(in: CGRect(x: cx + 3, y: cy - 3, width: r, height: r))
        case .dotGrid:
            // 2×2 精密微点阵
            let cx = rect.midX
            let cy = rect.midY
            let r: CGFloat = 1.0
            ctx.fillEllipse(in: CGRect(x: cx - 3, y: cy + 2, width: r, height: r))
            ctx.fillEllipse(in: CGRect(x: cx + 2, y: cy + 2, width: r, height: r))
            ctx.fillEllipse(in: CGRect(x: cx - 3, y: cy - 3, width: r, height: r))
            ctx.fillEllipse(in: CGRect(x: cx + 2, y: cy - 3, width: r, height: r))
        case .grid:
            // 极细微十字方格
            ctx.setLineWidth(0.8)
            let cx = rect.midX
            let cy = rect.midY
            ctx.move(to: CGPoint(x: cx - 4, y: cy))
            ctx.addLine(to: CGPoint(x: cx + 4, y: cy))
            ctx.move(to: CGPoint(x: cx, y: cy - 4))
            ctx.addLine(to: CGPoint(x: cx, y: cy + 4))
            ctx.strokePath()
        case .brushed:
            // 水平微拉丝
            ctx.setLineWidth(0.8)
            let cx = rect.midX
            let cy = rect.midY
            ctx.move(to: CGPoint(x: cx - 4, y: cy + 2))
            ctx.addLine(to: CGPoint(x: cx + 4, y: cy + 2))
            ctx.move(to: CGPoint(x: cx - 4, y: cy - 2))
            ctx.addLine(to: CGPoint(x: cx + 4, y: cy - 2))
            ctx.strokePath()
        }

        ctx.restoreGState()
    }
}

/// 预设颜色调色板组件：色块排布与名称/纹理标签
final class PresetPaletteView: NSView {
    private let presets: [BackgroundPreset]
    private var swatchButtons: [ColorSwatchButton] = []
    private let nameLabel = NSTextField(labelWithString: "")
    var selectedId: String {
        didSet { updateSelection() }
    }
    var onSelect: ((String) -> Void)?

    init(presets: [BackgroundPreset], selectedId: String) {
        self.presets = presets
        self.selectedId = selectedId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 5
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 5
        buttonRow.alignment = .centerY

        for preset in presets {
            let btn = ColorSwatchButton(preset: preset)
            btn.isSelected = (preset.id == selectedId)
            btn.onSelect = { [weak self] p in
                self?.selectedId = p.id
                self?.onSelect?(p.id)
            }
            btn.onHoverChanged = { [weak self] isHovered, p in
                self?.handleHover(isHovered: isHovered, preset: p)
            }
            swatchButtons.append(btn)
            buttonRow.addArrangedSubview(btn)
        }
        rootStack.addArrangedSubview(buttonRow)

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rootStack.addArrangedSubview(nameLabel)

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setEnabled(_ enabled: Bool) {
        alphaValue = enabled ? 1.0 : 0.45
        for btn in swatchButtons {
            btn.isEnabled = enabled
        }
    }

    private func handleHover(isHovered: Bool, preset: BackgroundPreset) {
        if isHovered {
            nameLabel.stringValue = displayName(for: preset)
        } else {
            updateSelection()
        }
    }

    private func updateSelection() {
        for btn in swatchButtons {
            btn.isSelected = (btn.preset.id == selectedId)
        }
        if let current = presets.first(where: { $0.id == selectedId }) {
            nameLabel.stringValue = displayName(for: current)
        }
    }

    private func displayName(for preset: BackgroundPreset) -> String {
        let baseName = L10n.t(preset.name)
        if preset.texture != .none {
            return "\(baseName)  ·  \(textureDescription(preset.texture))"
        }
        return baseName
    }

    private func textureDescription(_ texture: BackgroundTexture) -> String {
        switch texture {
        case .none: return ""
        case .twill: return L10n.t("微斜纹")
        case .noise: return L10n.t("微粒磨砂")
        case .dotGrid: return L10n.t("微点阵")
        case .grid: return L10n.t("微方格")
        case .brushed: return L10n.t("微拉丝")
        }
    }

    func retranslate() {
        for btn in swatchButtons {
            btn.toolTip = L10n.t(btn.preset.name)
        }
        updateSelection()
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

    /// 与 SystemGlass.makeContainer 保持一致的窗口圆角
    private static let windowCornerRadius: CGFloat = 14

    private var config = ConfigStore.load()
    private var saveDebounce: Timer?
    private var keyMonitor: Any?
    private var recordMonitor: Any?
    private var isRecordingShortcut = false

    // MARK: - 控件定义

    // 外观
    private let themeControl = NSSegmentedControl(
        labels: [L10n.t("明亮"), L10n.t("深黑"), L10n.t("跟随系统")], trackingMode: .selectOne, target: nil, action: nil)
    private var darkPaletteView: PresetPaletteView!
    private var lightPaletteView: PresetPaletteView!
    /// 背景颜色卡片的容器（按当前主题重建，避免残留分隔线）
    private let paletteCardHost = NSView()
    private var paletteShowingDark: Bool?
    private let bgPathLabel = NSTextField(labelWithString: L10n.t("默认（系统毛玻璃）"))
    private let chooseBgButton = NSButton(title: L10n.t("选择图片…"), target: nil, action: nil)
    private let clearBgButton = NSButton(title: L10n.t("清除"), target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.85, minValue: 0.15, maxValue: 1.0, target: nil, action: nil)
    private let opacityValue = makeValueLabel()
    private let blurSlider = NSSlider(value: 0, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let blurValue = makeValueLabel()

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
    private let scanListHost = NSView()
    private let hiddenListHost = NSView()
    private let addPathButton = NSButton(title: L10n.t("添加目录…"), target: nil, action: nil)
    private let depthStepper: NSStepper = makeStepper(value: 3, min: 1, max: 6)
    private var depthBox: NumberStepperBox!
    private let rescanButtonScanTab = NSButton(title: L10n.t("立即重新扫描"), target: nil, action: nil)
    private let rescanStatusScanTab = NSTextField(labelWithString: "")

    // 快捷键与手势
    private let hotKeySwitch = NSSwitch()
    private let hotKeyBadge = NSView()
    private let hotKeyLabel = NSTextField(labelWithString: L10n.t("未设置"))
    private let recordButton = NSButton(title: L10n.t("录制快捷键…"), target: nil, action: nil)
    private let clearShortcutButton = NSButton(title: L10n.t("清除"), target: nil, action: nil)

    private let pinchSwitch = NSSwitch()
    private let pinchSlider = NSSlider(value: 0.7, minValue: 0.3, maxValue: 2.0, target: nil, action: nil)
    private let pinchValue = makeValueLabel()

    private let axStatusLabel = NSTextField(labelWithString: L10n.t("辅助功能：未授权"))
    private let axButton = NSButton(title: L10n.t("打开权限设置…"), target: nil, action: nil)
    private let trackpadButton = NSButton(title: L10n.t("触控板手势设置…"), target: nil, action: nil)

    // 通用
    private let languageControl = NSSegmentedControl(
        labels: AppLanguage.allCases.map { $0.displayName }, trackingMode: .selectOne, target: nil, action: nil)
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginStatus = NSTextField(labelWithString: "")
    private let rescanButtonGeneralTab = NSButton(title: L10n.t("重新扫描应用"), target: nil, action: nil)
    private let rescanStatusGeneralTab = NSTextField(labelWithString: "")
    private let openConfigButton = NSButton(title: L10n.t("打开配置目录"), target: nil, action: nil)
    private let exportConfigButton = NSButton(title: L10n.t("导出…"), target: nil, action: nil)
    private let importConfigButton = NSButton(title: L10n.t("导入…"), target: nil, action: nil)
    private let resetButton = NSButton(title: L10n.t("恢复默认设置"), target: nil, action: nil)
    private let resetLayoutButton = NSButton(title: L10n.t("重置桌面布局"), target: nil, action: nil)
    private let resetStatusLabel = NSTextField(labelWithString: "")
    private var isConfirmingReset = false
    /// 「当前背景渲染方式」提示（含格式参数，无法反查，需单独刷新）
    private var rendererHintLabel: NSTextField?
    private var isConfirmingLayoutReset = false

    // 关于
    private let githubLinkButton = LinkButton(url: AppVersion.repositoryURL)
    private let copyRepoButton = NSButton(title: L10n.t("复制地址"), target: nil, action: nil)
    private let copyRepoFeedback = NSTextField(labelWithString: "")

    // 窗口元素
    private var windowEdgeStroke: EdgeStrokeView?
    /// 玻璃之上的自适应底色：保证文字/卡片在任意桌面背景下都有稳定对比度
    private let contentTint = SettingsBackdropTintView()
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
    private let headerTitle = NSTextField(labelWithString: L10n.t("Rlaunch 设置"))
    private let closeButton = CloseButton()

    // MARK: - 布局与对齐核心辅助

    private static var rendererHintText: String {
        L10n.f("当前背景渲染方式：%@。", L10n.t(SystemGlass.rendererName))
    }

    /// 统一布局计算
    private func layoutContent() {
        guard let scrollView, let containerView, let headerView, let tabBarView,
              let glassView, let contentHost else { return }
        // 原生玻璃的内容由 contentView 承载，需显式与玻璃视图对齐
        contentHost.frame = glassView.bounds
        contentTint.frame = contentHost.bounds
        windowEdgeStroke?.frame = glassView.bounds
        let area = glassView.bounds
        let width = max(area.width, 640)
        let height = max(area.height, 480)

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
        tabBarView.frame = NSRect(x: 16, y: 14, width: SettingsMetrics.sidebarWidth, height: contentH_)
        let scrollX: CGFloat = 16 + SettingsMetrics.sidebarWidth + 16
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

        // 当前页内容高度与对齐（先定宽度再取高度：卡片高度依赖固定列宽）
        guard currentTab < contentPages.count, currentTab < contentStacks.count else { return }
        let page = contentPages[currentTab]
        let stack = contentStacks[currentTab]
        let pageW = max(scrollView.frame.width, 320)
        let stackW = pageW - 8
        stack.frame = NSRect(x: 4, y: 0, width: stackW, height: 10)
        stack.layoutSubtreeIfNeeded()
        let stackH = stack.fittingSize.height
        let contentH = max(stackH + 24, scrollView.bounds.height)
        page.frame = NSRect(x: 0, y: 0, width: pageW, height: contentH)
        containerView.frame = NSRect(x: 0, y: 0, width: pageW, height: contentH)
        stack.frame = NSRect(x: 4, y: contentH - stackH - 12, width: stackW, height: stackH)
    }

    // MARK: - 初始化

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
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
        let (glassView, contentHost) = SystemGlass.makeContainer(cornerRadius: Self.windowCornerRadius, material: .popover)
        glassView.autoresizingMask = [.width, .height]
        glassView.frame = drag.bounds
        drag.addSubview(glassView)

        contentHost.autoresizingMask = [.width, .height]
        contentHost.frame = glassView.bounds
        self.glassView = glassView
        self.contentHost = contentHost

        // 窗口最外圈描边：设置窗口轮廓由系统玻璃视图裁剪（圆角只能为圆形），用圆形描边贴合
        windowEdgeStroke = EdgeStrokeView.install(on: drag,
                                                  cornerRadius: Self.windowCornerRadius,
                                                  width: nil,
                                                  continuous: false)

        // 自适应底色（最先添加 → 位于 Tab 栏与内容之下）
        contentHost.addSubview(contentTint)

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

        darkPaletteView = PresetPaletteView(
            presets: BackgroundPresets.darkPresets,
            selectedId: config.darkBgPreset
        )
        darkPaletteView.onSelect = { [weak self] id in
            self?.config.darkBgPreset = id
            self?.refreshValues(heavy: false)
            self?.scheduleSave()
        }

        lightPaletteView = PresetPaletteView(
            presets: BackgroundPresets.lightPresets,
            selectedId: config.lightBgPreset
        )
        lightPaletteView.onSelect = { [weak self] id in
            self?.config.lightBgPreset = id
            self?.refreshValues(heavy: false)
            self?.scheduleSave()
        }

        buildTabsAndPages()
        refreshValues()
        updateContentTint()
        layoutContent()

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChangeNotification), name: .themeDidChange, object: nil)

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
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
    }

    // MARK: - Tab 构建

    private func buildTabsAndPages() {
        configureControls()

        // 标签顺序：通用置顶，「关于」独立成页放在最后
        let titles = [L10n.t("通用"), L10n.t("外观"), L10n.t("网格"),
                      L10n.t("应用扫描"), L10n.t("快捷键"), L10n.t("关于")]
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
            stack.spacing = SettingsMetrics.sectionTitleGap
            page.addSubview(stack)
            contentPages.append(page)
            contentStacks.append(stack)
            containerView.addSubview(page)
        }

        buildGeneralPage(contentStacks[0])
        buildAppearancePage(contentStacks[1])
        buildGridPage(contentStacks[2])
        buildScanPage(contentStacks[3])
        buildShortcutPage(contentStacks[4])
        buildAboutPage(contentStacks[5])

        // 注册常规配置变更事件
        let controls: [NSControl] = [themeControl, opacitySlider, blurSlider, columnsStepper,
                                     rowsStepper, columnSpacingSlider, rowSpacingSlider, fullscreenScaleSlider,
                                     iconSizeSlider, depthStepper, pinchSlider, pinchSwitch, hotKeySwitch,
                                     languageControl]
        for c in controls {
            c.target = self
            c.action = #selector(controlChanged)
            if let slider = c as? NSSlider { slider.isContinuous = true }
        }
        selectTab(0)
    }



    /// 统一按钮样式与事件绑定（页面构建只负责排版，不再各写一份）
    private func configureControls() {
        let buttons: [(NSButton, Selector)] = [
            (chooseBgButton, #selector(chooseBackground)),
            (clearBgButton, #selector(clearBackground)),
            (addPathButton, #selector(addScanPath)),
            (rescanButtonScanTab, #selector(rescanClicked)),
            (rescanButtonGeneralTab, #selector(rescanClicked)),
            (recordButton, #selector(recordShortcut)),
            (clearShortcutButton, #selector(clearShortcut)),
            (axButton, #selector(openAccessibilitySettings)),
            (trackpadButton, #selector(openTrackpadSettings)),
            (openConfigButton, #selector(openConfigFolder)),
            (exportConfigButton, #selector(exportConfig)),
            (importConfigButton, #selector(importConfig)),
            (resetButton, #selector(resetClicked)),
            (resetLayoutButton, #selector(resetLayoutClicked)),
            (copyRepoButton, #selector(copyRepositoryURL)),
        ]
        for (button, action) in buttons {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        for toggle in [hotKeySwitch, pinchSwitch, launchAtLoginSwitch] {
            toggle.controlSize = .small
        }
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged)

        for control in [themeControl, languageControl] {
            control.controlSize = .small
        }
        axStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        for status in [rescanStatusScanTab, rescanStatusGeneralTab, copyRepoFeedback, launchAtLoginStatus, resetStatusLabel] {
            status.maximumNumberOfLines = 1
            status.lineBreakMode = .byTruncatingTail
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        rescanStatusScanTab.font = .systemFont(ofSize: 11)
        rescanStatusGeneralTab.font = .systemFont(ofSize: 11)
        rescanStatusScanTab.textColor = .secondaryLabelColor
        rescanStatusGeneralTab.textColor = .secondaryLabelColor
    }

    // MARK: 1. 通用设置
    private func buildGeneralPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionTitle(L10n.t("通用"), isFirst: true))

        launchAtLoginStatus.font = .systemFont(ofSize: 11)
        launchAtLoginStatus.textColor = .secondaryLabelColor
        launchAtLoginStatus.maximumNumberOfLines = 1
        launchAtLoginStatus.lineBreakMode = .byTruncatingTail

        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("界面语言"),
                    subtitle: L10n.t("切换后立即生效，无需重启"),
                    control: languageControl),
            makeRow(L10n.t("开机启动"), subtitleLabel: launchAtLoginStatus, control: launchAtLoginSwitch),
            makeRow(L10n.t("应用索引"),
                    subtitle: L10n.t("每次打开界面都会自动增量更新"),
                    control: makeControlGroup([rescanButtonGeneralTab, rescanStatusGeneralTab], spacing: 10)),
        ]))

        stack.addArrangedSubview(makeSectionTitle(L10n.t("配置文件")))

        resetStatusLabel.font = .systemFont(ofSize: 11)
        resetStatusLabel.textColor = .systemOrange
        resetStatusLabel.maximumNumberOfLines = 1
        resetStatusLabel.lineBreakMode = .byTruncatingTail

        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("备份与迁移"),
                    subtitle: L10n.t("包含文件夹与页面编排"),
                    control: makeControlGroup([openConfigButton, exportConfigButton, importConfigButton])),
            makeRow(L10n.t("重置"),
                    subtitleLabel: resetStatusLabel,
                    tooltip: L10n.t("恢复默认设置仅重置设置项；重置桌面布局仅清空文件夹与页面编排"),
                    control: makeControlGroup([resetButton, resetLayoutButton])),
        ]))
    }

    // MARK: 2. 外观设置
    private func buildAppearancePage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionTitle(L10n.t("外观"), isFirst: true))
        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("外观模式"), control: themeControl),
        ]))

        // 背景颜色：只展示当前生效主题对应的调色板（内容随主题重建，避免残留分隔线）
        stack.addArrangedSubview(makeSectionTitle(L10n.t("背景颜色")))
        paletteCardHost.translatesAutoresizingMaskIntoConstraints = false
        paletteCardHost.widthAnchor.constraint(equalToConstant: SettingsMetrics.contentWidth).isActive = true
        stack.addArrangedSubview(paletteCardHost)
        rebuildPaletteCard(force: true)

        stack.addArrangedSubview(makeSectionTitle(L10n.t("背景图片")))

        bgPathLabel.font = .systemFont(ofSize: 11)
        bgPathLabel.textColor = .secondaryLabelColor
        bgPathLabel.lineBreakMode = .byTruncatingMiddle
        bgPathLabel.maximumNumberOfLines = 1
        bgPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("图片"),
                    subtitleLabel: bgPathLabel,
                    control: makeControlGroup([chooseBgButton, clearBgButton])),
            makeSliderRow(L10n.t("透明度"), slider: opacitySlider, valueLabel: opacityValue),
            makeSliderRow(L10n.t("模糊程度"),
                          subtitle: L10n.t("仅在使用自定义背景图片时生效"),
                          slider: blurSlider,
                          valueLabel: blurValue),
        ]))

        let rendererHint = NSTextField(wrappingLabelWithString: Self.rendererHintText)
        rendererHintLabel = rendererHint
        stack.addArrangedSubview(makeFootnote("", label: rendererHint))
    }

    // MARK: 3. 网格设置
    private func buildGridPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionTitle(L10n.t("布局规格"), isFirst: true))
        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("列数"), control: columnsBox),
            makeRow(L10n.t("行数"), control: rowsBox),
            makeSliderRow(L10n.t("列间距"), slider: columnSpacingSlider, valueLabel: columnSpacingValue),
            makeSliderRow(L10n.t("行间距"), slider: rowSpacingSlider, valueLabel: rowSpacingValue),
            makeSliderRow(L10n.t("全屏缩放"), slider: fullscreenScaleSlider, valueLabel: fullscreenScaleValue),
            makeSliderRow(L10n.t("图标大小"), slider: iconSizeSlider, valueLabel: iconSizeValue),
        ]))
        stack.addArrangedSubview(makeFootnote(L10n.t("窗口缩小时会自动收紧行数与图标尺寸，不会被顶栏遮挡。")))
    }

    // MARK: 4. 应用扫描设置
    private func buildScanPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionTitle(L10n.t("扫描目录"), isFirst: true))
        scanListHost.translatesAutoresizingMaskIntoConstraints = false
        scanListHost.widthAnchor.constraint(equalToConstant: SettingsMetrics.contentWidth).isActive = true
        stack.addArrangedSubview(scanListHost)
        stack.addArrangedSubview(makeFootnote(L10n.t("新增或移除应用后会自动更新索引，无需手动刷新。")))

        stack.addArrangedSubview(makeSectionTitle(L10n.t("扫描参数与操作")))
        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("递归层级"),
                    subtitle: L10n.t("搜索应用时的最大目录深度（建议 3）"),
                    control: depthBox),
            makeRow(L10n.t("应用索引"),
                    control: makeControlGroup([rescanButtonScanTab, rescanStatusScanTab], spacing: 10)),
        ]))

        stack.addArrangedSubview(makeSectionTitle(L10n.t("已隐藏的应用")))
        hiddenListHost.translatesAutoresizingMaskIntoConstraints = false
        hiddenListHost.widthAnchor.constraint(equalToConstant: SettingsMetrics.contentWidth).isActive = true
        stack.addArrangedSubview(hiddenListHost)
        stack.addArrangedSubview(makeFootnote(
            L10n.t("在主界面右键应用选择「从启动台隐藏」后，可在这里恢复。")))
    }

    // MARK: 5. 快捷键与手势设置
    private func buildShortcutPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionTitle(L10n.t("全局快捷键"), isFirst: true))

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

        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("启用全局快捷键唤起"), control: hotKeySwitch),
            makeRow(L10n.t("唤起快捷键"),
                    control: makeControlGroup([hotKeyBadge, recordButton, clearShortcutButton])),
        ]))

        stack.addArrangedSubview(makeSectionTitle(L10n.t("触控板手势")))
        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("四指/五指捏合：打开并全屏"), control: pinchSwitch),
            makeSliderRow(L10n.t("灵敏度"), slider: pinchSlider, valueLabel: pinchValue),
        ]))
        stack.addArrangedSubview(makeFootnote(
            L10n.t("捏合识别需要「辅助功能」权限。"),
            tooltip: L10n.t("手势说明：四指/五指捏合通过系统触摸点间距收缩算法识别（需要辅助功能权限）。若系统已授权仍无法使用，可在「辅助功能」中先移除 Rlaunch 再重新添加，并在「触控板手势设置」中检查是否被系统默认手势占用。")))

        stack.addArrangedSubview(makeSectionTitle(L10n.t("系统权限与手势")))
        stack.addArrangedSubview(makeCard([
            makeRow(L10n.t("辅助功能"), control: makeControlGroup([axStatusLabel, axButton], spacing: 10)),
            makeRow(L10n.t("触控板"), control: trackpadButton),
        ]))
    }

    // MARK: 6. 关于（独立标签页）
    private func buildAboutPage(_ stack: NSStackView) {
        stack.addArrangedSubview(makeSectionTitle(L10n.t("关于"), isFirst: true))

        githubLinkButton.toolTip = L10n.f("在浏览器中打开 %@", AppVersion.repositoryURL)
        copyRepoFeedback.font = .systemFont(ofSize: 11)
        copyRepoFeedback.textColor = .systemGreen
        copyRepoFeedback.maximumNumberOfLines = 1

        stack.addArrangedSubview(makeCard([
            makeRow("Rlaunch", subtitle: AppVersion.displayFull, control: nil),
            makeRow(L10n.t("项目主页"),
                    control: makeControlGroup([githubLinkButton, copyRepoButton, copyRepoFeedback], spacing: 10)),
        ]))
        stack.addArrangedSubview(makeFootnote(
            L10n.t("Rlaunch · 轻量高效的 macOS 启动台平替。点击 GitHub 地址可在浏览器中打开项目主页。")))
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
        scrollToTop()
    }

    /// 滚动回顶部。
    /// 文档视图未设 `isFlipped`，`.zero` 其实是左下角——内容超出可视高度时会停在底部，
    /// 把最上面的分组裁掉（英文文案更长、页面更高时尤其明显）。
    private func scrollToTop() {
        let maxY = max(0, containerView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
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
        languageControl.selectedSegment = AppLanguage.allCases.firstIndex(of: config.language) ?? 0

        darkPaletteView.selectedId = config.darkBgPreset
        lightPaletteView.selectedId = config.lightBgPreset
        let hasCustomImage = config.backgroundImagePath != nil && !config.backgroundImagePath!.isEmpty
        darkPaletteView.setEnabled(!hasCustomImage)
        lightPaletteView.setEnabled(!hasCustomImage)

        // 背景图与模糊联动
        if let path = config.backgroundImagePath, !path.isEmpty {
            bgPathLabel.stringValue = (path as NSString).lastPathComponent
            clearBgButton.isEnabled = true
            blurSlider.isEnabled = true
            blurValue.textColor = .secondaryLabelColor
        } else {
            bgPathLabel.stringValue = L10n.t("默认（系统毛玻璃）")
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

        updatePaletteVisibility()
    }

    @objc private func themeDidChangeNotification() {
        updateContentTint()
        updatePaletteVisibility()
        layoutContent()
    }

    /// 玻璃之上的自适应底色由 SettingsBackdropTintView 自绘，这里只需让它重画
    private func updateContentTint() {
        contentTint.needsDisplay = true
    }

    private func updatePaletteVisibility() {
        updateContentTint()
        rebuildPaletteCard()
    }

    /// 当前生效的明暗（跟随系统时以窗口实际外观为准）
    private func isEffectiveDark() -> Bool {
        switch config.theme {
        case .dark: return true
        case .light: return false
        case .system:
            return (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// 背景颜色卡片：只保留当前主题对应的调色板，重建时不会残留多余分隔线
    private func rebuildPaletteCard(force: Bool = false) {
        let dark = isEffectiveDark()
        if !force, paletteShowingDark == dark, !paletteCardHost.subviews.isEmpty { return }
        paletteShowingDark = dark
        paletteCardHost.subviews.forEach { $0.removeFromSuperview() }
        let palette = dark ? darkPaletteView : lightPaletteView
        let card = makeCard([
            makeRow(L10n.t("背景颜色"),
                    subtitle: L10n.t("点击色块即可切换背景"),
                    control: palette),
        ])
        addFilling(card, to: paletteCardHost)
        paletteCardHost.needsLayout = true
    }

    /// 与系统登录项状态同步（以系统状态为准）
    private func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            launchAtLoginSwitch.state = .on
            launchAtLoginStatus.stringValue = L10n.t("状态：已开启（登录时自动启动）")
            launchAtLoginStatus.textColor = .systemGreen
        case .requiresApproval:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatus.stringValue = L10n.t("状态：需要系统授权（请在系统设置中允许）")
            launchAtLoginStatus.textColor = .systemOrange
        case .notRegistered:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatus.stringValue = L10n.t("状态：未开启")
            launchAtLoginStatus.textColor = .secondaryLabelColor
        case .notFound:
            launchAtLoginSwitch.state = .off
            launchAtLoginStatus.stringValue = L10n.t("状态：未找到应用副本，请放入「应用程序」文件夹")
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
        axStatusLabel.stringValue = trusted ? L10n.t("辅助功能：已授权 ✓") : L10n.t("辅助功能：未授权")
        axStatusLabel.textColor = trusted ? .systemGreen : .systemRed
    }

    private func rebuildScanRows() {
        scanListHost.subviews.forEach { $0.removeFromSuperview() }
        var rows: [NSView] = []

        if config.scanPaths.isEmpty {
            rows.append(makeRow(L10n.t("未配置扫描目录"),
                                subtitle: L10n.t("点击下方按钮添加要扫描的应用目录"),
                                control: nil))
        } else {
            for (index, path) in config.scanPaths.enumerated() {
                let expanded = NSString(string: path).expandingTildeInPath
                let del = NSButton(title: "✕", target: self, action: #selector(removeScanPath(_:)))
                del.isBordered = false
                del.bezelStyle = .inline
                del.font = .systemFont(ofSize: 10, weight: .bold)
                del.contentTintColor = .secondaryLabelColor
                del.toolTip = L10n.t("移除该目录")
                del.tag = index
                rows.append(makeRow((path as NSString).abbreviatingWithTildeInPath,
                                    icon: NSWorkspace.shared.icon(forFile: expanded),
                                    control: del))
            }
        }

        // 最后一行放「添加目录…」按钮（右对齐）
        rows.append(makeRow(nil, control: addPathButton))
        addFilling(makeCard(rows), to: scanListHost)
        layoutContent()
    }

    /// 重建「已隐藏的应用」列表
    private func rebuildHiddenRows() {
        hiddenListHost.subviews.forEach { $0.removeFromSuperview() }
        var rows: [NSView] = []

        if config.hiddenAppPaths.isEmpty {
            rows.append(makeRow(L10n.t("没有被隐藏的应用"), control: nil))
        } else {
            for (index, path) in config.hiddenAppPaths.enumerated() {
                let pathLabel = NSTextField(labelWithString: path)
                pathLabel.maximumNumberOfLines = 1
                pathLabel.lineBreakMode = .byTruncatingMiddle

                let restore = NSButton(title: L10n.t("恢复"), target: self, action: #selector(restoreHiddenApp(_:)))
                restore.bezelStyle = .inline
                restore.isBordered = false
                restore.font = .systemFont(ofSize: 11, weight: .medium)
                restore.contentTintColor = .controlAccentColor
                restore.toolTip = L10n.t("恢复显示")
                restore.tag = index

                rows.append(makeRow(FileManager.default.displayName(atPath: path),
                                    icon: NSWorkspace.shared.icon(forFile: path),
                                    subtitleLabel: pathLabel,
                                    tooltip: path,
                                    control: restore))
            }
        }

        addFilling(makeCard(rows), to: hiddenListHost)
        layoutContent()
    }

    // MARK: - 事件处理

    @objc private func controlChanged(_ sender: Any?) {
        let previousLanguage = config.language
        config.theme = themeControl.selectedSegment == 0 ? .light : (themeControl.selectedSegment == 1 ? .dark : .system)
        let languageIndex = max(0, min(languageControl.selectedSegment, AppLanguage.allCases.count - 1))
        config.language = AppLanguage.allCases[languageIndex]
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

        // 语言切换：立即落盘并通知全局重建界面。
        // 异步派发，避免在设置窗口自身的回调里把它释放掉。
        if config.language != previousLanguage {
            L10n.setLanguage(config.language)
            persist()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: ConfigStore.didChange, object: nil)
            }
        }

        refreshValues(heavy: false)
        updatePaletteVisibility()
        layoutContent()
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
        recordButton.title = L10n.t("按下快捷键… (Esc 取消)")
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
        recordButton.title = L10n.t("录制快捷键…")
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
        panel.message = L10n.t("选择要扫描的应用目录")
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
        let index = sender.tag
        guard index >= 0, index < config.scanPaths.count else { return }
        config.scanPaths.remove(at: index)
        refreshValues()
        scheduleSave()
    }

    /// 恢复被隐藏的应用（交互元素在重建行时动态创建，故用菜单/按钮的 hover 行反查路径）
    @objc private func restoreHiddenApp(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < config.hiddenAppPaths.count else { return }
        config.hiddenAppPaths.remove(at: index)
        refreshValues()
        scheduleSave()
    }

    @objc private func rescanClicked() {
        onRescan?()
        rescanStatusScanTab.stringValue = L10n.t("已触发重新扫描 ✓")
        rescanStatusGeneralTab.stringValue = L10n.t("已触发重新扫描 ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.rescanStatusScanTab.stringValue = ""
            self?.rescanStatusGeneralTab.stringValue = ""
        }
    }

    // MARK: - 就地切换语言

    /// 切换语言时就地刷新界面文案。
    ///
    /// 不重建窗口：重建会整块闪烁，还会丢掉滚动位置与当前所在标签页。
    /// 做法是遍历视图树，把「已知译文」反查回键、再写成新语言；
    /// 应用名、路径、数值等非文案内容反查不到，原样保留。
    func retranslateInterface() {
        retranslateTree(in: window?.contentView)
        // 含格式参数的文案无法反查，单独刷新
        rendererHintLabel?.stringValue = Self.rendererHintText
        githubLinkButton.toolTip = L10n.f("在浏览器中打开 %@", AppVersion.repositoryURL)
        darkPaletteView?.retranslate()
        lightPaletteView?.retranslate()
        layoutContent()
    }

    private func retranslateTree(in view: NSView?) {
        guard let view else { return }
        switch view {
        case let tab as TabButton:
            // TabButton 用 attributedTitle 控制缩进与配色，需走它自己的 setter
            tab.applyLocalizedTitle(L10n.retranslate(tab.title))
        case is LinkButton:
            break   // 显示的是 URL，不翻译，也不能覆盖其 attributedTitle
        case let button as NSButton:
            button.title = L10n.retranslate(button.title)
            button.toolTip = button.toolTip.map(L10n.retranslate)
        case let segmented as NSSegmentedControl:
            for index in 0..<segmented.segmentCount {
                guard let label = segmented.label(forSegment: index) else { continue }
                segmented.setLabel(L10n.retranslate(label), forSegment: index)
            }
        case let field as NSTextField:
            field.stringValue = L10n.retranslate(field.stringValue)
            field.toolTip = field.toolTip.map(L10n.retranslate)
        default:
            view.toolTip = view.toolTip.map(L10n.retranslate)
        }
        for subview in view.subviews { retranslateTree(in: subview) }
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
                self.showResetStatus(L10n.t("已导出 ✓"), color: .systemGreen)
            } catch {
                self.showResetStatus(L10n.f("导出失败：%@", error.localizedDescription), color: .systemRed)
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
        panel.message = L10n.t("选择要导入的 Rlaunch 配置文件")
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url),
                  let imported = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                self.showResetStatus(L10n.t("导入失败：文件格式不正确"), color: .systemRed)
                return
            }
            ConfigStore.save(imported)
            ThemeManager.current = imported.theme
            self.config = imported
            self.refreshValues()
            NotificationCenter.default.post(name: ConfigStore.didChange, object: nil)
            self.showResetStatus(L10n.t("已导入 ✓"), color: .systemGreen)
        }
    }

    /// 重置桌面布局：清空文件夹与分页编排，保留应用与设置
    @objc private func resetLayoutClicked() {
        guard isConfirmingLayoutReset else {
            isConfirmingLayoutReset = true
            resetLayoutButton.title = L10n.t("确认重置？")
            showResetStatus(L10n.t("将清空所有文件夹与页面编排，应用不受影响"), color: .systemOrange)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isConfirmingLayoutReset else { return }
                self.isConfirmingLayoutReset = false
                self.resetLayoutButton.title = L10n.t("重置桌面布局")
                self.resetStatusLabel.stringValue = ""
            }
            return
        }
        isConfirmingLayoutReset = false
        resetLayoutButton.title = L10n.t("重置桌面布局")

        var latest = ConfigStore.load()
        latest.folders = []
        latest.pageOrders = []
        latest.itemOrder = []
        ConfigStore.save(latest)
        config.folders = []
        config.pageOrders = []
        config.itemOrder = []
        NotificationCenter.default.post(name: ConfigStore.didChange, object: nil)
        showResetStatus(L10n.t("桌面布局已重置 ✓"), color: .systemGreen)
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
            resetButton.title = L10n.t("确认恢复？")
            resetStatusLabel.stringValue = L10n.t("仅重置设置项，保留文件夹与桌面布局")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isConfirmingReset else { return }
                self.isConfirmingReset = false
                self.resetButton.title = L10n.t("恢复默认设置")
                self.resetStatusLabel.stringValue = ""
            }
            return
        }
        isConfirmingReset = false
        resetButton.title = L10n.t("恢复默认设置")

        let defaults = AppConfig.defaults
        config.theme = defaults.theme
        config.backgroundImagePath = defaults.backgroundImagePath
        config.bgOpacity = defaults.bgOpacity
        config.bgBlur = defaults.bgBlur
        config.darkBgPreset = defaults.darkBgPreset
        config.lightBgPreset = defaults.lightBgPreset
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
        resetStatusLabel.stringValue = L10n.t("已恢复默认设置 ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.resetStatusLabel.stringValue = ""
        }
    }

    // MARK: - 关于

    @objc private func copyRepositoryURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AppVersion.repositoryURL, forType: .string)
        copyRepoFeedback.stringValue = L10n.t("已复制 ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyRepoFeedback.stringValue = ""
        }
    }

    @objc private func closeClicked() {
        close()
    }

    // MARK: - 保存

    private func persist() {
        // 读取磁盘最新值（保留主窗口负责的字段），再覆盖设置面板负责的全部字段。
        // 字段清单集中在 AppConfig.applySettings，避免此处手写漏字段。
        var latest = ConfigStore.load()
        latest.applySettings(from: config)
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

    /// 切换语言时就地更新标题（attributedTitle 的缩进/配色由 updateStyle 重建）
    func applyLocalizedTitle(_ text: String) {
        title = text
        updateStyle()
    }

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
