import Cocoa

/// 图标缓存：只加载一次，LRU 淘汰，避免重复读磁盘、控制内存。
public final class IconCache {
    public static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 256 * 1024 * 1024 // 256MB 上限
    }

    public func icon(for path: String) -> NSImage {
        if let img = cache.object(forKey: path as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        // NSCache 默认 cost 为 0，会让 totalCostLimit 完全失效；这里按像素占用估算成本
        let pixelWidth = max(img.size.width, 1)
        let pixelHeight = max(img.size.height, 1)
        let cost = Int(pixelWidth * pixelHeight * 4)
        cache.setObject(img, forKey: path as NSString, cost: cost)
        return img
    }

    public func clear() {
        cache.removeAllObjects()
    }
}
