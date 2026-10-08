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

    /// 窗口化网格：容量范围内尽量用配置的图标尺寸，放不下时按比例收紧间距与图标。
    /// 返回结果保证 `gridPixelWidth <= viewport.width` 且 `gridPixelHeight <= viewport.height`。
    public static func windowedConfig(viewport: CGSize,
                                      capacity: GridCapacity,
                                      preferredIconSize: CGFloat,
                                      columnSpacing: CGFloat,
                                      rowSpacing: CGFloat) -> GridLayoutConfig {
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
                iconSize: prefIcon
            )
        }

        let W = viewport.width
        let H = viewport.height

        func fittedIcon(_ colSpacing: CGFloat, _ rowSpacing: CGFloat) -> CGFloat {
            // 用配置图标的标签高度估算（偏保守），随后再由像素尺寸校验兜底
            let labelH = min(40, max(26, prefIcon * 0.28))
            let iconForW = (W - (cols - 1) * colSpacing) / cols - 20
            let iconForH = (H - (rowCount - 1) * rowSpacing) / rowCount - labelH - 16
            return min(iconForW, iconForH)
        }

        var colSpacing = max(minColumnSpacing, columnSpacing)
        var rowSpacing = max(minRowSpacing, rowSpacing)
        var fit = fittedIcon(colSpacing, rowSpacing)
        if fit < minIconSize {
            // 逐步收紧间距，直到能放下最小图标为止
            for step in stride(from: 0.9, through: 0.1, by: -0.1) {
                let candidateCol = max(minColumnSpacing, columnSpacing * step)
                let candidateRow = max(minRowSpacing, rowSpacing * step)
                colSpacing = candidateCol
                rowSpacing = candidateRow
                fit = fittedIcon(candidateCol, candidateRow)
                if fit >= minIconSize { break }
                if candidateCol <= minColumnSpacing && candidateRow <= minRowSpacing { break }
            }
        }

        var icon = min(prefIcon, max(minIconSize, fit))
        var result = GridLayoutConfig(
            columns: columns, rows: rows,
            columnSpacing: colSpacing, rowSpacing: rowSpacing, iconSize: icon
        )
        // 兜底：标签高度随图标变化，用真实像素尺寸再校验一次
        while icon > minIconSize,
              result.gridPixelHeight > H || result.gridPixelWidth > W {
            icon -= 1
            result = GridLayoutConfig(
                columns: columns, rows: rows,
                columnSpacing: colSpacing, rowSpacing: rowSpacing, iconSize: icon
            )
        }
        return result
    }

    /// 全屏网格：用屏幕尺寸把图标放大铺满
    public static func fullscreenConfig(screenSize: CGSize,
                                        configured: GridCapacity,
                                        preferredIconSize: CGFloat,
                                        columnSpacing: CGFloat,
                                        rowSpacing: CGFloat,
                                        spacingScale: CGFloat) -> GridLayoutConfig {
        let columns = max(configured.columns, 1)
        let rows = max(configured.rows, 1)
        let cols = CGFloat(columns)
        let rowCount = CGFloat(rows)
        let prefIcon = max(preferredIconSize, minIconSize)

        let scaledCol = max(14, columnSpacing * spacingScale)
        let scaledRow = max(14, rowSpacing * spacingScale)
        let labelH: CGFloat = 36
        let iconForW = (screenSize.width * 0.88 - (cols - 1) * scaledCol) / cols - 16
        let iconForH = (screenSize.height * 0.84 - (rowCount - 1) * scaledRow) / rowCount - labelH - 8
        let icon = min(160, max(prefIcon, min(iconForW, iconForH)))
        return GridLayoutConfig(
            columns: columns, rows: rows,
            columnSpacing: scaledCol, rowSpacing: scaledRow, iconSize: icon
        )
    }
}
