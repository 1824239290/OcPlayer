# MoviePilot 页面布局对齐

对照用户提供的四张 macOS 截图，以及本地 macOS 项目的
`App/Shared/Features/MoviePilot/MoviePilotHomeView.swift`、`MoviePilotResourceView.swift`。
Windows 继续使用 WinUI 3 原生控件和已有的背景、卡片主题资源，保留原版页面结构。

- 订阅首页：搜索、添加、下载管理和刷新菜单置于标题栏；正文是分类与追更数量，以及 2:3 海报网格。列宽按照视口自适应，目标范围 180–240 DIP，列间距 20 DIP、行间距 28 DIP；海报显示状态、季数、评分，下方是细进度条、标题、年份和缺集信息。编辑、搜索、刷新和取消订阅保留在右键菜单。
- 媒体搜索：隐藏订阅分类，显示媒体结果数量和横向卡片。左侧海报为 76×114 DIP，中间是标题、元信息标签和摘要，右侧是订阅菜单和查资源。窄窗口把操作移到信息下方。
- 资源页：顶部媒体海报为 84×126 DIP，保留摘要及缺少 TMDB 编号的提示；下方依次是单行搜索、紧凑筛选与排序、资源数量、搜索进度和资源卡片。未搜索时显示下载图标与空态，筛选栏收到结果后显示。
- 资源卡片：左侧是两行以内的资源标题、单行说明、站点／促销／标签／大小／做种／时间，右侧是下载按钮。站点选择、归属媒体和重新登录收进标题栏控件，结果关键词和清除筛选收进筛选栏菜单。
- 资源页背景使用所选媒体的固定海报，保持完整模糊；离开后恢复既有会话背景池。返回按钮恢复进入资源页或下载页前的来源路由。

搜索仍通过共享 Core 流式接收结果。筛选弹窗和下载不等待搜索结束；下载继续回传原始媒体来源编号及种子数据。排序字段、方向及筛选语义沿用现有策略。

## 验证

Debug 和 Release x64 构建均通过，零警告、零错误。

共享 Core／服务器集成回归 347 条断言通过，包含四条资源页背景生命周期检查；观影／Bangumi／集成设置页面回归 30 条 WinUI 断言通过。结果分别位于 `artifacts/moviepilot-parity-regression-final-2/results.json` 和 `artifacts/moviepilot-viewing-regression-final/results.json`。

`tests/OcPlayer.Ui/MoviePilotPageVerification.cs` 使用隔离账号和本地图片／协议 fixture，20 条 WinUI 断言通过。覆盖订阅分类、六列与窄窗口网格、海报比例、搜索结果操作位置、资源初始空态、七项筛选、流式进度、搜索中的筛选与下载、媒体来源传递及排序记忆。

结果与深色、浅色、窄窗口截图位于 `artifacts/moviepilot-layout-final/`。截图使用测试数据，`RenderTargetBitmap` 记录 XAML 布局；背景的 Composition 像素不包含在这些截图中。背景来源、持续保留、换媒体以及退出时恢复会话池由集成测试验证。

分类文字裁切修正：28 DIP 高的 `SelectorBarItem` 使用 12 DIP 字号和上下各 3 DIP 的内边距，避免默认上下 10／7 DIP 内边距裁掉文字。分类栏的位置和高度保持不变。补充文字边界回归后，21 条 WinUI 断言通过；结果与截图位于 `artifacts/moviepilot-category-fix/`。

Debug 专项入口为 `--verify-moviepilot=<绝对输出目录>`，完成后自动关闭窗口：

```powershell
dotnet build OcPlayer.sln -c Debug -p:Platform=x64
$env:DOTNET_ROOT = Split-Path -Parent (Get-Command dotnet).Source
$env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
$exe = ./Scripts/start-windows.ps1 -PrepareOnly
Start-Process -FilePath $exe -ArgumentList '--verify-moviepilot=D:\OcPlayer-Windows\artifacts\moviepilot-layout-check' -WindowStyle Hidden
```
