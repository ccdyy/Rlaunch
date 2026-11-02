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

// MARK: - 设置 → 实际显示

/// 用户在「设置 → 网格」里配置的全部参数（与 `AppConfig` 解耦，便于纯逻辑测试）。
public struct GridSettings: Equatable {
    public var columns: Int
    public var rows: Int
    /// 图标边长（pt）。窗口化时就是图标的目标尺寸，全屏时是放大前的基准。
    public var iconSize: CGFloat
    public var columnSpacing: CGFloat
    public var rowSpacing: CGFloat
    /// 全屏放大倍数（≥ 1）：全屏时图标与间距相对窗口化放大的倍数；
    /// 当前屏幕放不下时自动降低（最低 1×），但**不会**为了放大而减少每页行列数。
    public var fullscreenScale: CGFloat

    public init(columns: Int = 7,
                rows: Int = 5,
                iconSize: CGFloat = 64,
                columnSpacing: CGFloat = 24,
                rowSpacing: CGFloat = 24,
                fullscreenScale: CGFloat = 1.25) {
        self.columns = columns
        self.rows = rows
        self.iconSize = iconSize
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.fullscreenScale = fullscreenScale
    }
}

public extension AppConfig {
    /// 网格相关设置的快照
    var gridSettings: GridSettings {
        GridSettings(columns: columns,
                     rows: rows,
                     iconSize: CGFloat(iconSize),
                     columnSpacing: CGFloat(columnSpacing),
                     rowSpacing: CGFloat(rowSpacing),
                     fullscreenScale: CGFloat(fullscreenScale))
    }
}

public enum GridMode: Equatable {
    case windowed
    case fullscreen
}

/// 实际显示与设置之间的差异（如实告诉用户「为什么和设置不一样」）
public enum GridDeviation: Equatable {
    case columnsReduced(configured: Int, actual: Int)
    case rowsReduced(configured: Int, actual: Int)
    /// 图标比期望值小：`percent` 为实际占期望的百分比（< 100）
    case iconShrunk(percent: Int)
    case spacingTightened
    /// 全屏缩放放不下：设置了 `requested` 倍，当前屏幕最多 `applied` 倍
    case scaleLimited(requested: Double, applied: Double)
}

/// 一次推算的结果：实际生效的网格 + 它与设置的差异。
public struct GridResolution: Equatable {
    public var layout: GridLayoutConfig
    public var mode: GridMode
    /// 推算所用的设置（已规整）
    public var settings: GridSettings
    /// 全屏实际生效的放大倍数；窗口化恒为 1
    public var appliedScale: CGFloat

    public var capacity: GridCapacity {
        GridCapacity(columns: layout.columns, rows: layout.rows)
    }

    /// 期望的图标尺寸（已计入实际生效的缩放）
    public var expectedIconSize: CGFloat { settings.iconSize * appliedScale }

    /// 实际图标 / 期望图标（1 表示完全按设置显示）
    public var iconRatio: CGFloat {
        expectedIconSize > 0 ? layout.iconSize / expectedIconSize : 1
    }

    public var deviations: [GridDeviation] {
        var result: [GridDeviation] = []
        if mode == .fullscreen, settings.fullscreenScale - appliedScale > 0.02 {
            result.append(.scaleLimited(requested: Double(settings.fullscreenScale),
                                        applied: Double(appliedScale)))
        }
        if layout.columns < settings.columns {
            result.append(.columnsReduced(configured: settings.columns, actual: layout.columns))
        }
        if layout.rows < settings.rows {
            result.append(.rowsReduced(configured: settings.rows, actual: layout.rows))
        }
        if iconRatio < 0.995 {
            result.append(.iconShrunk(percent: Int((iconRatio * 100).rounded())))
        }
        let expectedColumnSpacing = settings.columnSpacing * appliedScale
        let expectedRowSpacing = settings.rowSpacing * appliedScale
        if layout.columnSpacing < expectedColumnSpacing - 0.5 || layout.rowSpacing < expectedRowSpacing - 0.5 {
            result.append(.spacingTightened)
        }
        return result
    }

    /// 实际显示是否与设置完全一致
    public var matchesSettings: Bool { deviations.isEmpty }
}

// MARK: - 尺寸推算

/// 网格尺寸推算（纯计算，便于自测覆盖）。
///
/// 设计原则：**设置里写多少就显示多少**，放不下时才按固定顺序降级，且降级幅度有明确上限：
///
/// 1. 间距最多收紧到设置值的 60%（且不低于硬下限）；
/// 2. 图标最多缩小到设置值的 85%；
/// 3. 仍放不下就减少每页行 / 列数（行列是「最多」，不是「必须」）；
/// 4. 只有连「最小网格」（3 列 × 2 行）都放不下时，才把图标继续缩到硬下限。
///
/// 全屏的「全屏缩放」是一个尽力而为的放大倍数：在保持配置行列数的前提下尽量放大，
/// 屏幕放不下就自动降低（最低 1×），绝不为了放大而减少每页的应用数。
///
/// 这样同一份设置在不同尺寸的窗口 / 屏幕上，图标大小的差距只取决于「放得下多少」，
/// 而不是被「铺满」之类的隐式规则放大几倍。
public enum GridMetrics {

    /// 硬下限：低于这套值就不再压缩，改为减少每页行列数
    public static let minIconSize: CGFloat = 34
    public static let minColumnSpacing: CGFloat = 8
    public static let minRowSpacing: CGFloat = 6

    /// 间距最多收紧到设置值的这一比例
    public static let spacingFloorRatio: CGFloat = 0.6
    /// 图标最多缩小到期望值的这一比例（再小就改为减少行列）
    public static let iconFloorRatio: CGFloat = 0.85
    /// 为了保住图标尺寸而减少行列时，至少保留的网格规格
    public static let minHonoredColumns = 3
    public static let minHonoredRows = 2

    /// 全屏时网格占可视区的比例（四周留一点呼吸空间）
    public static let fullscreenFill = CGSize(width: 0.94, height: 0.92)

    public static var minCellWidth: CGFloat { minIconSize + 20 }
    public static var minCellHeight: CGFloat { minIconSize + 26 + 16 }

    /// 统一入口：按可视区把「设置」推算成「实际网格」。
    /// 返回结果保证 `gridPixelWidth <= viewport.width` 且 `gridPixelHeight <= viewport.height`
    /// （除非连单个最小单元格都放不下）。
    public static func resolve(settings raw: GridSettings, viewport: CGSize, mode: GridMode) -> GridResolution {
        let settings = GridSettings(
            columns: max(raw.columns, 1),
            rows: max(raw.rows, 1),
            iconSize: max(raw.iconSize, minIconSize),
            columnSpacing: max(raw.columnSpacing, 0),
            rowSpacing: max(raw.rowSpacing, 0),
            fullscreenScale: max(raw.fullscreenScale, 1)
        )

        // 窗口尚未布局：按设置原样返回
        guard viewport.width > 1, viewport.height > 1 else {
            return GridResolution(
                layout: GridLayoutConfig(columns: settings.columns, rows: settings.rows,
                                         columnSpacing: settings.columnSpacing,
                                         rowSpacing: settings.rowSpacing,
                                         iconSize: settings.iconSize),
                mode: mode, settings: settings, appliedScale: 1)
        }

        let fill = mode == .fullscreen ? fullscreenFill : CGSize(width: 1, height: 1)
        let usable = CGSize(width: viewport.width * fill.width, height: viewport.height * fill.height)

        if mode == .fullscreen, let zoomed = zoomedLayout(settings: settings, in: usable) {
            return GridResolution(layout: zoomed.layout, mode: mode, settings: settings, appliedScale: zoomed.scale)
        }

        let layout = squeezedLayout(columns: settings.columns, rows: settings.rows,
                                    icon: settings.iconSize,
                                    columnSpacing: settings.columnSpacing, rowSpacing: settings.rowSpacing,
                                    in: usable)
        return GridResolution(layout: layout, mode: mode, settings: settings, appliedScale: 1)
    }

    // MARK: 全屏：在保持行列数的前提下尽量放大

    /// 配置的整个网格在放大 `scale` 倍后（间距可收紧到下限）能否放进 `size`
    private static func fits(settings: GridSettings, scale: CGFloat, in size: CGSize) -> Bool {
        let columnSpacing = settings.columnSpacing * scale
        let rowSpacing = settings.rowSpacing * scale
        let (columnFloor, rowFloor) = spacingFloors(columnSpacing, rowSpacing)
        return fits(columns: settings.columns, rows: settings.rows, icon: settings.iconSize * scale,
                    columnSpacing: columnFloor, rowSpacing: rowFloor, in: size)
    }

    /// 全屏放大：返回保持配置行列数时的最大倍数（∈ [1, 请求倍数]）；连 1× 都放不下返回 nil
    private static func zoomedLayout(settings: GridSettings, in usable: CGSize) -> (layout: GridLayoutConfig, scale: CGFloat)? {
        guard fits(settings: settings, scale: 1, in: usable) else { return nil }

        var scale = settings.fullscreenScale
        if !fits(settings: settings, scale: scale, in: usable) {
            var low: CGFloat = 1
            var high = scale
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if fits(settings: settings, scale: mid, in: usable) { low = mid } else { high = mid }
            }
            scale = low
        }

        let icon = settings.iconSize * scale
        let probe = GridLayoutConfig(iconSize: icon)
        let columnTarget = settings.columnSpacing * scale
        let rowTarget = settings.rowSpacing * scale
        let (columnFloor, rowFloor) = spacingFloors(columnTarget, rowTarget)
        let layout = GridLayoutConfig(
            columns: settings.columns,
            rows: settings.rows,
            columnSpacing: relaxedSpacing(target: columnTarget, count: settings.columns,
                                          cell: probe.cellWidth, extent: usable.width, floor: columnFloor),
            rowSpacing: relaxedSpacing(target: rowTarget, count: settings.rows,
                                       cell: probe.cellHeight, extent: usable.height, floor: rowFloor),
            iconSize: icon)
        return (layout, scale)
    }

    // MARK: 放不下时的降级

    /// 间距收紧后的下限：设置值的 60%（不低于硬下限）；设置值本身已低于硬下限时不再压缩
    private static func spacingFloors(_ columnSpacing: CGFloat, _ rowSpacing: CGFloat) -> (CGFloat, CGFloat) {
        (min(columnSpacing, max(minColumnSpacing, columnSpacing * spacingFloorRatio)),
         min(rowSpacing, max(minRowSpacing, rowSpacing * spacingFloorRatio)))
    }

    private static func fits(columns: Int, rows: Int, icon: CGFloat,
                             columnSpacing: CGFloat, rowSpacing: CGFloat, in size: CGSize) -> Bool {
        let grid = GridLayoutConfig(columns: columns, rows: rows,
                                    columnSpacing: columnSpacing, rowSpacing: rowSpacing, iconSize: icon)
        return grid.gridPixelWidth <= size.width + 0.001 && grid.gridPixelHeight <= size.height + 0.001
    }

    /// 在不溢出的前提下，把间距尽量恢复到目标值
    private static func relaxedSpacing(target: CGFloat, count: Int, cell: CGFloat,
                                       extent: CGFloat, floor: CGFloat) -> CGFloat {
        guard count > 1 else { return target }
        let available = (extent - CGFloat(count) * cell) / CGFloat(count - 1)
        return min(target, max(available, floor))
    }

    /// 满足 `fits` 的最大图标（`fits` 随图标单调：图标越大越难放下）
    private static func largestIcon(upTo limit: CGFloat, where fits: (CGFloat) -> Bool) -> CGFloat {
        if fits(limit) { return limit }
        var low: CGFloat = 0
        var high = limit
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// 窗口化（以及全屏连 1× 都放不下时）的降级流程，见类型注释。
    private static func squeezedLayout(columns: Int, rows: Int, icon target: CGFloat,
                                       columnSpacing: CGFloat, rowSpacing: CGFloat,
                                       in usable: CGSize) -> GridLayoutConfig {
        let (columnFloor, rowFloor) = spacingFloors(columnSpacing, rowSpacing)

        // 图标最多缩到期望值的 85%：先算出这个下限下每个方向最多能放几个
        let iconFloor = min(target, max(minIconSize, target * iconFloorRatio))
        let probe = GridLayoutConfig(iconSize: iconFloor)
        let columnsFit = Int(((usable.width + columnFloor) / (probe.cellWidth + columnFloor)).rounded(.down))
        let rowsFit = Int(((usable.height + rowFloor) / (probe.cellHeight + rowFloor)).rounded(.down))

        var cols = max(1, min(columns, columnsFit))
        var rowCount = max(1, min(rows, rowsFit))
        // 宁可继续缩小图标，也不把网格减到不像样（至少 3 列 × 2 行，除非配置本身更小）
        cols = max(cols, min(columns, minHonoredColumns))
        rowCount = max(rowCount, min(rows, minHonoredRows))

        // 该行列数下图标最大能到多少（间距取最紧）
        var icon = largestIcon(upTo: target) {
            fits(columns: cols, rows: rowCount, icon: $0,
                 columnSpacing: columnFloor, rowSpacing: rowFloor, in: usable)
        }
        icon = max(icon, minIconSize)

        // 兜底：硬下限下仍放不下（窗口小到极端）→ 继续减少行列，保证整页落在可视区内
        while !fits(columns: cols, rows: rowCount, icon: icon,
                    columnSpacing: columnFloor, rowSpacing: rowFloor, in: usable),
              cols > 1 || rowCount > 1 {
            let grid = GridLayoutConfig(columns: cols, rows: rowCount,
                                        columnSpacing: columnFloor, rowSpacing: rowFloor, iconSize: icon)
            if grid.gridPixelHeight > usable.height, rowCount > 1 {
                rowCount -= 1
            } else if grid.gridPixelWidth > usable.width, cols > 1 {
                cols -= 1
            } else if rowCount > 1 {
                rowCount -= 1
            } else {
                cols -= 1
            }
        }

        // 间距：在不溢出的前提下尽量恢复到设置值
        let final = GridLayoutConfig(iconSize: icon)
        return GridLayoutConfig(
            columns: cols,
            rows: rowCount,
            columnSpacing: relaxedSpacing(target: columnSpacing, count: cols,
                                          cell: final.cellWidth, extent: usable.width, floor: columnFloor),
            rowSpacing: relaxedSpacing(target: rowSpacing, count: rowCount,
                                       cell: final.cellHeight, extent: usable.height, floor: rowFloor),
            iconSize: icon)
    }
}
