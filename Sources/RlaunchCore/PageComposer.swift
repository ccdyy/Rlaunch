import Foundation

/// 桌面分页 / 文件夹编排：纯数据逻辑，不依赖 AppKit，便于单元测试。
///
/// 之前这些逻辑直接写在 `MainWindowController` 里，自测只能「照抄一份」验证，无法覆盖真实代码。
/// 抽到 Core 之后，App 与自测使用同一实现。
public enum PageComposer {

    // MARK: - 分页

    /// 按网格**实际容量**把条目切分为多页。
    ///
    /// 关键：容量不能简单用 `columns × rows`（条目数），因为文件夹会占多格；
    /// 用条目数切页会让跨格文件夹挤掉后续条目，导致它们既不在这一页、也不在下一页，被静默隐藏。
    public static func chunk(_ items: [GridItem], columns: Int, rows: Int) -> [[GridItem]] {
        guard !items.isEmpty else { return [[]] }
        var pages: [[GridItem]] = []
        var rest = ArraySlice(items)
        while !rest.isEmpty {
            let count = min(GridPacker.fitCount(for: Array(rest), columns: columns, rows: rows), rest.count)
            pages.append(Array(rest.prefix(count)))
            rest = rest.dropFirst(count)
        }
        return trimTrailingEmpty(pages)
    }

    /// 组装分页。
    /// - Parameters:
    ///   - savedPages: 按 `pageOrders` 顺序解析出的各页条目；空数组表示用户刻意留白的页面
    ///   - unvisited: 未出现在任何页面记录中的条目（新增应用、新建文件夹等）
    ///
    /// 未访问条目先尽量补进最后一页的空位，剩下的再按容量切成新页。
    public static func compose(savedPages: [[GridItem]],
                               unvisited: [GridItem],
                               columns: Int,
                               rows: Int) -> [[GridItem]] {
        var pages = savedPages
        var remaining = unvisited

        if !remaining.isEmpty, let last = pages.last, !last.isEmpty {
            let fit = GridPacker.fitCount(for: last + remaining, columns: columns, rows: rows)
            if fit > last.count {
                let take = fit - last.count
                pages[pages.count - 1] = last + remaining.prefix(take)
                remaining = Array(remaining.dropFirst(take))
            }
        }

        if !remaining.isEmpty {
            pages.append(contentsOf: chunk(remaining, columns: columns, rows: rows))
        }
        return trimTrailingEmpty(pages)
    }

    /// 移除末尾的空页（至少保留一页）；内部刻意留白的空页保持不动
    public static func trimTrailingEmpty(_ pages: [[GridItem]]) -> [[GridItem]] {
        var result = pages
        while result.count > 1 && result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.isEmpty ? [[]] : result
    }

    /// 回收空页（字符串键版本，用于 `pageOrders`）
    public static func compact(_ pages: [[String]]) -> [[String]] {
        guard pages.count > 1 else { return pages.isEmpty ? [[]] : pages }
        let nonEmpty = pages.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? [[]] : nonEmpty
    }

    // MARK: - 增删与移动

    /// 从所有页面中剔除指定标识符的条目
    public static func removing(_ identifiers: Set<String>, from pages: [[GridItem]]) -> [[GridItem]] {
        guard !identifiers.isEmpty else { return pages }
        return pages.map { page in page.filter { !identifiers.contains($0.identifier) } }
    }

    /// 把 `moving` 移动到目标页的 `index` 位置（**严格保持 moving 的先后顺序**），
    /// 并从其余页面移除；目标页溢出部分按容量顺延到后续页面。
    public static func move(_ moving: [GridItem],
                            toPage page: Int,
                            at index: Int,
                            in pages: [[GridItem]],
                            columns: Int,
                            rows: Int) -> [[GridItem]] {
        guard !moving.isEmpty else { return pages }
        var result = pages.isEmpty ? [[]] : pages
        let target = min(max(page, 0), max(result.count - 1, 0))
        while result.count <= target { result.append([]) }

        // 先取目标页的参考物，才能在移除后精确还原插入位置
        let reference: GridItem? = (index >= 0 && index < result[target].count) ? result[target][index] : nil

        let movingIds = Set(moving.map { $0.identifier })
        result = removing(movingIds, from: result)

        let insertIndex: Int
        if let reference,
           let found = result[target].firstIndex(where: { $0.identifier == reference.identifier }) {
            insertIndex = found
        } else {
            insertIndex = min(max(index, 0), result[target].count)
        }
        result[target].insert(contentsOf: moving, at: insertIndex)

        return reflow(result, from: target, columns: columns, rows: rows)
    }

    /// 把指定页的条目追加到该页末尾（放不下则顺延）
    public static func appending(_ items: [GridItem],
                                 toPage page: Int,
                                 in pages: [[GridItem]],
                                 columns: Int,
                                 rows: Int) -> [[GridItem]] {
        guard !items.isEmpty else { return pages }
        return move(items, toPage: page, at: Int.max, in: pages, columns: columns, rows: rows)
    }

    /// 从第 `start` 页开始，把超出网格容量的条目顺延到下一页
    public static func reflow(_ pages: [[GridItem]], from start: Int, columns: Int, rows: Int) -> [[GridItem]] {
        var result = pages
        var p = max(start, 0)
        while p < result.count {
            let items = result[p]
            let fit = GridPacker.fitCount(for: items, columns: columns, rows: rows)
            guard fit < items.count else {
                p += 1
                continue
            }
            let overflow = Array(items.dropFirst(fit))
            result[p] = Array(items.prefix(fit))
            if p + 1 < result.count {
                result[p + 1].insert(contentsOf: overflow, at: 0)
            } else {
                result.append(overflow)
            }
            p += 1
        }
        return result
    }

    /// 从文件夹中释放应用：从 `startPage` 开始逐页寻找空位放置（放不下则新建页）
    public static func release(_ items: [GridItem],
                               fromPage startPage: Int,
                               in pages: [[GridItem]],
                               columns: Int,
                               rows: Int) -> [[GridItem]] {
        guard !items.isEmpty else { return pages }
        var result = pages.isEmpty ? [[]] : pages
        var p = min(max(startPage, 0), max(result.count - 1, 0))

        for item in items {
            while p < result.count && GridPacker.fitCount(for: result[p] + [item],
                                                          columns: columns, rows: rows) <= result[p].count {
                p += 1
            }
            if p >= result.count { result.append([]) }
            result[p].append(item)
        }
        return result
    }
}
