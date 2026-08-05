import Cocoa

/// 图标缓存：只加载一次，LRU 淘汰，避免重复读磁盘、控制内存。
public final class IconCache {
    public static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()
    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 512 * 1024 * 1024 // 512MB 上限，正常远达不到
    }

    public func icon(for path: String) -> NSImage {
        if let img = cache.object(forKey: path as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: path as NSString)
        return img
    }

    public func clear() {
        cache.removeAllObjects()
    }
}
