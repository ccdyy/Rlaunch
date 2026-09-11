import Foundation

/// 应用版本信息：从 App Bundle 的 Info.plist 读取 `CFBundleShortVersionString` / `CFBundleVersion`。
///
/// - `build.sh` 会依据 `git describe --tags` 把 tag 版本写进 Info.plist；
/// - Release CI 会用发布 tag 覆盖同一个字段；
/// - 直接用 `swift run` 调试时没有 Info.plist，此时回退为 `dev`。
public enum AppVersion {
    /// 仓库主页
    public static let repositoryURL = "https://github.com/ccdyy/Rlaunch"

    /// 纯版本号，例如 `0.1.6`
    public static let short: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "dev" : trimmed
    }()

    /// 构建号 / 提交描述，例如 `v0.1.6-3-gabc1234`；无额外信息时与 `short` 相同
    public static let build: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? short : trimmed
    }()

    /// 面向界面的 tag 版本串（补 `v` 前缀），例如 `v0.1.6`
    public static var displayTag: String {
        guard short != "dev" else { return "dev" }
        return short.hasPrefix("v") || short.hasPrefix("V") ? short : "v\(short)"
    }

    /// 版本 + 构建描述：`v0.1.6 (v0.1.6-3-gabc1234)`；两者相同时只显示一次
    public static var displayFull: String {
        guard displayTag != "dev" else { return "dev" }
        let buildDesc = build.hasPrefix("v") || build.hasPrefix("V") ? build : "v\(build)"
        return buildDesc == displayTag ? displayTag : "\(displayTag) (\(buildDesc))"
    }
}
