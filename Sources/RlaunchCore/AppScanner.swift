import Cocoa
import CoreServices

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

    /// 扫描入口。completion 一定在主线程回调。
    public static func scan(paths: [String], maxDepth: Int, completion: @escaping ([AppInfo]) -> Void) {
        // clamp 深度：防 config.json 被手改后失控递归（symlink 已跳过防环）
        let depth = min(max(maxDepth, 0), 20)
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [String: AppInfo] = [:]
            let fm = FileManager.default
            for p in paths {
                guard !p.isEmpty else { continue }
                // 支持 ~/ 形式（config 以 tilde 存储，不暴露用户名）
                let expanded = (p as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded)
                guard fm.fileExists(atPath: expanded) else { continue }
                scanDir(url, depth: 0, maxDepth: depth, fm: fm, into: &found)
            }
            let sorted = found.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    private static func scanDir(_ url: URL, depth: Int, maxDepth: Int, fm: FileManager, into found: inout [String: AppInfo]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true else { continue }

            if entry.pathExtension.lowercased() == "app" {
                if let bundle = Bundle(path: entry.path), let bid = bundle.bundleIdentifier {
                    if found[bid] == nil {
                        found[bid] = AppInfo(
                            name: displayName(for: entry.path, bundle: bundle),
                            path: entry.path,
                            bundleID: bid
                        )
                    }
                }
            } else if depth < maxDepth && values?.isSymbolicLink != true {
                scanDir(entry, depth: depth + 1, maxDepth: maxDepth, fm: fm, into: &found)
            }
        }
    }
}
