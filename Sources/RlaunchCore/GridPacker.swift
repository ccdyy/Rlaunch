import Foundation

/// 网格落位（行、列，均从 0 开始，原点在左上）
public struct GridPosition: Equatable, Hashable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// 网格装箱：应用恒占 1×1，文件夹可占多格。
///
/// 统一采用「从上到下、从左到右」的首次适配算法，**布局与分页共用同一份实现**，
/// 避免出现「分页以为放得下、布局却放不下」导致条目被静默隐藏的问题。
public enum GridPacker {

    /// 网格总格数
    public static func capacity(columns: Int, rows: Int) -> Int {
        max(columns, 1) * max(rows, 1)
    }

    /// 依次计算每个条目的落位；放不下的条目为 `nil`（调用方应据此换页）。
    public static func placements(for items: [GridItem], columns: Int, rows: Int) -> [GridPosition?] {
        let cols = max(columns, 1)
        let rws = max(rows, 1)
        var occupied = [Bool](repeating: false, count: cols * rws)
        var result: [GridPosition?] = []
        result.reserveCapacity(items.count)

        for item in items {
            let spanC = min(max(item.spanColumns, 1), cols)
            let spanR = min(max(item.spanRows, 1), rws)
            var placed: GridPosition?

            outer: for r in 0...(rws - spanR) {
                for c in 0...(cols - spanC) {
                    var fits = true
                    inner: for dr in 0..<spanR {
                        for dc in 0..<spanC {
                            if occupied[(r + dr) * cols + (c + dc)] {
                                fits = false
                                break inner
                            }
                        }
                    }
                    if fits {
                        placed = GridPosition(row: r, column: c)
                        for dr in 0..<spanR {
                            for dc in 0..<spanC {
                                occupied[(r + dr) * cols + (c + dc)] = true
                            }
                        }
                        break outer
                    }
                }
            }
            result.append(placed)
        }
        return result
    }

    /// 从头部开始，最多能完整放下的条目个数（至少 1，保证分页不会死循环）
    public static func fitCount(for items: [GridItem], columns: Int, rows: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        let placed = placements(for: items, columns: columns, rows: rows)
        var count = 0
        for position in placed {
            if position == nil { break }
            count += 1
        }
        return max(count, 1)
    }

    /// 键盘导航：在指定方向上寻找最近的邻居条目下标。
    ///
    /// 主轴距离优先、另一轴的偏移作为次要惩罚，保证 `↑/↓` 尽量落在同一列、`←/→` 尽量落在同一行；
    /// 该方向上没有更远的条目时返回 `nil`（由调用方决定翻页或保持不动）。
    public static func neighborIndex(from index: Int,
                                     dx: Int,
                                     dy: Int,
                                     placements: [GridPosition?]) -> Int? {
        guard index >= 0, index < placements.count, let origin = placements[index] else { return nil }
        var best: (index: Int, score: Int)?
        for (i, position) in placements.enumerated() {
            guard let position, i != index else { continue }
            let dCol = position.column - origin.column
            let dRow = position.row - origin.row
            if dx > 0 && dCol <= 0 { continue }
            if dx < 0 && dCol >= 0 { continue }
            if dy > 0 && dRow <= 0 { continue }
            if dy < 0 && dRow >= 0 { continue }
            let primary = dx != 0 ? abs(dCol) : abs(dRow)
            let secondary = dx != 0 ? abs(dRow) : abs(dCol)
            let score = primary * 10 + secondary
            if best == nil || score < best!.score { best = (i, score) }
        }
        return best?.index
    }
}
