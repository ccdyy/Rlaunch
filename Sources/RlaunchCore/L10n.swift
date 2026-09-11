import Foundation

/// 界面语言
public enum AppLanguage: String, Codable, CaseIterable {
    case zhHans = "zh-Hans"
    case en = "en"

    /// 语言选择器里的显示名（各语言下都显示自己的名字，便于识别）
    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

/// 轻量本地化层。
///
/// 设计取舍：以**简体中文原文作为键**做查表。
/// 这样无需为上百条文案另起一套键名（也不会出现键名与文案对不上），
/// 中文直接返回原文，英文缺失时自动回退到中文，不会出现空白或 key 泄漏。
/// 语言可运行时立即切换，无需重启。
public enum L10n {

    public private(set) static var language: AppLanguage = .zhHans

    public static func setLanguage(_ language: AppLanguage) {
        self.language = language
    }

    /// 取译文（简体中文为键）
    public static func t(_ zh: String) -> String {
        guard language != .zhHans else { return zh }
        return english[zh] ?? zh
    }

    /// 带格式参数的译文，参数用 `%d` / `%@` 占位
    public static func f(_ zh: String, _ args: CVarArg...) -> String {
        String(format: t(zh), arguments: args)
    }

    /// 英文文案表：键为简体中文原文
    /// 把一段「已知译文」换成当前语言的说法；不是已知文案则原样返回。
    ///
    /// 用于切换语言时**就地刷新**界面：遍历视图拿到当前文本 → 反查回键 → 写入新语言，
    /// 无需重建窗口（重建会闪烁、丢滚动位置）。
    public static func retranslate(_ text: String) -> String {
        guard let key = reverseIndex[text] else { return text }
        return t(key)
    }

    /// 反查索引：任一语言的文案 → 简体中文键。英文值需唯一，否则会有歧义（见自测守护）。
    private static let reverseIndex: [String: String] = {
        var index: [String: String] = [:]
        for (key, value) in table.map {
            index[key] = key
            if index[value] == nil { index[value] = key }
        }
        return index
    }()

    /// 英文文案表：键为简体中文原文。
    /// 用元组数组而非字典字面量构建——字典字面量一旦出现重复键会在运行时直接崩溃，
    /// 这里改为后者覆盖 + 记录重复键，便于自测发现（见 `duplicateKeys`）。
    public static let english: [String: String] = table.map

    /// 重复的键（正常应为空，由自测守护）
    public static var duplicateKeys: [String] { table.duplicates }

    private static let table: (map: [String: String], duplicates: [String]) = {
        let pairs: [(String, String)] = [

        // MARK: 菜单栏
        ("Rlaunch：点击打开 / 收起，右键查看更多", "Rlaunch: click to open or dismiss, right-click for more"),
        ("显示 / 隐藏 Rlaunch", "Show / Hide Rlaunch"),
        ("设置…", "Settings…"),
        ("退出 Rlaunch", "Quit Rlaunch"),
        // MARK: 顶栏
        ("隐藏 Rlaunch", "Hide Rlaunch"),
        ("最小化窗口", "Minimize window"),
        ("切换全屏", "Toggle full screen"),
        ("搜索", "Search"),
        ("搜索应用…", "Search apps…"),
        ("搜索应用", "Search apps"),
        ("全屏 / 退出全屏", "Enter / Exit full screen"),
        ("重新扫描应用", "Rescan apps"),
        ("设置", "Settings"),
        // MARK: 条目
        ("文件夹", "Folder"),
        ("应用", "App"),
        ("%@（文件夹）", "%@ (folder)"),
        ("%@，%@", "%@, %@"),
        // MARK: 中转站
        ("%@\n点击移除出中转站", "%@\nClick to remove"),
        ("%@ (文件夹)\n点击移除出中转站", "%@ (folder)\nClick to remove"),
        ("清空并退出多选", "Clear and exit selection"),
        ("放本页", "Place here"),
        ("建文件夹", "New folder"),
        ("放文件夹", "Add to folder"),
        // MARK: 文件夹弹窗
        ("解散文件夹", "Dissolve Folder"),
        ("共 %d 个应用", "%d apps"),
        ("放入选中应用 (%d)", "Add %d selected"),
        ("从文件夹移出", "Remove from folder"),
        // MARK: 通用浮层
        ("取消", "Cancel"),
        // MARK: 空状态
        ("没有匹配的应用", "No matching apps"),
        ("换个关键词试试，或按 Esc 清空搜索", "Try another keyword, or press Esc to clear"),
        ("还没有扫描到应用", "No apps found yet"),
        ("请检查「设置 → 应用扫描」中的目录是否正确", "Check the folders in Settings → Scanning"),
        ("重新扫描", "Rescan"),
        // MARK: 主窗口提示与菜单
        ("最多只能添加 %d 个", "You can select up to %d items"),
        ("「%@」已不存在，正在重新扫描…", "“%@” no longer exists — rescanning…"),
        ("无法打开「%@」：%@", "Could not open “%@”: %@"),
        ("新建文件夹", "New Folder"),
        ("输入文件夹名称，之后可以把应用拖入该文件夹", "Enter a name. You can drag apps into this folder later."),
        ("创建", "Create"),
        ("重命名文件夹", "Rename Folder"),
        ("确定", "OK"),
        ("删除文件夹", "Delete Folder"),
        ("确定删除「%@」吗？里面的应用将被释放回主界面。", "Delete “%@”? Its apps will be released back to the desktop."),
        ("删除并释放", "Delete & Release"),
        ("确定要解散「%@」吗？里面的应用将被释放回主界面。", "Dissolve “%@”? Its apps will be released back to the desktop."),
        ("解散", "Dissolve"),
        ("从「%@」移出", "Remove from “%@”"),
        ("移动到文件夹", "Move to Folder"),
        ("在访达中显示", "Show in Finder"),
        ("退出应用", "Quit App"),
        ("从启动台隐藏", "Hide from Launcher"),
        ("网格大小", "Grid Size"),
        ("1 × 1 (标准)", "1 × 1 (Standard)"),
        ("2 × 1 (横向双格)", "2 × 1 (Wide)"),
        ("1 × 2 (纵向双格)", "1 × 2 (Tall)"),
        ("2 × 2 (大卡片)", "2 × 2 (Large)"),
        ("重命名", "Rename"),
        ("已隐藏「%@」，可在设置中恢复", "“%@” hidden — restore it in Settings"),
        // MARK: 主题
        ("明亮", "Light"),
        ("深黑", "Dark"),
        ("跟随系统", "System"),
        // MARK: 快捷键
        ("未设置", "Not set"),
        // MARK: 背景渲染
        ("Liquid Glass（macOS 26 原生）", "Liquid Glass (native, macOS 26)"),
        ("毛玻璃（NSVisualEffectView）", "Vibrancy (NSVisualEffectView)"),
        // MARK: 设置 - 标签页
        ("Rlaunch 设置", "Rlaunch Settings"),
        ("外观", "Appearance"),
        ("网格", "Grid"),
        ("应用扫描", "Scanning"),
        ("快捷键", "Shortcuts"),
        ("通用", "General"),
        // MARK: 设置 - 外观
        ("界面样式", "Interface"),
        ("主题模式", "Theme"),
        ("语言", "Language"),
        ("切换语言后界面立即生效，无需重启。", "Language changes take effect immediately — no restart needed."),
        ("背景图片", "Background Image"),
        ("默认（系统毛玻璃）", "Default (vibrancy)"),
        ("选择图片…", "Choose…"),
        ("清除", "Clear"),
        ("背景效果", "Background Effect"),
        ("透明度", "Opacity"),
        ("模糊程度", "Blur"),
        ("提示：高斯模糊仅在使用自定义背景图片时生效。", "Note: blur only applies when a custom background image is set."),
        ("当前背景渲染方式：%@。", "Active background renderer: %@."),
        // MARK: 设置 - 网格
        ("布局规格", "Layout"),
        ("列数", "Columns"),
        ("行数", "Rows"),
        ("间距与尺寸", "Spacing & Size"),
        ("列间距", "Column Spacing"),
        ("行间距", "Row Spacing"),
        ("全屏缩放", "Full-screen Scale"),
        ("图标大小", "Icon Size"),
        // MARK: 设置 - 应用扫描
        ("扫描目录", "Scan Folders"),
        ("目录列表", "Folders"),
        ("添加目录…", "Add Folder…"),
        ("扫描参数与操作", "Options"),
        ("递归层级", "Recursion Depth"),
        ("搜索应用时的最大目录深度（建议保持为 3）。", "Maximum folder depth when scanning (3 recommended)."),
        ("应用索引", "App Index"),
        ("立即重新扫描", "Rescan Now"),
        ("已隐藏的应用", "Hidden Apps"),
        ("隐藏列表", "Hidden"),
        ("在启动台中右键应用选择「从启动台隐藏」后，可在这里恢复显示。", "Right-click an app and choose “Hide from Launcher”, then restore it here."),
        ("未配置扫描目录", "No scan folders configured"),
        ("没有被隐藏的应用", "No hidden apps"),
        ("恢复", "Restore"),
        ("恢复显示", "Show again"),
        ("选择要扫描的应用目录", "Choose folders to scan for apps"),
        ("已触发重新扫描 ✓", "Rescan started ✓"),
        // MARK: 设置 - 快捷键与手势
        ("全局快捷键", "Global Shortcut"),
        ("全局唤起", "Activation"),
        ("启用全局快捷键唤起", "Enable global shortcut"),
        ("唤起快捷键", "Shortcut"),
        ("录制快捷键…", "Record Shortcut…"),
        ("按下快捷键… (Esc 取消)", "Press shortcut… (Esc to cancel)"),
        ("触控板手势", "Trackpad Gesture"),
        ("捏合唤起", "Pinch to open"),
        ("四指/五指捏合：打开并全屏", "4/5-finger pinch: open in full screen"),
        ("灵敏度", "Sensitivity"),
        ("系统权限与手势", "Permissions & Gestures"),
        ("辅助功能", "Accessibility"),
        ("辅助功能：未授权", "Accessibility: Not granted"),
        ("辅助功能：已授权 ✓", "Accessibility: Granted ✓"),
        ("打开权限设置…", "Open Privacy Settings…"),
        ("触控板", "Trackpad"),
        ("触控板手势设置…", "Trackpad Settings…"),
        ("手势说明：四指/五指捏合通过系统触摸点间距收缩算法识别（需要辅助功能权限）。若系统已授权仍无法使用，可在「辅助功能」中先移除 Rlaunch 再重新添加，并在「触控板手势设置」中检查是否被系统默认手势占用。", "Pinch detection uses a fingertip-distance shrink algorithm and requires Accessibility permission. " + "If it still does not work after granting access, remove Rlaunch from Accessibility and add it again, " + "and check in Trackpad Settings whether the gesture is taken by a system gesture."),
        // MARK: 设置 - 通用
        ("系统启动", "Startup"),
        ("开机启动", "Launch at Login"),
        ("登录时自动启动 Rlaunch", "Launch Rlaunch at login"),
        ("可在「系统设置 → 通用 → 登录项与扩展」中管理。", "Manage in System Settings → General → Login Items & Extensions."),
        ("状态：已开启（登录时自动启动）", "Status: On (starts at login)"),
        ("状态：需要系统授权（请在系统设置中允许）", "Status: Needs approval (allow it in System Settings)"),
        ("状态：未开启", "Status: Off"),
        ("状态：未找到应用副本，请放入「应用程序」文件夹", "Status: App copy not found — move Rlaunch into /Applications"),
        ("应用维护", "Maintenance"),
        ("配置文件", "Config File"),
        ("打开配置目录", "Open Config Folder"),
        ("导出…", "Export…"),
        ("导入…", "Import…"),
        ("重置", "Reset"),
        ("恢复默认设置", "Restore Defaults"),
        ("重置桌面布局", "Reset Layout"),
        ("确认恢复？", "Confirm restore?"),
        ("仅重置设置项，保留文件夹与桌面布局", "Only resets preferences; folders and layout are kept"),
        ("确认重置？", "Confirm reset?"),
        ("将清空所有文件夹与页面编排，应用不受影响", "Clears all folders and page layout; apps are unaffected"),
        ("已恢复默认设置 ✓", "Defaults restored ✓"),
        ("桌面布局已重置 ✓", "Layout reset ✓"),
        ("已导出 ✓", "Exported ✓"),
        ("导出失败：%@", "Export failed: %@"),
        ("选择要导入的 Rlaunch 配置文件", "Choose a Rlaunch config file"),
        ("导入失败：文件格式不正确", "Import failed: invalid file format"),
        ("已导入 ✓", "Imported ✓"),
        // MARK: 设置 - 关于
        ("关于", "About"),
        ("在浏览器中打开 %@", "Open %@ in your browser"),
        ("复制地址", "Copy URL"),
        ("已复制 ✓", "Copied ✓"),
        ("Rlaunch · 轻量高效的 macOS 启动台平替。点击 GitHub 地址可在浏览器中打开项目主页。", "Rlaunch — a lightweight native Launchpad replacement for macOS. Click the GitHub link to open the project page."),
        ]
        var seen = Set<String>()
        var duplicates = Set<String>()
        var map: [String: String] = [:]
        for (key, value) in pairs {
            if seen.contains(key) { duplicates.insert(key) } else { seen.insert(key) }
            map[key] = value
        }
        return (map, duplicates.sorted())
    }()
}
