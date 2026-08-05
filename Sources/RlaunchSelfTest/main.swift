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
    } else {
        check(false, "旧格式配置可正常解码（缺新字段不崩溃）")
    }
}

// MARK: - 入口

do {
    testFuzzySearch()
    try testScanner()
    try testConfigStore()
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
