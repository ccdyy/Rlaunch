import Cocoa
import RlaunchCore

/// 窗口内联输入 / 确认浮层。
///
/// 为什么不用 `NSAlert.runModal()`：启动台在伪全屏时窗口层级为 `mainMenuWindow + 1`，
/// 远高于模态面板的 `.modalPanel`，弹框会被压在启动台窗口后面完全无法操作；
/// 同时 `runModal()` 会阻塞主线程，界面看起来像卡死。
/// 这里改成窗口内的浮层，天然位于最上层，且不阻塞主线程。
final class PromptOverlayView: NSView {

    var onConfirm: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let dimmingMask = NSView()
    private let cardView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let textField = NSTextField()
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()
    private var escMonitor: Any?

    private let showsTextField: Bool
    private let confirmTitle: String
    private let placeholder: String?

    // MARK: - 尺寸（布局与高度计算共用同一组常量，避免按钮被卡片裁掉）

    private enum Metric {
        static let pad: CGFloat = 20
        static let titleH: CGFloat = 22
        static let messageH: CGFloat = 34
        static let fieldH: CGFloat = 26
        static let btnH: CGFloat = 26
        static let btnW: CGFloat = 104
        static let gapTitleMessage: CGFloat = 8
        static let gapMessageField: CGFloat = 12
        static let gapToButtons: CGFloat = 20
        static let cardWidth: CGFloat = 400
    }

    /// 卡片高度由内容推导
    private var contentHeight: CGFloat {
        var h = Metric.pad + Metric.titleH
        if !messageLabel.isHidden { h += Metric.gapTitleMessage + Metric.messageH }
        if showsTextField { h += Metric.gapMessageField + Metric.fieldH }
        h += Metric.gapToButtons + Metric.btnH + Metric.pad
        return h
    }

    init(title: String,
         message: String?,
         placeholder: String? = nil,
         defaultValue: String = "",
         confirmTitle: String,
         showsTextField: Bool) {
        self.showsTextField = showsTextField
        self.confirmTitle = confirmTitle
        self.placeholder = placeholder
        super.init(frame: .zero)
        wantsLayer = true

        dimmingMask.wantsLayer = true
        addSubview(dimmingMask)

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 16
        cardView.layer?.masksToBounds = true
        cardView.layer?.borderWidth = 1
        addSubview(cardView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        cardView.addSubview(titleLabel)

        messageLabel.stringValue = message ?? ""
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = (message ?? "").isEmpty
        cardView.addSubview(messageLabel)

        if showsTextField {
            textField.stringValue = defaultValue
            textField.placeholderString = placeholder
            textField.font = .systemFont(ofSize: 13)
            textField.isBezeled = true
            textField.bezelStyle = .roundedBezel
            textField.focusRingType = .none
            textField.target = self
            textField.action = #selector(confirmClicked)
            cardView.addSubview(textField)
        }

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cardView.addSubview(cancelButton)

        confirmButton.title = confirmTitle
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        confirmButton.keyEquivalent = "\r" // Enter
        cardView.addSubview(confirmButton)

        updateAppearance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    @objc private func themeDidChange() { updateAppearance() }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        dimmingMask.layer?.backgroundColor = NSColor.black.withAlphaComponent(isDark ? 0.32 : 0.18).cgColor
        cardView.layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.24, alpha: 0.99)
            : NSColor(calibratedWhite: 0.99, alpha: 0.99)).cgColor
        cardView.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.10)).cgColor
    }

    // MARK: - 展示 / 收起

    func present(in parent: NSView) {
        frame = parent.bounds
        autoresizingMask = [.width, .height]
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 1
        }
        if showsTextField {
            window?.makeFirstResponder(textField)
            if let editor = textField.currentEditor() {
                editor.selectedRange = NSRange(location: textField.stringValue.count, length: 0)
            }
        } else {
            window?.makeFirstResponder(confirmButton)
        }
        // 兜底处理 Esc（按钮 keyEquivalent 在部分场景下不生效）
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.superview != nil else { return event }
            self.cancelClicked()
            return nil
        }
    }

    func dismiss(then completion: (() -> Void)? = nil) {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
            completion?()
        }
    }

    @objc private func confirmClicked() {
        finish { [weak self] in
            guard let self else { return }
            self.onConfirm?(self.showsTextField ? self.textField.stringValue : "")
        }
    }

    @objc private func cancelClicked() {
        finish { [weak self] in
            self?.onCancel?()
        }
    }

    /// 收敛出口：回车（输入框 action / 按钮 keyEquivalent）与 Esc（按钮 / 本地监听）可能重复触发，
    /// 这里保证确认或取消只生效一次，避免重复创建文件夹等副作用。
    private var isFinishing = false

    private func finish(then completion: @escaping () -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        dismiss(then: completion)
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        dimmingMask.frame = b

        let cardW = min(Metric.cardWidth, b.width - 40)
        let cardH = contentHeight
        let cardRect = NSRect(x: (b.width - cardW) / 2,
                              y: (b.height - cardH) / 2,
                              width: cardW,
                              height: cardH)
        cardView.frame = cardRect

        let pad = Metric.pad
        var cursor = cardH - pad
        cursor -= Metric.titleH
        titleLabel.frame = NSRect(x: pad, y: cursor, width: cardW - pad * 2, height: Metric.titleH)

        if !messageLabel.isHidden {
            cursor -= Metric.gapTitleMessage + Metric.messageH
            messageLabel.frame = NSRect(x: pad, y: cursor, width: cardW - pad * 2, height: Metric.messageH)
        }

        if showsTextField {
            cursor -= Metric.gapMessageField + Metric.fieldH
            textField.frame = NSRect(x: pad, y: cursor, width: cardW - pad * 2, height: Metric.fieldH)
        }

        cursor -= Metric.gapToButtons + Metric.btnH
        confirmButton.frame = NSRect(x: cardW - pad - Metric.btnW, y: cursor,
                                     width: Metric.btnW, height: Metric.btnH)
        cancelButton.frame = NSRect(x: cardW - pad - Metric.btnW * 2 - 10, y: cursor,
                                    width: Metric.btnW, height: Metric.btnH)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !cardView.frame.contains(p) { cancelClicked() }
    }
}
