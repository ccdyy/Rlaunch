import Foundation

/// 主窗口「顶栏 / 分页条 / 网格」的纵向尺寸分配（纯计算）。
///
/// 主窗口布局（`MainWindowController.rootChromeLayout`）与设置页的「当前显示效果」预览
/// 共用这份算式：预览推算出的网格可视区必须与真实布局一致，设置页才不会「跟实际情况不符合」。
public enum ChromeMetrics {
    /// 顶栏（搜索框 + 按钮）高度
    public static let topBarHeight: CGFloat = 56
    /// 窗口化时顶栏 / 底栏与网格之间的留白（全屏为 0）
    public static let windowedContentGap: CGFloat = 12
    /// 底部分页条高度
    public static let paginationBarHeight: CGFloat = 36
    /// 分页条上下留白
    public static let paginationMargin: CGFloat = 16

    /// 底部为分页条与留白预留的总高度
    public static func bottomReserved(fullscreen: Bool, showsPagination: Bool) -> CGFloat {
        let gap = fullscreen ? 0 : windowedContentGap
        let bar = showsPagination ? paginationBarHeight + paginationMargin * 2 : 0
        return bar + gap
    }

    /// 网格可视区尺寸（滚动区大小）。
    /// - Parameters:
    ///   - containerSize: 窗口内容区大小（全屏时为屏幕大小）
    ///   - safeAreaTop: 全屏时顶部安全区（刘海）高度；窗口化传 0
    public static func gridViewport(containerSize: CGSize,
                                    fullscreen: Bool,
                                    safeAreaTop: CGFloat,
                                    showsPagination: Bool) -> CGSize {
        let gap = fullscreen ? 0 : windowedContentGap
        let topInset = fullscreen ? safeAreaTop : 0
        let height = containerSize.height - topBarHeight - topInset - gap
            - bottomReserved(fullscreen: fullscreen, showsPagination: showsPagination)
        return CGSize(width: containerSize.width, height: max(0, height))
    }
}

/// 设置页预览所需的「当前窗口 / 屏幕」信息（由主窗口提供）。
public struct GridPreviewContext: Equatable {
    /// 窗口化时窗口（内容区）的大小；全屏中则为退出全屏后将恢复的大小
    public var windowSize: CGSize
    /// 窗口化时网格可视区
    public var windowedViewport: CGSize
    /// 全屏时所在屏幕的名称与大小
    public var screenName: String
    public var screenSize: CGSize
    /// 全屏时网格可视区
    public var fullscreenViewport: CGSize

    public init(windowSize: CGSize,
                windowedViewport: CGSize,
                screenName: String,
                screenSize: CGSize,
                fullscreenViewport: CGSize) {
        self.windowSize = windowSize
        self.windowedViewport = windowedViewport
        self.screenName = screenName
        self.screenSize = screenSize
        self.fullscreenViewport = fullscreenViewport
    }
}

// MARK: - 空白处点击策略

/// 点击网格空白处应该做什么。
public enum BlankClickAction: Equatable {
    /// 什么都不做
    case none
    /// 收起启动台（仅全屏）
    case hideLauncher
    /// 关闭设置面板（仅全屏：此时设置面板是浮在全屏之上的附属面板）
    case closeSettings
    /// 关闭已展开的文件夹
    case dismissFolder
    /// 退出多选模式
    case exitSelection
}

public enum BlankClickPolicy {
    /// 点击空白处的行为：
    ///
    /// - **全屏**：关闭设置面板 → 关闭文件夹 → 退出多选 → 收起启动台（逐层退出，与 Launchpad 一致）。
    /// - **窗口化（小窗）**：点空白处**不会**关闭任何东西——不收起启动台，也**不会**关掉设置面板
    ///   （设置面板与小窗并排使用，点一下空白就把它关掉会打断调节）。
    ///   文件夹、多选这类「窗口内的临时状态」仍然可以点空白退出。
    public static func action(isFullscreen: Bool,
                              settingsVisible: Bool,
                              folderOpen: Bool,
                              selecting: Bool) -> BlankClickAction {
        if isFullscreen, settingsVisible { return .closeSettings }
        if folderOpen { return .dismissFolder }
        if selecting { return .exitSelection }
        return isFullscreen ? .hideLauncher : .none
    }
}
