import Cocoa
import CoreServices

/// 扫描结果：完整列表 + 与上次扫描相比的增量差异。
///
/// 界面每次展示时都会做一次「增量扫描」：已存在且未变动的 .app 直接复用上次的
/// `AppInfo`（省掉 `Bundle` 解析与 Spotlight 查询），只有新增/改动的才重新解析。
public struct AppScanResult {
    public let apps: [AppInfo]
    public let added: [AppInfo]
    public let removed: [AppInfo]

    public var hasChanges: Bool { !added.isEmpty || !removed.isEmpty }

    public init(apps: [AppInfo], added: [AppInfo], removed: [AppInfo]) {
        self.apps = apps
        self.added = added
        self.removed = removed
    }
}

/// 递归扫描 .app，按 bundleID 去重（优先保留先扫到的目录里的），后台线程执行。
public enum AppScanner {

    /// 应用显示名：优先 Spotlight 本地化名（中文系统显示"系统设置"），
    /// 回退 Info.plist 的本地化/通用名称，最后用文件名。
    private static func displayName(for path: String, bundle: Bundle) -> String {
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
           let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String,
           !name.isEmpty {
            return name
        }
        let localized = bundle.localizedInfoDictionary
        return (localized?["CFBundleDisplayName"] as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (localized?["CFBundleName"] as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// 全量扫描（兼容旧调用）：completion 一定在主线程回调。
    public static func scan(paths: [String], maxDepth: Int, completion: @escaping ([AppInfo]) -> Void) {
        scan(paths: paths, maxDepth: maxDepth, previous: [], since: nil) { completion($0.apps) }
    }

    /// 扫描入口（支持增量）。
    ///
    /// - Parameters:
    ///   - previous: 上次扫描结果；其中的条目若在本次扫描时未被改动会被直接复用。
    ///   - since: 上次扫描完成的时刻。.app 目录的修改时间早于它即认为「未变动」，可复用缓存。
    /// - Returns: `added` / `removed` 为相对 `previous` 的差异，`hasChanges` 为假时调用方可跳过重排界面。
    public static func scan(paths: [String],
                            maxDepth: Int,
                            previous: [AppInfo],
                            since: Date?,
                            completion: @escaping (AppScanResult) -> Void) {
        // clamp 深度：防 config.json 被手改后失控递归（symlink 已跳过防环）
        let depth = min(max(maxDepth, 0), 20)
        var cache: [String: AppInfo] = [:]
        cache.reserveCapacity(previous.count)
        for app in previous { cache[app.path] = app }

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [String: AppInfo] = [:]
            let fm = FileManager.default
            for p in paths {
                guard !p.isEmpty else { continue }
                // 支持 ~/ 形式（config 以 tilde 存储，不暴露用户名）
                let expanded = (p as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded)
                guard fm.fileExists(atPath: expanded) else { continue }
                scanDir(url, depth: 0, maxDepth: depth, fm: fm,
                        cache: cache, since: since, into: &found)
            }
            let sorted = found.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            let previousPaths = Set(previous.map(\.path))
            let currentPaths = Set(sorted.map(\.path))
            let result = AppScanResult(
                apps: sorted,
                added: sorted.filter { !previousPaths.contains($0.path) },
                removed: previous.filter { !currentPaths.contains($0.path) }
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func scanDir(_ url: URL,
                                depth: Int,
                                maxDepth: Int,
                                fm: FileManager,
                                cache: [String: AppInfo],
                                since: Date?,
                                into found: inout [String: AppInfo]) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey, .contentModificationDateKey
        ]
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }

            if entry.pathExtension.lowercased() == "app" {
                // 增量：目录未改动则直接复用上次解析结果（跳过 Bundle / Spotlight 查询）
                if let since,
                   let cached = cache[entry.path],
                   let modified = values?.contentModificationDate,
                   modified < since {
                    if found[cached.bundleID] == nil { found[cached.bundleID] = cached }
                    continue
                }
                if let bundle = Bundle(path: entry.path), let bid = bundle.bundleIdentifier,
                   found[bid] == nil {
                    found[bid] = AppInfo(
                        name: displayName(for: entry.path, bundle: bundle),
                        path: entry.path,
                        bundleID: bid
                    )
                }
            } else if depth < maxDepth && values?.isSymbolicLink != true {
                scanDir(entry, depth: depth + 1, maxDepth: maxDepth, fm: fm,
                        cache: cache, since: since, into: &found)
            }
        }
    }
}
