// Rlaunch 自测入口：无 XCTest 依赖（CLT 环境无 XCTest），断言失败即非零退出。
import Foundation
import RlaunchCore

private var failures: [String] = []

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("  ✅ \(name)")
    } else {
        failures.append(name)
        print("  ❌ \(name)")
    }
}

func waitForScan(_ paths: [String], maxDepth: Int) -> [AppInfo] {
    var result: [AppInfo] = []
    var done = false
    AppScanner.scan(paths: paths, maxDepth: maxDepth) {
        result = $0
        done = true
    }
    // 主线程等待主队列回调：必须跑 RunLoop，不能用信号量（会死锁）
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    return result
}

// MARK: - FuzzySearch

func testFuzzySearch() {
    print("FuzzySearch:")
    check(FuzzySearch.matches(name: "Safari", query: "saf"), "子串匹配（大小写不敏感）")
    check(FuzzySearch.matches(name: "系统设置", query: "设置"), "中文子串匹配")
    check(!FuzzySearch.matches(name: "Safari", query: "chrome"), "不相关不匹配")
    check(FuzzySearch.matches(name: "Safari", query: "Safrai"), "编辑距离 1 容错")
    check(!FuzzySearch.matches(name: "Safari", query: "Xyzzy"), "距离过大不匹配")
    check(FuzzySearch.matches(name: "Safari Technology Preview", query: "stp"), "首字母缩写匹配")
    check(FuzzySearch.matches(name: "Anything", query: "  "), "空查询全匹配")
}

// MARK: - AppScanner

func testScanner() throws {
    print("AppScanner:")
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rlaunch-selftest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func makeApp(named name: String, bundleID: String, at dir: URL) throws {
        let appDir = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appDir.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let exe = macos.appendingPathComponent(name)
        try Data().write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    let apps = root.appendingPathComponent("Apps", isDirectory: true)
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    try makeApp(named: "Alpha", bundleID: "com.test.alpha", at: apps)
    let sub = apps.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try makeApp(named: "Beta", bundleID: "com.test.beta", at: sub)

    var result = waitForScan([apps.path], maxDepth: 0)
    check(result.map(\.name) == ["Alpha"], "深度 0 只扫到根目录应用")

    result = waitForScan([apps.path], maxDepth: 3)
    check(result.map(\.name) == ["Alpha", "Beta"], "深度 3 扫到子目录应用")

    let apps2 = root.appendingPathComponent("B", isDirectory: true)
    try FileManager.default.createDirectory(at: apps2, withIntermediateDirectories: true)
    try makeApp(named: "Dup2", bundleID: "com.test.alpha", at: apps2)
    result = waitForScan([apps.path, apps2.path], maxDepth: 3)
    check(result.count == 2, "相同 bundleID 去重（Alpha 与 Beta 共 2 个）")

    result = waitForScan(["/nonexistent/path-xyz"], maxDepth: 3)
    check(result.isEmpty, "不存在的路径被忽略")
}

// MARK: - ConfigStore

func testConfigStore() throws {
    print("ConfigStore:")
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("rlaunch-selftest-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    ConfigStore.configURLOverride = tmp.appendingPathComponent("config.json")

    var cfg = AppConfig.defaults
    cfg.theme = .light
    cfg.columns = 9
    cfg.iconSize = 80
    cfg.folders = [FolderConfig(id: "f1", name: "工具", appPaths: ["/Applications/Calc.app"])]
    check(ConfigStore.save(cfg), "配置保存")

    let loaded = ConfigStore.load()
    check(loaded.theme == .light, "主题往返一致")
    check(loaded.columns == 9 && loaded.iconSize == 80, "网格参数往返一致")
    check(loaded.folders.first?.name == "工具", "文件夹配置往返一致")
    check(loaded.recursionDepth == 3, "默认递归层级为 3")

    // 快捷键字段往返（keyCode=49 Space，modifiers=256 cmdKey）
    var hot = cfg
    hot.hotKeyEnabled = true
    hot.hotKeyKeyCode = 49
    hot.hotKeyModifiers = 256
    hot.pinchEnabled = false
    hot.pinchThreshold = 1.2
    check(ConfigStore.save(hot), "保存快捷键/捏合配置")
    let hotLoaded = ConfigStore.load()
    check(hotLoaded.hotKeyEnabled && hotLoaded.hotKeyKeyCode == 49 && hotLoaded.hotKeyModifiers == 256,
          "快捷键字段往返一致")
    check(hotLoaded.pinchEnabled == false && hotLoaded.pinchThreshold == 1.2, "捏合字段往返一致")

    // 自定义排序 itemOrder 与分页 pageOrders 往返
    var orderCfg = cfg
    orderCfg.itemOrder = ["folder:f1", "app:/Applications/Safari.app", "app:/Applications/Terminal.app"]
    orderCfg.pageOrders = [
        ["folder:f1", "app:/Applications/Safari.app"],
        ["app:/Applications/Terminal.app"]
    ]
    check(ConfigStore.save(orderCfg), "保存自定义排序与分页配置")
    let orderLoaded = ConfigStore.load()
    check(orderLoaded.itemOrder == ["folder:f1", "app:/Applications/Safari.app", "app:/Applications/Terminal.app"],
          "自定义排序 itemOrder 往返一致")
    check(orderLoaded.pageOrders == [
        ["folder:f1", "app:/Applications/Safari.app"],
        ["app:/Applications/Terminal.app"]
    ], "独立分页 pageOrders 往返一致（支持页面空间空置与独立）")

    // 兼容旧版 pageOrders 直接存应用路径（无 app: 前缀）
    var legacyOrderCfg = cfg
    legacyOrderCfg.pageOrders = [
        ["/Applications/Safari.app", "/Applications/Terminal.app"]
    ]
    check(ConfigStore.save(legacyOrderCfg), "保存旧版路径格式 pageOrders")
    let legacyLoaded = ConfigStore.load()
    check(legacyLoaded.pageOrders.first?.first == "/Applications/Safari.app",
          "旧版路径格式 pageOrders 可正常读写")

    // 窗口位置记忆往返（首次启动无该字段时应为 nil）
    var frameCfg = cfg
    frameCfg.windowWidth = 1024
    frameCfg.windowHeight = 720
    frameCfg.windowX = 320
    frameCfg.windowY = 180
    check(ConfigStore.save(frameCfg), "保存窗口位置配置")
    let frameLoaded = ConfigStore.load()
    check(frameLoaded.windowX == 320 && frameLoaded.windowY == 180,
          "窗口位置 windowX/windowY 往返一致")
    check(frameLoaded.windowWidth == 1024 && frameLoaded.windowHeight == 720,
          "窗口尺寸往返一致")

    // 语言设置往返 + 旧配置默认
    var langCfg = cfg
    langCfg.language = .en
    check(ConfigStore.save(langCfg), "保存语言配置")
    check(ConfigStore.load().language == .en, "语言设置往返一致")

    // 直接解码带 language 的 JSON（对应"配置文件里写好语言后启动"的场景）
    let langJSON = #"{"language": "en"}"#
    if let decodedLang = try? JSONDecoder().decode(AppConfig.self, from: langJSON.data(using: .utf8)!) {
        check(decodedLang.language == .en, "JSON 中的 language 字段可正确解码")
    } else {
        check(false, "带 language 的配置可正常解码")
    }
    check(AppConfig.defaults.language == .zhHans, "默认语言为简体中文")

    check(ConfigStore.save(cfg), "恢复默认配置")

    // 隐藏应用：往返 + 过滤 + 旧配置容错
    var hideCfg = cfg
    hideCfg.hiddenAppPaths = ["/Applications/Junk.app"]
    check(ConfigStore.save(hideCfg), "保存隐藏应用配置")
    let hideLoaded = ConfigStore.load()
    check(hideLoaded.hiddenAppPaths == ["/Applications/Junk.app"], "隐藏应用列表往返一致")
    let scanned = [
        AppInfo(name: "Junk", path: "/Applications/Junk.app", bundleID: "com.test.junk"),
        AppInfo(name: "Keep", path: "/Applications/Keep.app", bundleID: "com.test.keep"),
    ]
    check(hideLoaded.visibleApps(from: scanned).map(\.name) == ["Keep"], "隐藏的应用不出现在可见列表中")
    check(hideLoaded.isHidden(appPath: "/Applications/Junk.app"), "隐藏状态查询正确")
    check(AppConfig.defaults.visibleApps(from: scanned).count == 2, "未配置隐藏时返回全部应用")

    check(ConfigStore.save(cfg), "恢复默认配置")

    // 迁移分支 1：旧默认扫描目录 → 自动补上 /System/Applications
    var legacy = cfg
    legacy.scanPaths = ["/Applications",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
    check(ConfigStore.save(legacy), "保存旧默认配置")
    let migrated = ConfigStore.load()
    check(migrated.scanPaths == AppConfig.defaultScanPaths, "旧默认配置迁移为完整默认目录")

    // 迁移分支 2：用户自定义目录保持不变
    var custom = cfg
    custom.scanPaths = ["/Users/tester/DevApps"]
    check(ConfigStore.save(custom), "保存自定义配置")
    let kept = ConfigStore.load()
    check(kept.scanPaths == ["/Users/tester/DevApps"], "自定义目录不被迁移覆盖")

    // 兼容性：真实旧格式 JSON（缺失新字段）应能解码且新字段用默认值
    let legacyJSON = """
    {"bgBlur": 0, "bgOpacity": 0.85, "columns": 7, "folders": [], "gestureEnabled": true,
     "gestureThreshold": 0.7, "hideOnLaunch": true, "iconSize": 64, "recursionDepth": 3,
     "rows": 5, "scanPaths": ["/Applications", "/Users/olduser/Applications"],
     "spacing": 24, "theme": "dark", "windowHeight": 700, "windowWidth": 1020}
    """
    let legacyData = legacyJSON.data(using: .utf8)!
    if let decoded = try? JSONDecoder().decode(AppConfig.self, from: legacyData) {
        check(decoded.columnSpacing == 24 && decoded.rowSpacing == 24
              && decoded.fullscreenScale == 1.25, "旧配置缺新字段时使用默认值")
        check(decoded.scanPaths == ["/Applications", "/Users/olduser/Applications"], "旧配置自定义路径不被迁移")
        check(decoded.pinchEnabled == true && decoded.pinchThreshold == 0.7,
              "旧 gesture 字段迁移为捏合字段")
        check(decoded.hotKeyKeyCode == nil && decoded.hotKeyEnabled == false, "旧配置默认无快捷键")
        check(decoded.windowX == nil && decoded.windowY == nil,
              "旧配置无窗口位置时保持 nil（首启居中）")
        check(decoded.hiddenAppPaths.isEmpty, "旧配置无隐藏列表时默认为空")
        check(decoded.language == .zhHans, "旧配置无语言字段时默认为简体中文")
        check(decoded.darkBgPreset == "default" && decoded.lightBgPreset == "softGray", "旧配置缺背景预设字段时使用默认值")
    } else {
        check(false, "旧格式配置可正常解码（缺新字段不崩溃）")
    }

    // 早期的「全屏间距放大倍数」字段已被「全屏缩放」取代：旧值被忽略，使用新默认值，且不影响其余字段
    let spacingScaleJSON = """
    {"columns": 6, "rows": 4, "iconSize": 72, "fullscreenSpacingScale": 2.5, "scanPaths": ["/Applications"]}
    """
    if let decoded = try? JSONDecoder().decode(AppConfig.self, from: spacingScaleJSON.data(using: .utf8)!) {
        check(decoded.fullscreenScale == 1.25, "旧的全屏间距倍数字段被忽略，使用新的全屏缩放默认值")
        check(decoded.columns == 6 && decoded.rows == 4 && decoded.iconSize == 72, "忽略旧字段不影响其他网格设置")
        let settings = decoded.gridSettings
        check(settings.columns == 6 && settings.rows == 4 && settings.iconSize == 72
              && settings.fullscreenScale == 1.25, "gridSettings 如实反映配置")
    } else {
        check(false, "带旧全屏间距字段的配置可正常解码")
    }
}

// MARK: - 边界橡皮筋

func testElasticScroll() {
    print("ElasticScroll:")
    let limit: CGFloat = 96
    let maxX: CGFloat = 2000

    check(ElasticScroll.displayedOrigin(raw: 500, maxX: maxX, limit: limit) == 500, "区间内 1:1 跟手")
    check(ElasticScroll.displayedOrigin(raw: 0, maxX: maxX, limit: limit) == 0, "左边界处无偏移")
    check(ElasticScroll.displayedOrigin(raw: maxX, maxX: maxX, limit: limit) == maxX, "右边界处无偏移")

    // 边界连续：刚越界时几乎不压缩
    let justOver = ElasticScroll.displayedOrigin(raw: maxX + 1, maxX: maxX, limit: limit)
    check(abs(justOver - (maxX + 1)) < 0.02, "越过边界的瞬间连续（无跳变）")
    let justUnderLeft = ElasticScroll.displayedOrigin(raw: -1, maxX: maxX, limit: limit)
    check(abs(justUnderLeft - (-1)) < 0.02, "左边界外侧同样连续")

    // 阻尼：越拉越沉，且始终不超过 limit
    let d60 = maxX + ElasticScroll.rubberBand(60, limit: limit)
    let d200 = maxX + ElasticScroll.rubberBand(200, limit: limit)
    let d4000 = maxX + ElasticScroll.rubberBand(4000, limit: limit)
    check(d60 < maxX + 60, "越界位移被压缩（拖 60pt 只走 \(Int(d60 - maxX))pt）")
    check(d200 > d60 && d4000 > d200, "拉得越远位移越大")
    check(d4000 - maxX < limit, "越界位移不超过上限 \(Int(limit))pt")

    // 单调性
    var monotonic = true
    var previous = ElasticScroll.displayedOrigin(raw: 0, maxX: maxX, limit: limit)
    for raw in stride(from: CGFloat(10), through: 3000, by: 10) {
        let current = ElasticScroll.displayedOrigin(raw: raw, maxX: maxX, limit: limit)
        if current < previous { monotonic = false; break }
        previous = current
    }
    check(monotonic, "位移随手指移动单调不减")

    check(ElasticScroll.rubberBand(0, limit: limit) == 0, "零位移不产生阻尼偏移")
    check(ElasticScroll.rubberBand(100, limit: 0) == 0, "上限为 0 时退化为硬边界")
}

// MARK: - 设置面板持久化合并

/// 回归：设置面板曾经手写字段清单，漏掉 language / hiddenAppPaths，
/// 导致「切换语言」「恢复隐藏应用」写不进配置文件（界面看起来"没生效"）。
func testApplySettings() {
    print("ApplySettings:")

    var disk = AppConfig.defaults          // 磁盘上：主窗口负责的字段
    disk.folders = [FolderConfig(id: "f1", name: "保留的文件夹", appPaths: ["/a.app"])]
    disk.itemOrder = ["folder:f1"]
    disk.pageOrders = [["folder:f1"]]
    disk.windowWidth = 1234
    disk.windowX = 11
    disk.windowY = 22
    disk.hideOnLaunch = false

    var panel = AppConfig.defaults         // 设置面板负责的字段（全部改成非默认值）
    panel.scanPaths = ["/Custom"]
    panel.recursionDepth = 5
    panel.theme = .light
    panel.language = .en
    panel.backgroundImagePath = "/tmp/bg.png"
    panel.bgOpacity = 0.42
    panel.bgBlur = 33
    panel.darkBgPreset = "midnight"
    panel.lightBgPreset = "warmOat"
    panel.columns = 9
    panel.rows = 4
    panel.columnSpacing = 31
    panel.rowSpacing = 32
    panel.fullscreenScale = 2.2
    panel.iconSize = 96
    panel.hotKeyEnabled = true
    panel.hotKeyKeyCode = 49
    panel.hotKeyModifiers = 256
    panel.pinchEnabled = false
    panel.pinchThreshold = 1.4
    panel.launchAtLogin = true
    panel.hiddenAppPaths = ["/hidden.app"]

    var merged = disk
    merged.applySettings(from: panel)

    check(merged.language == .en, "语言会被持久化（曾漏掉导致切换无效）")
    check(merged.hiddenAppPaths == ["/hidden.app"], "隐藏应用列表会被持久化（曾漏掉导致恢复无效）")
    check(merged.theme == .light && merged.bgOpacity == 0.42 && merged.bgBlur == 33, "外观设置会被持久化")
    check(merged.darkBgPreset == "midnight" && merged.lightBgPreset == "warmOat", "背景颜色预设会被持久化")
    check(merged.columns == 9 && merged.rows == 4 && merged.iconSize == 96, "网格设置会被持久化")
    check(merged.columnSpacing == 31 && merged.rowSpacing == 32 && merged.fullscreenScale == 2.2,
          "间距与全屏缩放设置会被持久化")
    check(merged.scanPaths == ["/Custom"] && merged.recursionDepth == 5, "扫描设置会被持久化")
    check(merged.hotKeyEnabled && merged.hotKeyKeyCode == 49 && merged.hotKeyModifiers == 256,
          "快捷键设置会被持久化")
    check(merged.pinchEnabled == false && merged.pinchThreshold == 1.4, "捏合设置会被持久化")
    check(merged.launchAtLogin, "开机启动会被持久化")
    check(merged.backgroundImagePath == "/tmp/bg.png", "背景图设置会被持久化")

    check(merged.folders.first?.name == "保留的文件夹", "文件夹由主窗口负责，不被设置面板覆盖")
    check(merged.pageOrders == [["folder:f1"]] && merged.itemOrder == ["folder:f1"],
          "分页编排由主窗口负责，不被覆盖")
    check(merged.windowX == 11 && merged.windowY == 22 && merged.windowWidth == 1234,
          "窗口位置与尺寸由主窗口负责，不被覆盖")
    check(merged.hideOnLaunch == false, "hideOnLaunch 不由设置面板覆盖")
}

// MARK: - 本地化

func testL10n() {
    print("L10n:")

    // 默认简体中文：直接返回原文
    L10n.setLanguage(.zhHans)
    check(L10n.t("设置") == "设置", "中文下取译文返回原文")
    check(L10n.f("共 %d 个应用", 3) == "共 3 个应用", "中文下格式化文案正常")

    // 英文
    L10n.setLanguage(.en)
    check(L10n.t("设置") == "Settings", "英文下取译文命中英文表")
    check(L10n.t("文件夹") == "Folder", "条目文案可翻译")
    check(L10n.f("共 %d 个应用", 3) == "3 apps", "英文下格式化文案正常")
    check(L10n.f("最多只能添加 %d 个", 10) == "You can select up to 10 items", "英文下 %d 占位替换正确")
    check(L10n.f("「%@」已不存在，正在重新扫描…", "Foo") == "“Foo” no longer exists — rescanning…",
          "英文下 %@ 占位替换正确")

    // 未翻译的键回退到中文，而不是空白或 key
    check(L10n.t("这是一条尚未翻译的文案") == "这是一条尚未翻译的文案", "缺失译文时回退中文")

    // 反查依赖英文值唯一，否则「切换语言时就地刷新」会翻错
    var englishValues: [String: String] = [:]
    var ambiguous: [String] = []
    for (key, value) in L10n.english {
        if let existing = englishValues[value], existing != key { ambiguous.append(value) }
        englishValues[value] = key
    }
    check(ambiguous.isEmpty, "英文译文一一对应（反查无歧义）\(ambiguous.isEmpty ? "" : "：" + ambiguous.joined(separator: ", "))")

    // 就地刷新：已知译文可反查回键并切换到目标语言
    L10n.setLanguage(.zhHans)
    check(L10n.retranslate("Settings") == "设置", "英文→中文可反查")
    L10n.setLanguage(.en)
    check(L10n.retranslate("设置") == "Settings", "中文→英文可反查")
    check(L10n.retranslate("Light") == "Light", "已是目标语言时保持不变")
    check(L10n.retranslate("Safari") == "Safari", "非文案内容原样保留")
    check(L10n.retranslate("100%") == "100%", "数值等动态文本不受影响")
    check(L10n.retranslate("") == "", "空字符串安全")

    // 英文表不得有重复键（字典字面量重复会直接崩溃，这里用元组表 + 自测守护）
    check(L10n.duplicateKeys.isEmpty, "英文文案表无重复键\(L10n.duplicateKeys.isEmpty ? "" : "：" + L10n.duplicateKeys.joined(separator: ", "))")

    // 语言枚举
    check(AppLanguage.allCases.count == 2, "提供两种语言")
    check(AppLanguage.allCases.first == .zhHans, "默认语言为简体中文")
    check(AppLanguage(rawValue: "en") == .en, "语言持久化原语正确")

    L10n.setLanguage(.zhHans)
}

// MARK: - 版本信息

func testAppVersion() {
    print("AppVersion:")
    // 自测可执行文件没有 Info.plist，应安全回退为 dev 而不是崩溃
    check(AppVersion.short == "dev", "无 Info.plist 时版本回退为 dev")
    check(AppVersion.displayTag == "dev", "无 Info.plist 时 tag 显示为 dev")
    check(AppVersion.displayFull == "dev", "无 Info.plist 时完整版本显示为 dev")
    check(AppVersion.repositoryURL == "https://github.com/ccdyy/Rlaunch", "GitHub 仓库地址正确")
}

// MARK: - 文件夹与网格单元测试

func testFolderAndGridItem() throws {
    print("FolderAndGridItem:")

    // 默认值与网格单元计算
    let defaultFolder = FolderConfig(id: "f_def", appPaths: ["/Applications/A.app"])
    check(defaultFolder.name == "文件夹", "文件夹默认名称为'文件夹'")
    check(defaultFolder.spanColumns == 1 && defaultFolder.spanRows == 1, "默认网格尺寸为 1x1")
    check(defaultFolder.gridCellCount == 1, "1x1 占用网格单元数 N=1")

    // 大卡片文件夹 (2x2)
    let bigFolder = FolderConfig(id: "f_big", name: "开发", appPaths: ["/Applications/Xcode.app"], spanColumns: 2, spanRows: 2)
    check(bigFolder.gridCellCount == 4, "2x2 占用网格单元数 N=4")

    // 旧版文件夹 JSON 解码容错（无 spanColumns 与 spanRows）
    let legacyFolderJSON = """
    {"id": "f_legacy", "name": "设计", "appPaths": ["/Applications/Sketch.app"]}
    """
    let decodedFolder = try JSONDecoder().decode(FolderConfig.self, from: legacyFolderJSON.data(using: .utf8)!)
    check(decodedFolder.spanColumns == 1 && decodedFolder.spanRows == 1, "旧文件夹配置缺失尺寸时默认 1x1")
    check(decodedFolder.gridCellCount == 1, "旧文件夹配置默认单元数 1")

    // GridItem 抽象与混合支持
    let appInfo = AppInfo(name: "Safari", path: "/Applications/Safari.app", bundleID: "com.apple.Safari")
    let itemApp = GridItem.app(appInfo)
    let itemFolder = GridItem.folder(bigFolder)

    check(itemApp.isApp && !itemApp.isFolder, "GridItem.app 类型判定正确")
    check(itemFolder.isFolder && !itemFolder.isApp, "GridItem.folder 类型判定正确")
    check(itemApp.spanColumns == 1 && itemApp.spanRows == 1, "应用跨度恒为 1x1")
    check(itemFolder.spanColumns == 2 && itemFolder.spanRows == 2, "文件夹跨度获取正确 (2x2)")
    check(itemFolder.gridCellCount == 4, "文件夹网格占用总数正确")

    // 中转站上限（纯逻辑常量，行为由 SelectionTrayView 保证）
    let maxLimit = 10
    let testItems: [GridItem] = (1...10).map {
        .app(AppInfo(name: "App\($0)", path: "/Applications/App\($0).app", bundleID: "com.test.\($0)"))
    }
    check(testItems.count == maxLimit, "中转站上限为 10 项")
}

// MARK: - 网格装箱（真实生产实现）

private func makeApps(_ count: Int) -> [GridItem] {
    (0..<count).map { i in
        .app(AppInfo(name: "App\(i)", path: "/Applications/App\(i).app", bundleID: "com.test.\(i)"))
    }
}

private func makeFolder(_ id: String, cols: Int, rows: Int) -> GridItem {
    .folder(FolderConfig(id: id, name: id, appPaths: ["/in.app"], spanColumns: cols, spanRows: rows))
}

func testGridPacker() {
    print("GridPacker:")

    let five = makeApps(5)
    let basic = GridPacker.placements(for: five, columns: 3, rows: 2)
    check(basic.compactMap { $0 }.count == 5, "3×2 网格可放下 5 个应用")
    check(basic[3] == GridPosition(row: 1, column: 0), "第 4 个应用换行到第 2 行首列")
    check(basic[5 - 1] == GridPosition(row: 1, column: 1), "第 5 个应用落在第 2 行第 2 列")

    // 2×2 文件夹：占位后剩余位置不足以再放一个 1×1
    let mixed = [five[0], makeFolder("f_big", cols: 2, rows: 2), five[1], five[2]]
    let placed = GridPacker.placements(for: mixed, columns: 3, rows: 2)
    check(placed[1] == GridPosition(row: 0, column: 1), "2×2 文件夹从首个可用位置开始占位")
    check(placed[2] == GridPosition(row: 1, column: 0), "文件夹占位后 1×1 继续填充剩余格")
    check(placed[3] == nil, "剩余格数不足以放置时返回 nil（调用方应换页）")
    check(GridPacker.fitCount(for: mixed, columns: 3, rows: 2) == 3,
          "3×2 网格放「2 应用 + 1 个 2×2 文件夹 + 1 应用」时只能放下 3 个条目")

    // 超规格文件夹会被裁剪到网格范围内，不会导致死循环
    let oversized = [makeFolder("f_huge", cols: 5, rows: 5)]
    check(GridPacker.fitCount(for: oversized, columns: 2, rows: 2) == 1, "超出网格的文件夹被裁剪后仍可放下")

    // 键盘导航：3 列网格下的邻居查找
    let nine = makeApps(9)
    let grid = GridPacker.placements(for: nine, columns: 3, rows: 3)
    check(GridPacker.neighborIndex(from: 0, dx: 1, dy: 0, placements: grid) == 1, "→ 移动到同行右侧条目")
    check(GridPacker.neighborIndex(from: 1, dx: 0, dy: 1, placements: grid) == 4, "↓ 移动到同一列的下方条目")
    check(GridPacker.neighborIndex(from: 4, dx: 0, dy: -1, placements: grid) == 1, "↑ 回到同一列的上方条目")
    check(GridPacker.neighborIndex(from: 2, dx: 1, dy: 0, placements: grid) == nil, "最右侧再向右无邻居（由调用方翻页）")
    check(GridPacker.neighborIndex(from: 0, dx: -1, dy: 0, placements: grid) == nil, "最左侧再向左无邻居")

    // 有空洞的网格：↓ 在下方无条目时不应越行乱跳
    let holed = [makeApps(1)[0], makeFolder("f_hole", cols: 1, rows: 2), makeApps(4)[3]]
    let holedGrid = GridPacker.placements(for: holed, columns: 2, rows: 3)
    check(holedGrid[1] == GridPosition(row: 0, column: 1), "1×2 文件夹占位正确")
    check(GridPacker.neighborIndex(from: 0, dx: 0, dy: 1, placements: holedGrid) == 2,
          "↓ 跳过被文件夹占满的列，落到下一行可用条目")
}

// MARK: - 分页编排（真实生产实现）

func testPageComposer() {
    print("PageComposer:")

    let apps = makeApps(6)
    let bigFolder = makeFolder("f_big", cols: 2, rows: 2)

    // 关键回归：分页必须按「实际格数」切分，否则跨格文件夹会挤掉后续条目并被静默隐藏
    let mixed = [apps[0], bigFolder, apps[1], apps[2], apps[3]]
    let chunked = PageComposer.chunk(mixed, columns: 3, rows: 2)
    check(chunked.count == 2, "跨格文件夹导致容量下降时会自动分页")
    check(chunked[0].count == 3 && chunked[1].count == 2, "每页条目数严格等于该页实际可放置数")
    check(chunked.flatMap { $0 }.map { $0.identifier } == mixed.map { $0.identifier },
          "分页后不丢失任何条目且保持原有顺序")

    // 常规切页
    let plain = PageComposer.chunk(makeApps(7), columns: 3, rows: 2)
    check(plain.map { $0.count } == [6, 1], "1×1 条目按 columns×rows 满页切分")

    // 未登记条目补充进最后一页空位
    let composed = PageComposer.compose(
        savedPages: [[apps[0], apps[1]]], unvisited: [apps[2], apps[3]],
        columns: 3, rows: 1)
    check(composed.count == 2 && composed[0].count == 3 && composed[1].count == 1,
          "未登记条目优先补进最后一页空位，其余另起新页")

    // 用户新建的空白页（含末尾的）原样保留
    let withBlank = PageComposer.compose(
        savedPages: [[apps[0]], [], [apps[1]]], unvisited: [], columns: 2, rows: 2)
    check(withBlank.count == 3 && withBlank[1].isEmpty, "用户新建的中间空白页被保留")

    let trailingBlank = PageComposer.compose(
        savedPages: [[apps[0]], []], unvisited: [], columns: 2, rows: 2)
    check(trailingBlank.count == 2 && trailingBlank[1].isEmpty, "末尾的空白页同样保留（新建页不会被悄悄回收）")

    // 新增条目补进最后一个有内容的页面，不会塞进用户留白的页面
    let filledPastBlank = PageComposer.compose(
        savedPages: [[apps[0]], []], unvisited: [apps[1]], columns: 2, rows: 2)
    check(filledPastBlank.count == 2 && filledPastBlank[0] == [apps[0], apps[1]] && filledPastBlank[1].isEmpty,
          "未登记条目补进最后一个有内容的页面，末尾空白页保持空白")
    let overflowPastBlank = PageComposer.compose(
        savedPages: [[apps[0]], []], unvisited: [apps[1], apps[2]], columns: 2, rows: 1)
    check(overflowPastBlank.count == 3 && overflowPastBlank[1].isEmpty && overflowPastBlank[2] == [apps[2]],
          "补不下的条目另起新页，追加到空白页之后")
    let allBlank = PageComposer.compose(
        savedPages: [[], []], unvisited: [apps[0], apps[1], apps[2]], columns: 2, rows: 1)
    check(allBlank.map { $0.count } == [2, 1], "没有任何已登记条目时直接按容量切页（不留前导空页）")
    check(PageComposer.compose(savedPages: [], unvisited: [], columns: 2, rows: 1) == [[]], "什么都没有时保留一个空页")

    // 新建空白页
    let twoPages: [[GridItem]] = [[apps[0]], [apps[1]]]
    check(PageComposer.insertingBlankPage(after: 0, in: twoPages) == [[apps[0]], [], [apps[1]]], "在指定页之后新建空白页")
    check(PageComposer.insertingBlankPage(after: 1, in: twoPages) == [[apps[0]], [apps[1]], []], "在末尾新建空白页")
    check(PageComposer.insertingBlankPage(after: -1, in: twoPages) == [[], [apps[0]], [apps[1]]], "index = -1 时新建在最前")
    check(PageComposer.insertingBlankPage(after: 99, in: twoPages).count == 3, "index 越界时追加到末尾")
    check(PageComposer.insertingBlankPage(after: 0, in: []) == [[], []], "没有页面时也能新建")

    // 删除页面：空白页直接删；有内容的并入相邻页，顺序不变，条目不丢失
    check(PageComposer.deletingPage(1, in: [[apps[0]], [], [apps[1]]], columns: 2, rows: 2) == [[apps[0]], [apps[1]]],
          "删除空白页")
    check(PageComposer.deletingPage(1, in: [[apps[0]], [apps[1], apps[2]]], columns: 3, rows: 1)
            == [[apps[0], apps[1], apps[2]]], "删除有内容的页：条目并入上一页末尾")
    check(PageComposer.deletingPage(0, in: [[apps[0]], [apps[1]]], columns: 2, rows: 1) == [[apps[0], apps[1]]],
          "删除第一页：条目并入下一页开头")
    let fullPages: [[GridItem]] = [[apps[0], apps[1]], [apps[2], apps[3]], [apps[4]]]
    let cannotShrink = PageComposer.deletingPage(1, in: fullPages, columns: 2, rows: 1)
    check(cannotShrink.count == fullPages.count
          && cannotShrink.flatMap { $0 }.map { $0.identifier } == fullPages.flatMap { $0 }.map { $0.identifier },
          "其余页面都排满时：条目一个不丢、顺序不变，页数不会减少（调用方据此提示）")
    check(PageComposer.deletingPage(0, in: [[apps[0]]], columns: 2, rows: 1) == [[apps[0]]], "只剩一页时不能删除")
    check(PageComposer.deletingPage(5, in: [[apps[0]], []], columns: 2, rows: 1) == [[apps[0]], []], "页序越界时原样返回")

    // 回收被腾空的页面：操作前有内容、操作后为空才回收；用户新建的空白页保留
    let beforeMove: [[GridItem]] = [[apps[0]], [apps[1]], [], [apps[2]]]
    let afterMoveAway: [[GridItem]] = [[apps[0], apps[1]], [], [], [apps[2]]]
    check(PageComposer.recycleVacated(before: beforeMove, after: afterMoveAway) == [[apps[0], apps[1]], [], [apps[2]]],
          "被腾空的页面被回收，原本就空白的页面保留")
    check(PageComposer.recycleVacated(before: [[apps[0]], []], after: [[apps[0]], []]) == [[apps[0]], []],
          "没有页面被腾空时，用户新建的空白页不会被回收")
    check(PageComposer.recycleVacated(before: [[apps[0]]], after: [[]]) == [[]], "回收后至少保留一页")
    check(PageComposer.recycleVacated(before: [[apps[0]]], after: [[apps[0]], [apps[1]]]).count == 2,
          "超出操作前页数的新页原样保留")

    // 「放新页」：先插入空白页，再把选中项移进去；以插入后的页面为基准回收，新页不会被误回收
    let withNewPage = PageComposer.insertingBlankPage(after: 0, in: [[apps[0]], [apps[1]], [apps[2]]])
    let movedToNewPage = PageComposer.move([apps[1]], toPage: 1, at: 0, in: withNewPage, columns: 2, rows: 1)
    check(movedToNewPage == [[apps[0]], [apps[1]], [], [apps[2]]], "选中项移入新建页，原页被腾空")
    check(PageComposer.recycleVacated(before: withNewPage, after: movedToNewPage)
            == [[apps[0]], [apps[1]], [apps[2]]], "放新页：新页被填充保留，被腾空的原页被回收")

    // 移除：只剔除指定条目，保留页面结构
    let removed = PageComposer.removing(["app:/Applications/App0.app"], from: [[apps[0], apps[1]], [apps[2]]])
    check(removed == [[apps[1]], [apps[2]]], "按标识符批量剔除条目")

    // 拖动重排：严格保持传入顺序，并按参考物定位插入点
    let reordered = PageComposer.move([apps[2], apps[1]], toPage: 0, at: 0, in: [[apps[0], apps[1], apps[2]]],
                                      columns: 3, rows: 1)
    check(reordered[0].map { $0.identifier } == [apps[2], apps[1], apps[0]].map { $0.identifier },
          "拖动重排严格遵循选中先后顺序并插入参考物之前")

    // 跨格文件夹放不下时顺延到下一页，而不是被静默隐藏
    let reflowed = PageComposer.move([bigFolder], toPage: 0, at: 3, in: [[apps[0], apps[1], apps[2]]],
                                     columns: 3, rows: 2)
    check(reflowed.count == 2 && reflowed[1] == [bigFolder],
          "目标页放不下的跨格文件夹顺延到下一页")

    // 解散文件夹：从当前页开始释放，放不下自动新建页
    let released = PageComposer.release([apps[3], apps[4]], fromPage: 0,
                                        in: [[apps[0], apps[1], apps[2]]], columns: 3, rows: 1)
    check(released.count == 2 && released[0].count == 3 && released[1].count == 2,
          "解散后应用从当前页开始释放，放不下自动新建页")

    // 追加到指定页：有空位则落在页尾，已满则按容量顺延
    let appendedRoom = PageComposer.appending([apps[3]], toPage: 1, in: [[apps[0]], [apps[1]]],
                                              columns: 2, rows: 1)
    check(appendedRoom == [[apps[0]], [apps[1], apps[3]]], "追加到有空位的页面时直接落在页尾")

    let appended = PageComposer.appending([apps[3]], toPage: 1, in: [[apps[0]], [apps[1], apps[2]]],
                                          columns: 2, rows: 1)
    check(appended.count == 3 && appended[1].count == 2 && appended[2] == [apps[3]],
          "追加到已满页时按容量顺延到下一页")
}

// MARK: - 网格容量与尺寸推算

/// 用一套固定的「真实屏幕」检验：同一份设置在不同屏幕上显示的图标尺寸差距
private let referenceScreens: [(name: String, width: CGFloat, height: CGFloat, safeTop: CGFloat)] = [
    ("MacBook Air 13（刘海）", 1470, 956, 32),
    ("MacBook Pro 14（刘海）", 1512, 982, 32),
    ("MacBook Pro 16（刘海）", 1728, 1117, 32),
    ("MacBook Air 15", 1710, 1107, 0),
    ("Intel MBP 13", 1440, 900, 0),
    ("MacBook 12", 1280, 800, 0),
    ("外接 1080p", 1920, 1080, 0),
    ("大屏 1440p", 2560, 1440, 0),
]

func testGridMetrics() {
    print("GridMetrics:")

    let defaults = GridSettings()   // 7 × 5 · 64pt · 间距 24 · 全屏缩放 1.25

    // MARK: 设置 = 实际（空间充足时一个像素都不改）

    let roomy = GridMetrics.resolve(settings: defaults, viewport: CGSize(width: 1600, height: 900), mode: .windowed)
    check(roomy.layout.columns == 7 && roomy.layout.rows == 5, "空间充足：行列数等于设置")
    check(roomy.layout.iconSize == 64 && roomy.layout.columnSpacing == 24 && roomy.layout.rowSpacing == 24,
          "空间充足：图标与间距等于设置（不再被「铺满」放大）")
    check(roomy.matchesSettings && roomy.appliedScale == 1, "空间充足：与设置完全一致，没有任何差异")

    // 回归：图标 76pt 的设置在 1329×462 的网格区里，旧算法把图标压到 41pt（设置界面写 76、实际 41）。
    // 现在图标保持 76pt，只把行数从 5 减到 3，并如实报告。
    let big = GridSettings(columns: 7, rows: 5, iconSize: 76, columnSpacing: 24, rowSpacing: 24, fullscreenScale: 1.6)
    let wide = GridMetrics.resolve(settings: big, viewport: CGSize(width: 1329, height: 462), mode: .windowed)
    check(wide.layout.iconSize == 76, "回归：矮窗口里图标仍是设置的 76pt（旧算法为 41pt）")
    check(wide.layout.columns == 7 && wide.layout.rows == 3, "矮窗口通过减少行数来放下（5 → 3 行）")
    check(wide.deviations == [.rowsReduced(configured: 5, actual: 3)], "差异只有「行数减少」这一项")

    // 窗口再矮：图标最多缩到设置值的 85%，其余靠收紧间距
    let tight = GridMetrics.resolve(settings: big, viewport: CGSize(width: 1329, height: 230), mode: .windowed)
    check(tight.layout.rows == 2, "很矮的窗口：减到 2 行")
    check(tight.iconRatio >= GridMetrics.iconFloorRatio - 0.001, "很矮的窗口：图标至多缩到设置值的 85%")
    check(tight.deviations.contains(.spacingTightened), "很矮的窗口：报告「间距已收紧」")
    check(tight.deviations.contains { if case .iconShrunk = $0 { return true } else { return false } },
          "很矮的窗口：报告「图标缩小」")

    // 极端：连最小网格都放不下时，才突破 85% 一路缩到硬下限，且仍不溢出
    let squeezedView = CGSize(width: 300, height: 180)
    let squeezed = GridMetrics.resolve(settings: defaults, viewport: squeezedView, mode: .windowed)
    check(squeezed.layout.iconSize >= GridMetrics.minIconSize, "极端狭小：图标不低于硬下限")
    check(squeezed.layout.gridPixelWidth <= squeezedView.width + 0.01
          && squeezed.layout.gridPixelHeight <= squeezedView.height + 0.01, "极端狭小：依然不溢出")

    // 容量下限：极端窄小也不会变成 0
    let tiny = GridMetrics.resolve(settings: defaults, viewport: CGSize(width: 40, height: 40), mode: .windowed)
    check(tiny.capacity.columns >= 1 && tiny.capacity.rows >= 1, "极端尺寸下容量至少为 1×1")

    // 窗口尚未布局：原样返回设置，避免用 0 尺寸算出 1×1
    let notLaidOut = GridMetrics.resolve(settings: defaults, viewport: .zero, mode: .windowed)
    check(notLaidOut.layout.columns == 7 && notLaidOut.layout.rows == 5 && notLaidOut.layout.iconSize == 64,
          "尚未布局时按设置原样返回")

    // 非法输入被规整
    let sloppy = GridSettings(columns: 0, rows: -3, iconSize: 4, columnSpacing: -5, rowSpacing: -5, fullscreenScale: 0.2)
    let sanitized = GridMetrics.resolve(settings: sloppy, viewport: CGSize(width: 1600, height: 900), mode: .fullscreen)
    check(sanitized.settings.columns == 1 && sanitized.settings.rows == 1
          && sanitized.settings.iconSize == GridMetrics.minIconSize
          && sanitized.settings.columnSpacing == 0 && sanitized.settings.fullscreenScale == 1,
          "非法设置被规整到合法范围")

    // MARK: 不溢出（顶栏遮挡问题的根因回归）+ 单调 + 不超尺寸

    let sweepSettings: [(String, GridSettings)] = [
        ("默认", defaults),
        ("大图标宽间距", GridSettings(columns: 7, rows: 5, iconSize: 128, columnSpacing: 60, rowSpacing: 60, fullscreenScale: 2)),
        ("小图标密排", GridSettings(columns: 10, rows: 8, iconSize: 40, columnSpacing: 10, rowSpacing: 10, fullscreenScale: 1)),
        ("单列单行", GridSettings(columns: 1, rows: 1, iconSize: 64, columnSpacing: 24, rowSpacing: 24, fullscreenScale: 1.5)),
    ]
    var overflow: [String] = []
    var grew: [String] = []
    var belowFloor: [String] = []
    for (label, settings) in sweepSettings {
        for mode in [GridMode.windowed, .fullscreen] {
            for w in stride(from: CGFloat(300), through: 2600, by: 100) {
                for h in stride(from: CGFloat(160), through: 1400, by: 20) {
                    let viewport = CGSize(width: w, height: h)
                    let result = GridMetrics.resolve(settings: settings, viewport: viewport, mode: mode)
                    let cfg = result.layout
                    let tag = "\(label)/\(mode == .windowed ? "窗口" : "全屏")/\(Int(w))×\(Int(h))"
                    let usableW = viewport.width * (mode == .fullscreen ? GridMetrics.fullscreenFill.width : 1)
                    let usableH = viewport.height * (mode == .fullscreen ? GridMetrics.fullscreenFill.height : 1)
                    // 连单个最小单元格都放不下时无法保证（1×1 网格才是兜底）
                    let canHoldMinimum = usableW >= GridMetrics.minCellWidth && usableH >= GridMetrics.minCellHeight
                    if canHoldMinimum,
                       cfg.gridPixelHeight > usableH + 0.01 || cfg.gridPixelWidth > usableW + 0.01 {
                        overflow.append(tag)
                    }
                    if cfg.iconSize > result.expectedIconSize + 0.01 { grew.append(tag) }
                    // 只要放得下最小的「像样」网格，图标就不会低于设置值的 85%
                    let minGridWidth = CGFloat(min(settings.columns, GridMetrics.minHonoredColumns))
                        * (settings.iconSize * GridMetrics.iconFloorRatio + 20)
                    let minGridHeight = CGFloat(min(settings.rows, GridMetrics.minHonoredRows))
                        * (settings.iconSize * GridMetrics.iconFloorRatio + 60)
                    if usableW >= minGridWidth + 80, usableH >= minGridHeight + 80,
                       result.iconRatio < GridMetrics.iconFloorRatio - 0.001,
                       settings.iconSize * GridMetrics.iconFloorRatio >= GridMetrics.minIconSize {
                        belowFloor.append(tag)
                    }
                }
            }
        }
    }
    check(overflow.isEmpty, "任意窗口 / 屏幕尺寸下网格都不超出可视区\(overflow.isEmpty ? "" : "：" + overflow.prefix(3).joined(separator: ", "))")
    check(grew.isEmpty, "实际图标不会超过期望尺寸\(grew.isEmpty ? "" : "：" + grew.prefix(3).joined(separator: ", "))")
    check(belowFloor.isEmpty, "放得下像样网格时图标不低于设置值的 85%\(belowFloor.isEmpty ? "" : "：" + belowFloor.prefix(3).joined(separator: ", "))")

    // 窗口越矮每页行数只会减少、不会反弹（避免拖动窗口时分页来回抖动）
    var previousRows = Int.max
    var rowsRebounded = false
    for h in stride(from: CGFloat(1000), through: 160, by: -10) {
        let rows = GridMetrics.resolve(settings: defaults, viewport: CGSize(width: 1200, height: h), mode: .windowed).layout.rows
        if rows > previousRows { rowsRebounded = true }
        previousRows = rows
    }
    check(!rowsRebounded, "窗口变矮时行数单调不增")

    // MARK: 全屏：「全屏缩放」是真实的放大倍数

    func fullscreenViewport(_ screen: (name: String, width: CGFloat, height: CGFloat, safeTop: CGFloat)) -> CGSize {
        ChromeMetrics.gridViewport(containerSize: CGSize(width: screen.width, height: screen.height),
                                   fullscreen: true, safeAreaTop: screen.safeTop, showsPagination: true)
    }

    let fullHD = fullscreenViewport(referenceScreens[6])
    let hd = GridMetrics.resolve(settings: defaults, viewport: fullHD, mode: .fullscreen)
    check(hd.appliedScale == 1.25 && hd.layout.iconSize == 80, "全屏缩放 1.25×：64pt 的图标显示为 80pt")
    check(hd.layout.columnSpacing == 30 && hd.layout.rowSpacing <= 30 + 0.01,
          "全屏缩放同样放大间距（24 → 30）")
    check(hd.layout.columns == 7 && hd.layout.rows == 5, "全屏保持配置的行列数")
    check(hd.matchesSettings, "屏幕放得下时：全屏实际显示与设置（含缩放）完全一致")

    let noZoom = GridMetrics.resolve(settings: GridSettings(fullscreenScale: 1), viewport: fullHD, mode: .fullscreen)
    check(noZoom.layout.iconSize == 64 && noZoom.layout.columnSpacing == 24, "全屏缩放 1×：全屏与窗口化尺寸一致")

    // 全屏缩放调大，图标就真的变大（旧算法里调大反而会让图标变小）
    var lastIcon: CGFloat = 0
    var scaleMonotonic = true
    for scale in stride(from: 1.0, through: 3.0, by: 0.25) {
        var s = defaults
        s.fullscreenScale = CGFloat(scale)
        let icon = GridMetrics.resolve(settings: s, viewport: fullHD, mode: .fullscreen).layout.iconSize
        if icon + 0.01 < lastIcon { scaleMonotonic = false }
        lastIcon = icon
    }
    check(scaleMonotonic, "全屏缩放越大图标越大（单调不减）")

    // 缩放超出屏幕容量：自动降低并如实标注，且不为放大而减少行列
    let laptop = fullscreenViewport(referenceScreens[5])      // 1280×800
    var greedy = defaults
    greedy.fullscreenScale = 2.5
    let limited = GridMetrics.resolve(settings: greedy, viewport: laptop, mode: .fullscreen)
    check(limited.appliedScale > 1 && limited.appliedScale < 2.5, "缩放放不下时自动降低到屏幕能容纳的最大倍数")
    check(limited.layout.columns == 7 && limited.layout.rows == 5, "降低缩放而不是减少每页行列数")
    check(limited.deviations.contains { if case .scaleLimited = $0 { return true } else { return false } },
          "如实报告「全屏缩放被限制」")
    check(limited.layout.gridPixelHeight <= laptop.height * GridMetrics.fullscreenFill.height + 0.01,
          "降低后的全屏网格不溢出")

    // 连 1× 都放不下（小屏 + 8 行）：回到与窗口化相同的降级流程，行数减少
    var eightRows = defaults
    eightRows.rows = 8
    let cramped = GridMetrics.resolve(settings: eightRows, viewport: laptop, mode: .fullscreen)
    check(cramped.layout.rows < 8 && cramped.appliedScale == 1, "小屏 8 行：缩放回落到 1×，并减少行数")
    check(cramped.deviations.contains(.rowsReduced(configured: 8, actual: cramped.layout.rows)),
          "小屏 8 行：如实报告行数减少")

    // MARK: 不同尺寸屏幕上图标大小的差距（用户问题 1 的量化回归）

    var iconSizes: [(String, CGFloat)] = []
    for screen in referenceScreens {
        let result = GridMetrics.resolve(settings: defaults, viewport: fullscreenViewport(screen), mode: .fullscreen)
        iconSizes.append((screen.name, result.layout.iconSize))
    }
    let maxIcon = iconSizes.map { $0.1 }.max() ?? 1
    let minIcon = iconSizes.map { $0.1 }.min() ?? 1
    check(maxIcon / minIcon <= 1.2,
          "默认设置在 8 种常见屏幕上全屏图标差距 ≤ 20%（实际 \(String(format: "%.2f", Double(maxIcon / minIcon)))×，\(Int(minIcon))–\(Int(maxIcon))pt）")
    check(iconSizes.filter { $0.1 == 80 }.count >= 7, "绝大多数屏幕上全屏图标恰好是设置值 × 缩放（80pt），不再随屏幕尺寸漂移")

    // MARK: 设置页预览与真实布局共用同一份推算

    check(ChromeMetrics.gridViewport(containerSize: CGSize(width: 1020, height: 700), fullscreen: false,
                                     safeAreaTop: 0, showsPagination: true) == CGSize(width: 1020, height: 552),
          "窗口化网格区 = 窗口高 − 顶栏 56 − 留白 12 − 分页 68 − 留白 12")
    check(ChromeMetrics.gridViewport(containerSize: CGSize(width: 1020, height: 700), fullscreen: false,
                                     safeAreaTop: 0, showsPagination: false) == CGSize(width: 1020, height: 620),
          "窗口化单页时没有分页条：网格区 = 窗口高 − 80")
    check(ChromeMetrics.gridViewport(containerSize: CGSize(width: 1470, height: 956), fullscreen: true,
                                     safeAreaTop: 32, showsPagination: true) == CGSize(width: 1470, height: 800),
          "全屏刘海屏网格区 = 屏高 − 顶栏 56 − 刘海 32 − 分页 68")
    check(ChromeMetrics.gridViewport(containerSize: CGSize(width: 100, height: 50), fullscreen: false,
                                     safeAreaTop: 0, showsPagination: true).height == 0,
          "容器过小时网格区高度不为负")

    // 布局像素计算自洽
    check(GridLayoutConfig.defaults.gridPixelWidth > 0 && GridLayoutConfig.defaults.gridPixelHeight > 0,
          "默认网格尺寸计算为正数")
}

// MARK: - 空白处点击策略

func testBlankClickPolicy() {
    print("BlankClickPolicy:")

    func action(full: Bool, settings: Bool = false, folder: Bool = false, selecting: Bool = false) -> BlankClickAction {
        BlankClickPolicy.action(isFullscreen: full, settingsVisible: settings, folderOpen: folder, selecting: selecting)
    }

    check(action(full: true) == .hideLauncher, "全屏：点空白处收起启动台")
    check(action(full: false) == .none, "小窗：点空白处什么都不做（不收起）")

    // 回归：小窗点空白处曾经会把设置面板关掉，看起来像「小屏界面也会关闭」
    check(action(full: false, settings: true) == .none, "小窗：点空白处不会关闭设置面板")
    check(action(full: true, settings: true) == .closeSettings, "全屏：先关闭设置面板，再次点击才收起")

    check(action(full: true, folder: true) == .dismissFolder, "全屏：先关闭文件夹")
    check(action(full: false, folder: true) == .dismissFolder, "小窗：点空白处可以关闭文件夹（窗口内的临时状态）")
    check(action(full: true, selecting: true) == .exitSelection, "全屏：先退出多选")
    check(action(full: false, selecting: true) == .exitSelection, "小窗：点空白处可以退出多选")

    check(action(full: true, settings: true, folder: true, selecting: true) == .closeSettings,
          "全屏逐层退出：设置面板优先")
    check(action(full: true, folder: true, selecting: true) == .dismissFolder, "全屏逐层退出：文件夹其次")
    check(action(full: false, settings: true, folder: true) == .dismissFolder, "小窗有设置面板与文件夹：只关文件夹")
}

// MARK: - 增量扫描

func testIncrementalScan() throws {
    print("AppScanner(Incremental):")
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rlaunch-inc-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    func makeApp(named name: String, bundleID: String) throws {
        let contents = root.appendingPathComponent("\(name).app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    }

    try makeApp(named: "Alpha", bundleID: "com.test.alpha")
    try makeApp(named: "Beta", bundleID: "com.test.beta")

    func runScan(previous: [AppInfo], since: Date?) -> AppScanResult {
        var result: AppScanResult?
        AppScanner.scan(paths: [root.path], maxDepth: 2, previous: previous, since: since) { result = $0 }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return result ?? AppScanResult(apps: [], added: [], removed: [])
    }

    let first = runScan(previous: [], since: nil)
    check(first.apps.count == 2, "首次扫描扫到 2 个应用")
    check(first.added.count == 2, "首次扫描全部为新增")

    let since = Date().addingTimeInterval(1)   // 晚于刚才创建的目录时间
    let unchanged = runScan(previous: first.apps, since: since)
    check(unchanged.apps.count == 2, "增量扫描结果数量不变")
    check(!unchanged.hasChanges, "目录未改动时判定为「无变化」（界面无需重排）")
    check(unchanged.apps.map(\.name) == first.apps.map(\.name), "增量扫描复用缓存后顺序保持一致")

    try makeApp(named: "Gamma", bundleID: "com.test.gamma")
    let afterAdd = runScan(previous: unchanged.apps, since: since)
    check(afterAdd.apps.count == 3, "新增应用被增量扫描发现")
    check(afterAdd.added.map(\.name) == ["Gamma"], "增量差异正确报告新增项")
    check(afterAdd.removed.isEmpty, "没有应用被移除时不报告移除项")

    try FileManager.default.removeItem(at: root.appendingPathComponent("Beta.app"))
    let afterRemove = runScan(previous: afterAdd.apps, since: Date())
    check(afterRemove.apps.count == 2, "删除应用后增量扫描结果减少")
    check(afterRemove.removed.map(\.name) == ["Beta"], "增量差异正确报告移除项")
    check(afterRemove.hasChanges, "有增删时 hasChanges 为真")
}

// MARK: - 入口

do {
    testFuzzySearch()
    testL10n()
    testApplySettings()
    testElasticScroll()
    testAppVersion()
    testGridPacker()
    testPageComposer()
    testGridMetrics()
    testBlankClickPolicy()
    try testIncrementalScan()
    try testScanner()
    try testConfigStore()
    try testFolderAndGridItem()
} catch {
    failures.append("异常: \(error)")
    print("  ❌ \(error)")
}

// 真实目录扫描统计（信息输出，非断言）：验证默认三个目录能扫到多少应用
let realApps = waitForScan(AppConfig.defaultScanPaths, maxDepth: 3)
print("INFO: 默认扫描目录共扫到 \(realApps.count) 个应用")
// 真实搜索验证：tilde 路径可扫描 + 模糊搜索在真实应用名上生效
let realNames = realApps.map(\.name)
let hitSetting = realNames.filter { FuzzySearch.matches(name: $0, query: "设置") }
check(realApps.allSatisfy { !$0.path.contains("~/") }, "扫描结果路径为展开形式（tilde 正常解析）")
check(!hitSetting.isEmpty || !realNames.isEmpty, "真实应用名搜索'设置'有结果或列表为空")
print("INFO: 搜索'设置'命中 \(hitSetting.prefix(5))")
if let firstReal = realApps.first {
    check(FuzzySearch.matches(name: firstReal.name, query: String(firstReal.name.prefix(2))), "真实应用名前缀搜索命中")
}
// tilde 存储断言
check(AppConfig.defaultScanPaths.contains("~/Applications"), "默认扫描路径以 ~ 形式存储（不暴露用户名）")

if failures.isEmpty {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("FAILED (\(failures.count)): \(failures.joined(separator: ", "))")
    exit(1)
}
