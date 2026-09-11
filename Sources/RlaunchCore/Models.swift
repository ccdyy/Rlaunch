import Foundation

// MARK: - 应用条目（扫描结果）

public struct AppInfo: Equatable, Hashable {
    public let name: String
    public let path: String
    public let bundleID: String

    public init(name: String, path: String, bundleID: String) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
    }
}

// MARK: - 文件夹（目录）配置

public struct FolderConfig: Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var appPaths: [String]
    public var spanColumns: Int
    public var spanRows: Int

    /// 占用网格单元总数 N
    public var gridCellCount: Int {
        max(1, spanColumns) * max(1, spanRows)
    }

    public init(
        id: String,
        name: String = "文件夹",
        appPaths: [String] = [],
        spanColumns: Int = 1,
        spanRows: Int = 1
    ) {
        self.id = id
        self.name = name.isEmpty ? "文件夹" : name
        self.appPaths = appPaths
        self.spanColumns = max(1, spanColumns)
        self.spanRows = max(1, spanRows)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, appPaths, spanColumns, spanRows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "文件夹"
        appPaths = try c.decodeIfPresent([String].self, forKey: .appPaths) ?? []
        spanColumns = max(1, try c.decodeIfPresent(Int.self, forKey: .spanColumns) ?? 1)
        spanRows = max(1, try c.decodeIfPresent(Int.self, forKey: .spanRows) ?? 1)
    }
}

// MARK: - 网格单元：应用 或 文件夹

public enum GridItem: Equatable, Hashable {
    case app(AppInfo)
    case folder(FolderConfig)

    public var identifier: String {
        switch self {
        case .app(let info): return "app:\(info.path)"
        case .folder(let folder): return "folder:\(folder.id)"
        }
    }

    public var appPath: String? {
        if case .app(let info) = self { return info.path }
        return nil
    }

    public var folderID: String? {
        if case .folder(let folder) = self { return folder.id }
        return nil
    }

    public var displayName: String {
        switch self {
        case .app(let info): return info.name
        case .folder(let folder): return folder.name
        }
    }

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    public var isApp: Bool {
        if case .app = self { return true }
        return false
    }

    public var spanColumns: Int {
        switch self {
        case .app: return 1
        case .folder(let folder): return max(1, folder.spanColumns)
        }
    }

    public var spanRows: Int {
        switch self {
        case .app: return 1
        case .folder(let folder): return max(1, folder.spanRows)
        }
    }

    public var gridCellCount: Int {
        spanColumns * spanRows
    }
}

// MARK: - 主题

public enum Theme: String, Codable, CaseIterable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    public var displayName: String {
        switch self {
        case .light: return "明亮"
        case .dark: return "深黑"
        case .system: return "跟随系统"
        }
    }
}

// MARK: - 应用配置

public struct AppConfig: Codable, Equatable {
    // 扫描
    public var scanPaths: [String]
    public var recursionDepth: Int = 3    // 外观
    public var theme: Theme = .dark
    public var backgroundImagePath: String?
    public var bgOpacity: Double = 0.85          // 0.15 ~ 1.0
    public var bgBlur: Double = 0                // 0 ~ 60
    // 网格
    public var columns: Int = 7
    public var rows: Int = 5
    public var spacing: Double = 24          // 兼容旧配置，新代码使用 columnSpacing/rowSpacing
    public var columnSpacing: Double = 24
    public var rowSpacing: Double = 24
    public var fullscreenSpacingScale: Double = 1.6  // 全屏时列/行间距放大倍数
    public var iconSize: Double = 64
    // 快捷键（Carbon RegisterEventHotKey：keyCode + 修饰键位；keyCode 为 nil 表示未录制）
    public var hotKeyEnabled: Bool = false
    public var hotKeyKeyCode: Int?
    public var hotKeyModifiers: Int = 0
    // 捏合手势（四指/五指捏合：打开并全屏）
    public var pinchEnabled: Bool = true
    public var pinchThreshold: Double = 0.7    // 捏合幅度阈值（灵敏度）
    // 文件夹
    public var folders: [FolderConfig] = []
    /// 被用户隐藏的应用路径：扫描仍会找到，但不在启动台中展示
    public var hiddenAppPaths: [String] = []
    // 窗口
    public var windowWidth: Double = 1020
    public var windowHeight: Double = 700
    /// 上次关闭时的窗口原点（屏幕坐标）；为 nil 表示首次启动，窗口居中显示
    public var windowX: Double?
    public var windowY: Double?
    // 行为
    public var hideOnLaunch: Bool = true         // 启动应用后收起界面
    public var launchAtLogin: Bool = false       // 开机自动启动（SMAppService 登录项）
    // 自定义排序（存储 GridItem 的唯一键，如 "app:<path>" 或 "folder:<id>"）
    public var itemOrder: [String] = []
    // 分页排序（每页独立存储 GridItem 的唯一键，支持页面空间空置与跨页独立）
    public var pageOrders: [[String]] = []

    /// macOS 26 系统应用位于 /System/Applications（Launchpad 也会展示它们）。
    /// 用户目录用 ~ 形式存储（不暴露用户名，便于开源分享配置）。
    public static let defaultScanPaths = [
        "/Applications",
        "/System/Applications",
        "~/Applications",
    ]

    public static let defaults = AppConfig(scanPaths: defaultScanPaths)

    public init(scanPaths: [String] = AppConfig.defaultScanPaths) {
        self.scanPaths = scanPaths
    }

    /// 容错解码：旧版配置缺失新字段时用默认值，避免升级后配置被静默重置
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanPaths = try c.decodeIfPresent([String].self, forKey: .scanPaths) ?? AppConfig.defaultScanPaths
        recursionDepth = try c.decodeIfPresent(Int.self, forKey: .recursionDepth) ?? 3
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .dark
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        bgOpacity = try c.decodeIfPresent(Double.self, forKey: .bgOpacity) ?? 0.85
        bgBlur = try c.decodeIfPresent(Double.self, forKey: .bgBlur) ?? 0
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? 7
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 5
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 24
        columnSpacing = try c.decodeIfPresent(Double.self, forKey: .columnSpacing) ?? 24
        rowSpacing = try c.decodeIfPresent(Double.self, forKey: .rowSpacing) ?? 24
        fullscreenSpacingScale = try c.decodeIfPresent(Double.self, forKey: .fullscreenSpacingScale) ?? 1.6
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? 64
        hotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? false
        hotKeyKeyCode = try c.decodeIfPresent(Int.self, forKey: .hotKeyKeyCode)
        hotKeyModifiers = try c.decodeIfPresent(Int.self, forKey: .hotKeyModifiers) ?? 0
        // 旧版「手势」字段迁移为捏合字段（解码阶段一次性兼容，编码只写新字段）
        let legacyContainer = try decoder.container(keyedBy: LegacyKeys.self)
        let legacyEnabled = try legacyContainer.decodeIfPresent(Bool.self, forKey: .gestureEnabled)
        let legacyThreshold = try legacyContainer.decodeIfPresent(Double.self, forKey: .gestureThreshold)
        pinchEnabled = try c.decodeIfPresent(Bool.self, forKey: .pinchEnabled) ?? legacyEnabled ?? true
        pinchThreshold = try c.decodeIfPresent(Double.self, forKey: .pinchThreshold) ?? legacyThreshold ?? 0.7
        folders = try c.decodeIfPresent([FolderConfig].self, forKey: .folders) ?? []
        hiddenAppPaths = try c.decodeIfPresent([String].self, forKey: .hiddenAppPaths) ?? []
        windowWidth = try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? 1020
        windowHeight = try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? 700
        windowX = try c.decodeIfPresent(Double.self, forKey: .windowX)
        windowY = try c.decodeIfPresent(Double.self, forKey: .windowY)
        hideOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .hideOnLaunch) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        itemOrder = try c.decodeIfPresent([String].self, forKey: .itemOrder) ?? []
        pageOrders = try c.decodeIfPresent([[String]].self, forKey: .pageOrders) ?? []
    }

    public func appPathsInAllFolders() -> Set<String> {
        var set = Set<String>()
        for f in folders { set.formUnion(f.appPaths) }
        return set
    }

    /// 需要在启动台中展示的应用（扫描结果剔除已隐藏项）
    public func visibleApps(from scanned: [AppInfo]) -> [AppInfo] {
        guard !hiddenAppPaths.isEmpty else { return scanned }
        let hidden = Set(hiddenAppPaths)
        return scanned.filter { !hidden.contains($0.path) }
    }

    public func isHidden(appPath: String) -> Bool {
        hiddenAppPaths.contains(appPath)
    }

    public func folder(containing path: String) -> FolderConfig? {
        folders.first { $0.appPaths.contains(path) }
    }

    /// 旧版配置字段（仅解码用，编码只写新字段）
    private enum LegacyKeys: String, CodingKey {
        case gestureEnabled
        case gestureThreshold
    }
}

// MARK: - 配置存取

public enum ConfigStore {
    public static let didChange = Notification.Name("RlaunchConfigDidChange")

    /// 测试注入用：覆盖默认配置路径
    public static var configURLOverride: URL?

    private static var configURL: URL {
        if let override = configURLOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Rlaunch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 供「打开配置目录」等界面入口使用
    public static var configFileURL: URL { configURL }

    /// 旧版默认扫描路径（展开形式，无 /System/Applications），用于识别需要迁移的存量配置
    private static let legacyDefaultScanPaths = [
        "/Applications",
        NSString(string: "~/Applications").expandingTildeInPath,
    ]

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              var cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig.defaults
        }
        // 迁移：恰好等于旧默认的配置补上 /System/Applications；用户自定义目录保持不变
        if cfg.scanPaths == legacyDefaultScanPaths {
            cfg.scanPaths = AppConfig.defaultScanPaths
        }
        return cfg
    }

    @discardableResult
    public static func save(_ config: AppConfig) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return false }
        do {
            try data.write(to: configURL, options: .atomic)
            return true
        } catch {
            NSLog("Rlaunch: 保存配置失败 %@", error.localizedDescription)
            return false
        }
    }
}
