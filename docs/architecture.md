# 架构说明

WindowHop 是一个运行于菜单栏的原生 macOS 应用。AppKit 管理应用生命周期、设置窗口和浮动面板，SwiftUI 绘制窗口列表与选中背景，系统辅助功能接口负责窗口读取和操作，ScreenCaptureKit 提供可选截图。

## 源码分工

| 文件 | 职责 |
| --- | --- |
| `Source/main.swift` | 启动 `NSApplication` |
| `Source/AppDelegate.swift` | 会话状态、窗口加载、搜索、提交与取消、菜单栏及组件协调 |
| `Source/KeyboardController.swift` | 全局事件监听、快捷键与搜索状态、按键重复保护 |
| `Source/WindowCatalog.swift` | 窗口枚举、最近使用记录、AX／CG 身份匹配、聚焦、截图缓存 |
| `Source/WindowAction.swift` | 窗口动作类型及可用性规则 |
| `Source/Models.swift` | 窗口记录、设置、权限状态与基础规则 |
| `Source/OverlayController.swift` | 浮动面板、列表视图、鼠标与搜索输入 |
| `Source/OverlayLayout.swift` | 布局尺寸、项目位置和视觉导航规则 |
| `Source/SelectionBackdrop.swift` | 中性毛玻璃选中背景与选择动画 |
| `Source/ChooserPresentationAnimator.swift` | 列表呼出的淡入与弹簧位移 |
| `Source/SelectionPreviewController.swift` | 所选窗口捕获图像的独立放大预览 |
| `Source/SettingsController.swift` | 外观、控制、通用、例外四页设置 |
| `Source/DemoWindows.swift` | 示例窗口数据 |
| `Source/SelfTest.swift` | 不操作系统窗口的规则回归检查 |
| `Source/Diagnostics.swift` | 显式开启的开发诊断 |

## 一次切换的过程

1. 快捷键或菜单开启会话，记录本次窗口范围与屏幕。
2. 窗口目录通过辅助功能接口枚举候选，并结合系统窗口信息做保守关联；随后应用筛选、搜索与排序。
3. 面板显示候选。启用缩略图且已授权时，异步捕获图像并更新视图。选择变化只移动选中背景，图标与文字保持位置。
4. 用户松开修饰键、按 Enter 或点击目标后，向对应应用发送恢复及聚焦请求，并校验前台应用与窗口焦点。
5. 取消、新会话或后续用户输入会使旧意图失效，避免迟到的异步回调继续切换窗口。

窗口枚举、截图和动作使用不同的等待与取消策略。枚举有约 2 秒预算；聚焦与窗口操作允许更长的响应时间，但仍受会话与动作身份校验约束。关闭窗口和退出应用采用正常系统请求，不自动确认未保存内容提示。

## 捕获与缓存

截图使用 `SCScreenshotManager`，普通图像限制在约 720 × 480，启用所选窗口放大预览时限制在约 1440 × 960，并保持比例。缓存仅驻留内存，最多 40 张；超过 10 分钟的条目在下次加载时清理。复用要求窗口身份、窗口编号、几何位置和标题均匹配。

截图失败时回退为应用图标。最小化窗口可以复用符合条件的已有缓存，但不会被主动恢复以便捕获。放大预览面板不接收输入，也不激活真实窗口。

## 设置与系统集成

偏好保存在 `UserDefaults`，JSON 导入会检查字段类型与选项值。示例截图使用临时偏好存储，不改写用户设置。登录启动使用 `SMAppService`，系统需要批准时由设置页显示状态。

辅助功能和屏幕录制是两项独立权限。前者支撑窗口操作与快捷键，后者用于图像。普通运行不联网、不写入窗口捕获图像，也不开启诊断日志。

当前构建需要 macOS 26 SDK，因为源码包含受系统版本检查保护的 `NSGlassEffectView` 分支；macOS 15 上使用 `NSVisualEffectView`。安装运行的最低版本与编译所需 SDK 版本不同。

macOS 15 的面板使用窗口背后的系统模糊，浅色为 `mediumLight`，深色为 `dark`，普通模式不再叠加统一底色。「减少透明度」开启时才使用不透明背景。图标模式的单行标题复用底部边距，滚动内容仍保留标题的完整高度，避免多出一整段空白或裁掉最后一行文字。

## 当前边界

实现使用公开系统接口，未完整复现 AltTab 的私有 WindowServer／SkyLight／SLPS 路径。「当前可见桌面」依赖可见窗口集合，不能提供完整 Space 归属。应用的辅助功能实现、复杂标签页、全屏和受保护内容都会影响结果。截图不是视频流，当前也不提供持续后台实时捕获。

规则测试只能验证实现中的确定性逻辑。系统权限、真实窗口与多显示器行为需按 [验证说明](testing.md) 独立检查。
