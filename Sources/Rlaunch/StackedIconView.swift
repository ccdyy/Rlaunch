import Cocoa
import RlaunchCore

/// 叠放图标视图：用于展示多个应用图标的错位层叠视觉效果，并在角标中展示剩余数量。
final class StackedIconView: NSView {

    private var imageViews: [NSImageView] = []
    private let badgeCard = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        badgeCard.wantsLayer = true
        badgeCard.layer?.cornerRadius = 7
        badgeCard.layer?.masksToBounds = true
        badgeCard.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        badgeCard.layer?.borderWidth = 1
        badgeCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        badgeCard.isHidden = true

        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeCard.addSubview(badgeLabel)

        addSubview(badgeCard)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 配置叠放图标
    /// - Parameters:
    ///   - paths: 要展示在层叠中的应用路径列表（前 1~3 个）
    ///   - remainingCount: 包含当前及后续未展示的应用总数量
    func setApps(paths: [String], remainingCount: Int) {
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews.removeAll()

        let showPaths = Array(paths.prefix(3))
        if showPaths.isEmpty {
            badgeCard.isHidden = true
            return
        }

        // 倒序添加子视图，使第一个排在最上面
        for path in showPaths.reversed() {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.image = IconCache.shared.icon(for: path)
            iv.wantsLayer = true
            iv.layer?.shadowColor = NSColor.black.cgColor
            iv.layer?.shadowOpacity = 0.32
            iv.layer?.shadowOffset = CGSize(width: 0, height: -2)
            iv.layer?.shadowRadius = 4
            imageViews.append(iv)
            addSubview(iv, positioned: .below, relativeTo: badgeCard)
        }
        imageViews.reverse() // 恢复正常顺序：index 0 为顶层

        if remainingCount > 1 {
            badgeCard.isHidden = false
            badgeLabel.stringValue = "+\(remainingCount)"
        } else {
            badgeCard.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        let count = imageViews.count
        if count == 0 { return }

        if count == 1 {
            imageViews[0].frame = b
        } else if count == 2 {
            // 双图标层叠：充分利用空间
            let s = b.width * 0.86
            imageViews[1].frame = NSRect(x: b.width * 0.14, y: b.height * 0.14, width: s, height: s)
            imageViews[0].frame = NSRect(x: 0, y: 0, width: s, height: s)
        } else {
            // 三图标错位阶梯层叠：主图大而饱满
            let s = b.width * 0.84
            imageViews[2].frame = NSRect(x: b.width * 0.16, y: b.height * 0.16, width: s, height: s)
            imageViews[1].frame = NSRect(x: b.width * 0.08, y: b.height * 0.08, width: s, height: s)
            imageViews[0].frame = NSRect(x: 0, y: 0, width: s, height: s)
        }

        let badgeW: CGFloat = max(24, badgeLabel.intrinsicContentSize.width + 8)
        let badgeH: CGFloat = 15
        badgeCard.frame = NSRect(x: b.width - badgeW, y: 0, width: badgeW, height: badgeH)
        badgeLabel.frame = NSRect(x: 0, y: (badgeH - 12) / 2, width: badgeW, height: 12)
    }
}
