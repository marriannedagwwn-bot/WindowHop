import AppKit

enum WindowAction: String, CaseIterable {
    case close, minimize, fullscreen, hide, quit

    var title: String {
        switch self {
        case .close: return "关闭窗口"
        case .minimize: return "最小化 / 恢复窗口"
        case .fullscreen: return "进入 / 退出全屏"
        case .hide: return "隐藏 / 显示应用"
        case .quit: return "退出应用"
        }
    }

    /// The live AX operation checks whether an attribute/action is supported as well.
    func canApply(to window: WindowRecord) -> Bool {
        switch self {
        case .close, .minimize, .fullscreen:
            return !window.isWindowless && window.axElement != nil
        case .hide: return window.pid > 0
        case .quit:
            return window.pid > 0 && window.bundleIdentifier != "com.apple.finder"
        }
    }
}
