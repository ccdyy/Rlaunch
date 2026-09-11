import Cocoa
import RlaunchCore

/// 空状态提示：没有可显示的应用 / 搜索无结果时给出明确指引，避免用户面对一片空白不知所措。
final class EmptyStateView: NSView {

    var onAction: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .tertiaryLabelColor
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        addSubview(detailLabel)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        addSubview(actionButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func actionClicked() { onAction?() }

    /// 展示提示。`showsAction` 为 false 时隐藏操作按钮（例如搜索无结果无需操作）。
    func show(symbol: String,
              title: String,
              detail: String,
              actionTitle: String?,
              in parentView: NSView) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .light))
        if let actionTitle {
            actionButton.title = actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }

        let wasHidden = superview == nil
        if superview == nil {
            frame = parentView.bounds
            autoresizingMask = [.width, .height]
            parentView.addSubview(self, positioned: .above, relativeTo: nil)
        }
        layoutContent()
        needsLayout = true
        if wasHidden {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                self.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard superview != nil else { return }
        removeFromSuperview()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        let iconSize: CGFloat = 52
        let titleH: CGFloat = 22
        let detailH: CGFloat = detailLabel.isHidden ? 0 : 36
        let buttonH: CGFloat = actionButton.isHidden ? 0 : 32
        let spacing: CGFloat = 10

        var total = iconSize + spacing + titleH
        if detailH > 0 { total += spacing + detailH }
        if buttonH > 0 { total += spacing + buttonH }

        var y = (b.height + total) / 2 - iconSize
        iconView.frame = NSRect(x: (b.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)

        y -= spacing + titleH
        titleLabel.frame = NSRect(x: 24, y: y, width: b.width - 48, height: titleH)

        if detailH > 0 {
            y -= spacing + detailH
            detailLabel.frame = NSRect(x: 24, y: y, width: b.width - 48, height: detailH)
        }

        if buttonH > 0 {
            actionButton.sizeToFit()
            let w = max(120, actionButton.frame.width + 24)
            y -= spacing + buttonH
            actionButton.frame = NSRect(x: (b.width - w) / 2, y: y, width: w, height: buttonH)
        }
    }
}
