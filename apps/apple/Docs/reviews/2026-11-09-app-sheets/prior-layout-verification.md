# 弹窗统一与单层窗口修正

代码盘点：12 处 sheet 入口，覆盖 9 种内容弹窗；另有 12 处系统 confirmationDialog、2 处 popover 声明（其中一个为复用过滤器入口）。确认框与轻量筛选 popover 继续使用系统呈现。

## 最终实现

- `AppSheetSurface` 只管理系统 sheet 材质与尺寸，没有内容层背景卡片、外圆角、外描边、外阴影或外边距。系统拥有唯一窗口边界。
- Bangumi、TMDB、弹幕选择、直连输入、服务器地址、弹幕网关、MoviePilot 登录、订阅编辑和更新说明统一标题、字段与操作布局。
- 短表单在 iOS 默认使用紧凑高度，可展开；辅助功能大字号使用大弹窗。长列表和订阅表单保持滚动空间。
- TMDB 先选候选再确认，搜索任务随输入失效；保存失败时保留候选并展示错误。
- 提交期间禁止重复提交及交互关闭。底部动作独立于滚动内容，窄屏弹幕搜索分两行。
- 清除了 PlayerScreen 入口遗留的 `.presentationBackground(.clear)`。

## 验证

- 最终 macOS Debug 编译通过：`macos-accepted-build.log`。
- 最终 iOS Simulator Debug 编译通过：`ios-accepted-build.log`。
- 65 项相关回归测试通过，0 失败、0 跳过：`regression.xcresult`、`regression-summary.json`。回归运行在最后的纯窗口边界与尺寸修正之前；最后修改通过两端编译及原生截图复核。
- 使用真实 SwiftUI `.sheet` 呈现复核 macOS 直连输入、Bangumi 和订阅；iPhone 覆盖 9 种弹窗，并核对浅色、深色及辅助功能大字号。
- 最后的弹幕窄屏布局另存为 `iphone-accepted-danmaku*.png`。
- `git diff --check` 通过。

## 保留与隔离

原始截图、预览源码、日志和回归结果均完整保留。`baseline/` 保存此次修改前的源码，其中包含当时已有的 Bangumi 修改。`sheet-style-only.patch` 仅包含本次相对于 baseline 的变更；现有其他工作区修改保留。`source-sha256.json` 记录最终源码哈希。

预览应用使用隔离存储；临时 iOS 预览 bundle `local.ocplayer.sheetpreview` 已终止并卸载，macOS 预览进程也已退出。
