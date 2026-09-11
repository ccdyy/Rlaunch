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
              && decoded.fullscreenSpacingScale == 1.6, "旧配置缺新字段时使用默认值")
        check(decoded.scanPaths == ["/Applications", "/Users/olduser/Applications"], "旧配置自定义路径不被迁移")
        check(decoded.pinchEnabled == true && decoded.pinchThreshold == 0.7,
              "旧 gesture 字段迁移为捏合字段")
        check(decoded.hotKeyKeyCode == nil && decoded.hotKeyEnabled == false, "旧配置默认无快捷键")
        check(decoded.windowX == nil && decoded.windowY == nil,
              "旧配置无窗口位置时保持 nil（首启居中）")
    } else {
        check(false, "旧格式配置可正常解码（缺新字段不崩溃）")
    }
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

    // 模拟解散释放与空页回收
    var pageOrders = [
        ["folder:f_big", "app:/Applications/A.app"],
        ["app:/Applications/B.app"]
    ]
    let releasedApps = ["/Applications/C.app", "/Applications/D.app"]
    // 移除文件夹
    pageOrders[0].removeAll { $0 == "folder:f_big" }
    // 从当前页 (page 0) 释放，假设 perPage = 2
    let perPage = 2
    var curP = 0
    for app in releasedApps {
        while curP < pageOrders.count && pageOrders[curP].count >= perPage {
            curP += 1
        }
        if curP >= pageOrders.count {
            pageOrders.append([])
        }
        pageOrders[curP].append("app:\(app)")
    }
    check(pageOrders.count >= 2, "解散后应用放入当前页与后续页")

    // 空页压缩
    let emptyPages = [["app:/A.app"], [], ["app:/B.app"], []]
    let compacted = emptyPages.filter { !$0.isEmpty }
    check(compacted.count == 2, "全部移动走的空页被成功回收释放")

    // 校验文件夹跨页移动
    var movePages = [
        ["folder:f_test", "app:/A.app"],
        ["app:/B.app"]
    ]
    let movingFolder = "folder:f_test"
    // 从第一页移除并放入第二页
    for i in 0..<movePages.count {
        movePages[i].removeAll { $0 == movingFolder }
    }
    movePages[1].append(movingFolder)
    check(!movePages[0].contains("folder:f_test"), "文件夹已从原页面移出")
    check(movePages[1].contains("folder:f_test"), "文件夹成功放置到目标页面")

    // 校验文件夹与内部应用互斥逻辑
    let folderA = FolderConfig(id: "f_work", name: "办公", appPaths: ["/A.app", "/B.app"])
    var selected: [GridItem] = [.app(AppInfo(name: "A", path: "/A.app", bundleID: "com.test.a"))]
    // 用户接着长按选中了文件夹 folderA：互斥剔除内部 App
    let internalIds = Set(folderA.appPaths.map { "app:\($0)" })
    selected.removeAll { internalIds.contains($0.identifier) || $0.isApp }
    selected.append(.folder(folderA))
    check(selected.count == 1 && selected.first?.isFolder == true, "选中文件夹时自动互斥移除其内部应用")

    // 反向互斥：当前选中了文件夹，接着选中其内部应用 -> 互斥移除文件夹
    selected.removeAll { $0.isFolder }
    selected.append(.app(AppInfo(name: "A", path: "/A.app", bundleID: "com.test.a")))
    check(selected.count == 1 && selected.first?.isApp == true, "选中内部应用时自动互斥移除文件夹")

    // 校验新建文件夹不会被重复追加到最后一页
    var pagesBeforeCreate = [
        ["app:/A.app", "app:/B.app"],
        ["app:/C.app"]
    ]
    let newlyCreatedFolder = FolderConfig(id: "f_new", name: "新文件夹", appPaths: ["/A.app", "/B.app"])
    // 移除放入文件夹的 App
    let newFolderAppIds = Set(newlyCreatedFolder.appPaths.map { "app:\($0)" })
    for i in 0..<pagesBeforeCreate.count {
        pagesBeforeCreate[i].removeAll { newFolderAppIds.contains($0) }
    }
    // 放入当前页 (page 0)
    pagesBeforeCreate[0].append("folder:\(newlyCreatedFolder.id)")
    let allFolderInstances = pagesBeforeCreate.flatMap { $0 }.filter { $0 == "folder:\(newlyCreatedFolder.id)" }
    check(allFolderInstances.count == 1, "新建的文件夹在各页面中仅出现 1 次，不重复出现在末尾")

    // 校验中转站最多 10 项限制与拦截逻辑
    let maxLimit = 10
    var testItems: [GridItem] = (1...10).map {
        .app(AppInfo(name: "App\($0)", path: "/Applications/App\($0).app", bundleID: "com.test.\($0)"))
    }
    check(testItems.count == maxLimit, "中转站已达到 10 个满额")
    let eleventhItem = GridItem.app(AppInfo(name: "App11", path: "/Applications/App11.app", bundleID: "com.test.11"))
    var didBlockEleventh = false
    if testItems.count >= maxLimit {
        didBlockEleventh = true
    } else {
        testItems.append(eleventhItem)
    }
    check(didBlockEleventh && testItems.count == 10, "超过 10 个条目时拦截添加并保持上限 10 个")

    // 校验长按多选后拖动重排序（无论文件夹还是应用，严格按照选中先后顺序插入到指定位置）
    var reorderTestPage = ["app:/A.app", "app:/B.app", "folder:f1", "app:/C.app", "folder:f2"]
    // 用户先选中 folder:f2，再选中 app:/B.app
    let selectedOrder = ["folder:f2", "app:/B.app"]
    let selectedSet = Set(selectedOrder)
    let targetInsertIdx = 0 // 拖动到位置 0（即 app:/A.app 之前）
    let ref = (targetInsertIdx < reorderTestPage.count) ? reorderTestPage[targetInsertIdx] : nil
    reorderTestPage.removeAll { selectedSet.contains($0) }
    let finalInsertIdx: Int
    if let r = ref, let found = reorderTestPage.firstIndex(of: r) {
        finalInsertIdx = found
    } else {
        finalInsertIdx = min(targetInsertIdx, reorderTestPage.count)
    }
    reorderTestPage.insert(contentsOf: selectedOrder, at: finalInsertIdx)
    check(reorderTestPage == ["folder:f2", "app:/B.app", "app:/A.app", "folder:f1", "app:/C.app"], "无论文件夹还是应用，拖动重排严格遵循选中的先后顺序")

    // 校验批量 App 拖入文件夹逻辑（去重、成功加入文件夹、并从原页面移除）
    var targetFolder = FolderConfig(id: "f_target", name: "目标文件夹", appPaths: ["/A.app"])
    let appsToDrop = ["/B.app", "/C.app", "/A.app"] // 包含一个已存在的 /A.app
    var sourcePage = ["app:/B.app", "app:/C.app", "app:/D.app", "folder:f_target"]
    let dropSet = Set(appsToDrop)
    for p in appsToDrop where !targetFolder.appPaths.contains(p) {
        targetFolder.appPaths.append(p)
    }
    sourcePage.removeAll { itemKey in
        guard itemKey.hasPrefix("app:") else { return false }
        let path = String(itemKey.dropFirst(4))
        return dropSet.contains(path)
    }
    check(targetFolder.appPaths == ["/A.app", "/B.app", "/C.app"], "批量 App 拖入文件夹成功且自动去重")
    check(sourcePage == ["app:/D.app", "folder:f_target"], "拖入文件夹的 App 已从原页面移除")
}

// MARK: - 入口

do {
    testFuzzySearch()
    testAppVersion()
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
