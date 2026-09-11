import Foundation

/// 分页滚动到边界后的橡皮筋位移映射。
///
/// 抽成纯函数放在 Core：`SnapScrollView` 里是私有方法无法单测，
/// 而这段曲线（区间内 1:1、越界渐近阻尼、边界连续）恰恰是最容易写错的地方。
public enum ElasticScroll {

    /// 渐近阻尼量：拉动距离 d → ∞ 时位移趋近 `limit`，d 较小时几乎 1:1。
    /// 公式 `limit * (1 - 1 / (d/limit + 1))` 等价于 `d*limit / (d + limit)`。
    public static func rubberBand(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        let d = max(0, distance)
        guard limit > 0 else { return 0 }
        return limit * (1 - 1 / (d / limit + 1))
    }

    /// 手指原始位移 → 实际显示位移。
    /// - `raw` ∈ [0, maxX]：原样返回（1:1 跟手）
    /// - `raw < 0` 或 `raw > maxX`：超出部分按阻尼压缩，最多越界 `limit`
    public static func displayedOrigin(raw: CGFloat, maxX: CGFloat, limit: CGFloat) -> CGFloat {
        if raw < 0 { return -rubberBand(-raw, limit: limit) }
        if raw > maxX { return maxX + rubberBand(raw - maxX, limit: limit) }
        return raw
    }
}
