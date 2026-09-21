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
        name: String = L10n.t("文件夹"),
        appPaths: [String] = [],
        spanColumns: Int = 1,
        spanRows: Int = 1
    ) {
        self.id = id
        self.name = name.isEmpty ? L10n.t("文件夹") : name
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
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? L10n.t("文件夹")
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
        case .light: return L10n.t("明亮")
        case .dark: return L10n.t("深黑")
        case .system: return L10n.t("跟随系统")
        }
    }
}

// MARK: - 背景预设与纹理

public enum BackgroundTexture: String, Codable, CaseIterable {
    case none
    case noise       // 细腻磨砂噪点（胶片微粒/高级卡纸质感）
    case twill       // 45° 碳纤微斜纹（科技暗调/亚麻微编织）
    case dotGrid     // 极客微点阵（建筑/设计图纸点阵）
    case grid        // 极细方格网（经典工程绘图方格）
    case brushed     // 横向金属微拉丝（铝合金细腻质感）
}

public struct BackgroundPreset: Equatable {
    public let id: String
    public let name: String
    public let hexColor: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let tintOpacity: Double
    public let texture: BackgroundTexture

    public init(
        id: String,
        name: String,
        hexColor: String,
        red: Double,
        green: Double,
        blue: Double,
        tintOpacity: Double,
        texture: BackgroundTexture = .none
    ) {
        self.id = id
        self.name = name
        self.hexColor = hexColor
        self.red = red
        self.green = green
        self.blue = blue
        self.tintOpacity = tintOpacity
        self.texture = texture
    }
}

public enum BackgroundPresets {
    public static var darkPresets: [BackgroundPreset] {
        [
            // 经典纯色系
            BackgroundPreset(id: "default", name: L10n.t("默认深黑"), hexColor: "#1C1D22", red: 0.11, green: 0.11, blue: 0.13, tintOpacity: 0.38, texture: .none),
            BackgroundPreset(id: "obsidian", name: L10n.t("曜石炭黑"), hexColor: "#0E1014", red: 0.05, green: 0.06, blue: 0.08, tintOpacity: 0.58, texture: .none),
            BackgroundPreset(id: "midnight", name: L10n.t("极夜深蓝"), hexColor: "#101B2E", red: 0.06, green: 0.10, blue: 0.18, tintOpacity: 0.52, texture: .none),
            BackgroundPreset(id: "plum", name: L10n.t("紫檀暗调"), hexColor: "#221426", red: 0.13, green: 0.08, blue: 0.15, tintOpacity: 0.52, texture: .none),
            BackgroundPreset(id: "forest", name: L10n.t("午夜墨绿"), hexColor: "#10221A", red: 0.06, green: 0.13, blue: 0.10, tintOpacity: 0.52, texture: .none),
            BackgroundPreset(id: "titanium", name: L10n.t("钛金冷灰"), hexColor: "#20242B", red: 0.12, green: 0.14, blue: 0.17, tintOpacity: 0.50, texture: .none),
            // 质感纹理系（打破纯色单调）
            BackgroundPreset(id: "carbonTwill", name: L10n.t("碳纤斜纹"), hexColor: "#14171D", red: 0.08, green: 0.09, blue: 0.11, tintOpacity: 0.60, texture: .twill),
            BackgroundPreset(id: "darkMatte", name: L10n.t("微粒磨砂"), hexColor: "#16171B", red: 0.09, green: 0.09, blue: 0.11, tintOpacity: 0.55, texture: .noise),
            BackgroundPreset(id: "darkDotGrid", name: L10n.t("极客点阵"), hexColor: "#121824", red: 0.07, green: 0.09, blue: 0.14, tintOpacity: 0.56, texture: .dotGrid),
            BackgroundPreset(id: "brushedSteel", name: L10n.t("金属拉丝"), hexColor: "#1E2229", red: 0.12, green: 0.13, blue: 0.16, tintOpacity: 0.52, texture: .brushed),
        ]
    }

    public static var lightPresets: [BackgroundPreset] {
        [
            // 柔和纯色系
            BackgroundPreset(id: "softGray", name: L10n.t("柔和暖灰"), hexColor: "#E6E7EB", red: 0.90, green: 0.91, blue: 0.92, tintOpacity: 0.65, texture: .none),
            BackgroundPreset(id: "warmOat", name: L10n.t("燕麦暖白"), hexColor: "#EFECE5", red: 0.94, green: 0.92, blue: 0.90, tintOpacity: 0.68, texture: .none),
            BackgroundPreset(id: "iceMist", name: L10n.t("雾霭冰蓝"), hexColor: "#E0E8F2", red: 0.88, green: 0.91, blue: 0.95, tintOpacity: 0.65, texture: .none),
            BackgroundPreset(id: "sage", name: L10n.t("鼠尾草绿"), hexColor: "#E2ECE5", red: 0.88, green: 0.93, blue: 0.89, tintOpacity: 0.65, texture: .none),
            BackgroundPreset(id: "coolSilver", name: L10n.t("极简冷银"), hexColor: "#DFE3E9", red: 0.87, green: 0.89, blue: 0.91, tintOpacity: 0.66, texture: .none),
            BackgroundPreset(id: "blush", name: L10n.t("淡暮柔粉"), hexColor: "#F2E8E8", red: 0.95, green: 0.91, blue: 0.91, tintOpacity: 0.65, texture: .none),
            BackgroundPreset(id: "classic", name: L10n.t("经典磨砂"), hexColor: "#F5F5F7", red: 0.96, green: 0.96, blue: 0.97, tintOpacity: 0.18, texture: .none),
            // 质感纹理系（打破纯色单调）
            BackgroundPreset(id: "linenWeave", name: L10n.t("亚麻棉麻"), hexColor: "#ECE8E1", red: 0.92, green: 0.91, blue: 0.88, tintOpacity: 0.70, texture: .twill),
            BackgroundPreset(id: "artPaper", name: L10n.t("艺术卡纸"), hexColor: "#EAE7E1", red: 0.91, green: 0.90, blue: 0.88, tintOpacity: 0.68, texture: .noise),
            BackgroundPreset(id: "designGrid", name: L10n.t("极细方格"), hexColor: "#E4E6EB", red: 0.89, green: 0.90, blue: 0.92, tintOpacity: 0.68, texture: .grid),
            BackgroundPreset(id: "paperDotGrid", name: L10n.t("绘图点阵"), hexColor: "#E9ECEE", red: 0.91, green: 0.92, blue: 0.93, tintOpacity: 0.68, texture: .dotGrid),
        ]
    }

    public static func findDark(id: String) -> BackgroundPreset {
        darkPresets.first(where: { $0.id == id }) ?? darkPresets[0]
    }

    public static func findLight(id: String) -> BackgroundPreset {
        lightPresets.first(where: { $0.id == id }) ?? lightPresets[0]
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
    public var darkBgPreset: String = "default"  // 深色模式预设色
    public var lightBgPreset: String = "softGray" // 明亮模式预设色（默认柔和暖灰，不再刺眼）
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
    /// 界面语言（默认简体中文）
    public var language: AppLanguage = .zhHans
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
        darkBgPreset = try c.decodeIfPresent(String.self, forKey: .darkBgPreset) ?? "default"
        lightBgPreset = try c.decodeIfPresent(String.self, forKey: .lightBgPreset) ?? "softGray"
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
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .zhHans
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        itemOrder = try c.decodeIfPresent([String].self, forKey: .itemOrder) ?? []
        pageOrders = try c.decodeIfPresent([[String]].self, forKey: .pageOrders) ?? []
    }

    /// 把「设置面板」负责的字段从 `source` 覆盖到本配置上。
    ///
    /// 主窗口与设置面板各自负责一部分字段，两边都遵循「读取磁盘最新值 → 只改自己的字段 → 写回」，
    /// 因此这里必须完整列出设置面板的全部字段：早先 `persist()` 手写字段清单时漏掉了
    /// `language` 与 `hiddenAppPaths`，导致「切换语言」「恢复隐藏应用」写不进配置文件。
    ///
    /// 主窗口负责、此处**不覆盖**的字段：`folders` / `itemOrder` / `pageOrders` / `window*` / `hideOnLaunch`。
    public mutating func applySettings(from source: AppConfig) {
        scanPaths = source.scanPaths
        recursionDepth = source.recursionDepth
        theme = source.theme
        language = source.language
        backgroundImagePath = source.backgroundImagePath
        bgOpacity = source.bgOpacity
        bgBlur = source.bgBlur
        darkBgPreset = source.darkBgPreset
        lightBgPreset = source.lightBgPreset
        columns = source.columns
        rows = source.rows
        columnSpacing = source.columnSpacing
        rowSpacing = source.rowSpacing
        fullscreenSpacingScale = source.fullscreenSpacingScale
        iconSize = source.iconSize
        hotKeyEnabled = source.hotKeyEnabled
        hotKeyKeyCode = source.hotKeyKeyCode
        hotKeyModifiers = source.hotKeyModifiers
        pinchEnabled = source.pinchEnabled
        pinchThreshold = source.pinchThreshold
        launchAtLogin = source.launchAtLogin
        hiddenAppPaths = source.hiddenAppPaths
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
