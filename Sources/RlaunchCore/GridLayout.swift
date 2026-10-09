import Foundation

/// 网格布局参数
public struct GridLayoutConfig: Equatable {
    public var columns: Int
    public var rows: Int
    public var columnSpacing: CGFloat
    public var rowSpacing: CGFloat
    public var iconSize: CGFloat

    public init(columns: Int = 7,
                rows: Int = 5,
                columnSpacing: CGFloat = 24,
                rowSpacing: CGFloat = 24,
                iconSize: CGFloat = 64) {
        self.columns = columns
        self.rows = rows
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.iconSize = iconSize
    }

    public static let defaults = GridLayoutConfig()

    public var labelHeight: CGFloat { min(40, max(26, iconSize * 0.28)) }
    public var cellWidth: CGFloat { iconSize + 20 }
    public var cellHeight: CGFloat { iconSize + labelHeight + 16 }

    /// 整页网格占位（与 `GridPageView.layout` 一致），用于窗口缩放时校验是否超出可视区
    public var gridPixelWidth: CGFloat {
        let cols = CGFloat(max(columns, 1))
        return cols * cellWidth + max(0, cols - 1) * columnSpacing
    }

    public var gridPixelHeight: CGFloat {
        let rowCount = CGFloat(max(rows, 1))
        return rowCount * cellHeight + max(0, rowCount - 1) * rowSpacing
    }
}

/// 网格**实际可用容量**（列 × 行）。
///
/// 窗口可以被手动缩到很小；此时若仍按用户配置的 rows/columns 分页，
/// 「分页认为放得下、布局却放不下」的条目会被裁掉或压到顶栏下。
/// 容量随可视区收缩后，分页与布局始终使用同一份规格。
public struct GridCapacity: Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }
}

/// 网格尺寸推算（纯计算，便于自测覆盖）。
public enum GridMetrics {

    /// 允许的最小图标 / 间距：低于这套值就不再压缩，改为减少每页行列数
    public static let minIconSize: CGFloat = 34
    public static let minColumnSpacing: CGFloat = 8
    public static let minRowSpacing: CGFloat = 6

    public static var minCellWidth: CGFloat { minIconSize + 20 }
    public static var minCellHeight: CGFloat { minIconSize + 26 + 16 }

    /// 按可视区推算实际可用容量（不超过用户配置）
    public static func capacity(viewport: CGSize, configured: GridCapacity) -> GridCapacity {
        guard viewport.width > 1, viewport.height > 1 else { return configured }
        let columnsFit = Int(((viewport.width + minColumnSpacing) / (minCellWidth + minColumnSpacing)).rounded(.down))
        let rowsFit = Int(((viewport.height + minRowSpacing) / (minCellHeight + minRowSpacing)).rounded(.down))
        return GridCapacity(
            columns: min(configured.columns, columnsFit),
            rows: min(configured.rows, rowsFit)
        )
    }

    /// 窗口化网格：容量范围内尽量用配置的图标尺寸，放不下时先收紧间距、再收图标。
    /// 返回结果保证 `gridPixelWidth <= viewport.width` 且 `gridPixelHeight <= viewport.height`。
    public static func windowedConfig(viewport: CGSize,
                                      capacity: GridCapacity,
                                      preferredIconSize: CGFloat,
                                      columnSpacing: CGFloat,
                                      rowSpacing: CGFloat) -> GridLayoutConfig {
        fitted(viewport: viewport,
               capacity: capacity,
               preferredIconSize: preferredIconSize,
               columnSpacing: columnSpacing,
               rowSpacing: rowSpacing,
               fill: CGSize(width: 1, height: 1),
               growsToFill: false,
               maxIconSize: 160)
    }

    /// 全屏网格：在**真实网格可视区**（已扣掉顶栏、刘海安全区与底栏）内把图标放大铺满。
    ///
    /// 这里必须用可视区而不是 `NSScreen.frame`：笔记本上顶栏 56pt + 刘海安全区 32pt +
    /// 底栏 68pt 加起来有 156pt，用屏幕高度算会把网格算高，多出来的部分正好把首行图标
    /// 顶到可视区之外——表现就是「顶栏盖住了应用」。
    public static func fullscreenConfig(viewport: CGSize,
                                        capacity: GridCapacity,
                                        preferredIconSize: CGFloat,
                                        columnSpacing: CGFloat,
                                        rowSpacing: CGFloat,
                                        spacingScale: CGFloat) -> GridLayoutConfig {
        fitted(viewport: viewport,
               capacity: capacity,
               preferredIconSize: preferredIconSize,
               columnSpacing: max(14, columnSpacing * spacingScale),
               rowSpacing: max(14, rowSpacing * spacingScale),
               fill: CGSize(width: 0.94, height: 0.92),
               growsToFill: true,
               maxIconSize: 160)
    }

    /// 统一推算：**永远以真实可视区为准**，先收紧间距（最多收到配置值的 60%），再收图标，
    /// 最后按真实像素尺寸兜底校验，确保整页一定落在可视区内。
    private static func fitted(viewport: CGSize,
                               capacity: GridCapacity,
                               preferredIconSize: CGFloat,
                               columnSpacing: CGFloat,
                               rowSpacing: CGFloat,
                               fill: CGSize,
                               growsToFill: Bool,
                               maxIconSize: CGFloat) -> GridLayoutConfig {
        let columns = max(capacity.columns, 1)
        let rows = max(capacity.rows, 1)
        let cols = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let prefIcon = max(preferredIconSize, minIconSize)

        guard viewport.width > 1, viewport.height > 1 else {
            return GridLayoutConfig(
                columns: columns, rows: rows,
                columnSpacing: max(minColumnSpacing, columnSpacing),
                rowSpacing: max(minRowSpacing, rowSpacing),
                iconSize: prefIcon)
        }

        let usableW = viewport.width * fill.width
        let usableH = viewport.height * fill.height

        // 标签高度随图标变化，迭代几轮即收敛
        func fittedIcon(_ colSpacing: CGFloat, _ rowSpacing: CGFloat) -> CGFloat {
            var icon = prefIcon
            for _ in 0..<4 {
                let labelH = min(40, max(26, icon * 0.28))
                let iconForW = (usableW - (cols - 1) * colSpacing) / cols - 20
                let iconForH = (usableH - (rowCount - 1) * rowSpacing) / rowCount - labelH - 16
                icon = min(iconForW, iconForH)
            }
            return icon
        }

        var colSpacing = max(minColumnSpacing, columnSpacing)
        var rowSpacing = max(minRowSpacing, rowSpacing)
        var fit = fittedIcon(colSpacing, rowSpacing)

        // 先收紧间距（下限：配置值的 60% 与最小间距取大），尽量保住用户配置的图标尺寸
        if fit < prefIcon {
            for step in stride(from: 0.9, through: 0.61, by: -0.1) {
                let candidateCol = max(minColumnSpacing, columnSpacing * step)
                let candidateRow = max(minRowSpacing, rowSpacing * step)
                colSpacing = candidateCol
                rowSpacing = candidateRow
                fit = fittedIcon(candidateCol, candidateRow)
                if fit >= prefIcon { break }
                if candidateCol <= minColumnSpacing && candidateRow <= minRowSpacing { break }
            }
        }

        var icon = growsToFill
            ? min(maxIconSize, max(minIconSize, fit))
            : min(prefIcon, max(minIconSize, fit))

        var result = GridLayoutConfig(columns: columns, rows: rows,
                                      columnSpacing: colSpacing, rowSpacing: rowSpacing, iconSize: icon)
        // 兜底：先收到最小间距、再收图标；容量本身按最小尺寸推算过，因此不会无解
        while result.gridPixelHeight > viewport.height || result.gridPixelWidth > viewport.width {
            if colSpacing > minColumnSpacing || rowSpacing > minRowSpacing {
                colSpacing = max(minColumnSpacing, colSpacing - 2)
                rowSpacing = max(minRowSpacing, rowSpacing - 2)
            } else if icon > minIconSize {
                icon -= 1
            } else {
                break
            }
            result = GridLayoutConfig(columns: columns, rows: rows,
                                      columnSpacing: colSpacing, rowSpacing: rowSpacing, iconSize: icon)
        }
        return result
    }

}
