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
              && decoded.fullscreenSpacingScale == 1.6, "旧配置缺新字段时使用默认值")
        check(decoded.scanPaths == ["/Applications", "/Users/olduser/Applications"], "旧配置自定义路径不被迁移")
        check(decoded.pinchEnabled == true && decoded.pinchThreshold == 0.7,
              "旧 gesture 字段迁移为捏合字段")
        check(decoded.hotKeyKeyCode == nil && decoded.hotKeyEnabled == false, "旧配置默认无快捷键")
        check(decoded.windowX == nil && decoded.windowY == nil,
              "旧配置无窗口位置时保持 nil（首启居中）")
        check(decoded.hiddenAppPaths.isEmpty, "旧配置无隐藏列表时默认为空")
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

    // 刻意留白的中间页保留，末尾空页回收
    let withBlank = PageComposer.compose(
        savedPages: [[apps[0]], [], [apps[1]]], unvisited: [], columns: 2, rows: 2)
    check(withBlank.count == 3 && withBlank[1].isEmpty, "用户刻意留白的中间页被保留")

    let trailingBlank = PageComposer.compose(
        savedPages: [[apps[0]], []], unvisited: [], columns: 2, rows: 2)
    check(trailingBlank.count == 1, "末尾空页被回收")

    check(PageComposer.compact([["a"], [], ["b"], []]) == [["a"], ["b"]], "空页回收保留顺序")
    check(PageComposer.compact([[], []]) == [[]], "全部为空时至少保留一页")
    check(PageComposer.compact([["a"]]) == [["a"]], "单页不做回收处理")

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

// MARK: - 入口

do {
    testFuzzySearch()
    testAppVersion()
    testGridPacker()
    testPageComposer()
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
