# macOS 原生全屏工具栏背景修复

全屏时 AppKit 将工具栏搬入主窗口的 `NSToolbarFullScreenWindow` 子窗口。即使 SwiftUI 已隐藏工具栏背景，子窗口里的 `NSTitlebarBackgroundView` 仍绘制整条底色。主线原来的 `FullscreenTitlebarFade` 又在背景图上覆盖 52 pt 实色和 84 pt 渐隐，因此仅处理布局或透明设置不能恢复连续的背景。

`App/macOS/FullscreenToolbarBackground.swift` 在 RootView 常驻一个不接收点击的 AppKit 桥接视图。在 `willEnterFullScreen` 中同步记录主窗口的标题栏背景，并观察其隐藏状态；AppKit 把同一个视图搬进工具栏子窗口并重新显示它时，同步关闭背景，赶在该帧提交前生效。子窗口按父窗口或已记录的背景对象身份确认归属。若该系统配置还启用了内容不透明背板，则关闭 `needsOpaqueBackstop`。工具栏控件与玻璃底保留。窗口通知与 SwiftUI 更新覆盖首次进入、状态恢复、切页、播放工具栏隐藏后恢复及子窗口重建；退出全屏解除观察并恢复进入前的窗口态，拆卸时恢复系统对全屏背景的显示请求。旧渐隐层及其专用全屏环境状态已经移除。

兼容层依赖 AppKit 私有视图名称和可选属性。按具体窗口、内容视图类型及属性访问器检查；系统不再提供对应结构时跳过该部分，不隐藏工具栏或改动普通窗口。应在后续 macOS 升级时重新运行全屏对照。此次本机实测为 **macOS 26.6 / Xcode 27.1 / arm64**，未在截图提到的 macOS 27.2 上运行。

验证：

- macOS Debug 构建与所选现有 AppTests 通过。测试范围为氛围来源、轮播、详情背景保持、路由覆盖、HUD 让位与导航返回。
- iOS Simulator Debug 编译通过，移除共享渐隐代码后未引入平台编译问题；该项未运行 iOS UI 测试。
- 使用真实 SwiftUI Window 和 NavigationStack，将同一份生产桥接代码编入独立验收程序。浅色、深色分别截图；基线有整条标题栏底色，启用桥接后底色消失，撤除桥接后底色重新出现。
- 修复后的 OcPlayer 在隔离数据目录运行：全屏首页与详情页背景连续到顶端，返回、搜索输入、打开本地文件面板和菜单退出全屏正常。文件面板取消后首页工具栏恢复。

完整构建日志、测试结果包、独立程序源码与原始截图保存在 `apps/apple/.local-build/fullscreen-fix-20261119/`。主要入口：`macos-tests.log`、`macos-tests.xcresult`、`ios-build.log`、`fullscreen-regression.swift`、`fullscreen-regression.log`、`light/fullscreen-regression.log`、`app-01-fullscreen-home.png`、`app-02-fullscreen-detail.png`。图片原始文件保留，仅使用另行生成的 JPEG 预览进行检查。

两次独立窗口对照均完成以下全部检查（保留完整检查输出，不将构建成功当作画面验证）：

```text
PASS native full screen entered
PASS baseline has visible titlebar background
PASS bridge disables background on an existing full screen window
PASS native toolbar remains visible
PASS detail navigation keeps background disabled
PASS detail toolbar remains visible
PASS hiding playback toolbar retains native full screen
PASS restored toolbar gets transparent background
PASS full screen exits normally
PASS exit restores original backstop
PASS exit restores titlebar background visibility
PASS second full screen entry disables background
PASS dismantle restores background
```

## 进入全屏动画的补充验证

最初的修复只通过 `childWindows` 查找工具栏子窗口。60 fps 录屏与视图对象时间线复现了后续反馈：动画中 `NSToolbarFullScreenWindow.parent` 为 nil，同一个标题栏背景在迁移时被 AppKit 重新显示；直到 `didEnterFullScreen` 建立父子关系后才被隐藏。先前的全屏完成截图不能证明动画期间无白带。

补充修复提前观察迁移的背景视图，并在 KVO 回调中同步阻止显示；记录系统请求时排除自身的纠正写入，防止恢复时重放错误状态。新增 AppTests 验证迁移到无窗口视图后仍能立即拦截显示、退出后解除观察、其他窗口的全屏通知不影响本窗口。

最终源码的浅色和深色进入／退出录屏均通过检查：背景在子窗口尚未建立 parent 时已保持隐藏；全屏完成前后没有整条底色，退出后普通窗口仍透明。浅色逐帧判据使用顶栏中央固定区域的亮度、颜色方差及下方背景颜色；旧源码录屏能检出白带，最终录屏未检出。相同判据的完整时间点输出保存在 JSON 中，录屏时间轴未与进程时钟作同步，不混用两者计时。切页、播放工具栏隐藏／恢复、第二次进入和拆卸回滚的独立窗口回归也全部通过。

本轮原始源码快照、录屏、帧图及日志保存在 `apps/apple/.local-build/fullscreen-transition-20261119/`：`FullscreenToolbarBackground-before.swift`、`transition-probe.swift`、`transition.mov`、`before.log`、`after-final/transition.mov`、`after-final/transition.log`、`dark-final/transition.mov`、`dark-final/transition.log`、`final-pixel-validation.json`、`steady-final/regression.log`、`macos-tests-final.log`、`macos-tests-final.xcresult`。失败尝试的构建日志与第一轮录屏另行保留；最终结论以 final 产物为准。
