# WinUI 3 前端实施方案

> 2026-11-15 用户明确要求 UI 尽量与 macOS 原版一致，不主动改变布局或交互；无法还原的部分由用户取舍。
> 本文中早期提出的主动设计变化已经失效，对齐约定与当前差异见 [UI-PARITY.md](UI-PARITY.md)。

调研日期：2026-11-15。Apple 参考仓库：[1824239290/OcPlayer](https://github.com/1824239290/OcPlayer)，调研固定在提交 [`888ccdd8`](https://github.com/1824239290/OcPlayer/tree/888ccdd8a1098b4426166bb4b09b2f7dca3d8720)。

本方案以共享 Core 已完成为前提，规划 Windows 前端及平台适配。现有 `ARCHITECTURE.md` 的“迁移共享核心”属于早期路线，不再作为本次前端工作的前置任务。本次只增加规划文档，不实现页面。

## 1. 产品方向

保留 OcPlayer 的内容结构、海报氛围、续播路径和播放器操作习惯，用 WinUI 3 实现 Windows 原生窗口与交互。

推荐主窗口使用**顶部导航：首页 / 观影 / 设置**。媒体库从首页进入；Bangumi 和 MoviePilot 的管理入口归入观影空间。三项主入口适合顶部布局，横向空间留给媒体内容。此选择对应当前 macOS 源码，而非较早截图里的四图标导航。

第一版的目标是打通两个完整路径：

1. 无服务器启动 → 打开本地文件或 URL → 播放 → 调整字幕/音轨 → 退出。
2. 登录服务器 → 首页 → 媒体库/搜索 → 详情 → 选集/续播 → 播放 → 返回后更新进度。

## 2. macOS 调研结论

查看了 README 的首页、详情及播放器截图，并对照当前 SwiftUI 页面、导航和 Core 适配源码。截图用于观察视觉，当前源码用于确定导航及业务边界；未在 Windows 环境运行 macOS 应用。

| 参考部分 | 当前实现 | Windows 对应 |
| --- | --- | --- |
| AppShell / AppShellChrome | 无侧栏，顶栏分区为首页、观影、设置；播放器在页面导航之外呈现 | 顶部 NavigationView + Frame；播放器覆盖主窗口 |
| HomeView / HomeSection | 继续观看、接下来看、最近添加、媒体库四类栏目，可排序及隐藏；支持局部失败与缓存内容 | 横向内容栏，按栏目呈现加载/失败；保留栏目配置 |
| UnifiedSearch | 默认搜索媒体库；用户主动选择 Bangumi 或 MoviePilot 才查询对应来源 | AutoSuggestBox + 来源菜单；不默认同时请求三个服务 |
| LibraryView | 海报网格、库内搜索、排序、观看状态筛选、分页 | 虚拟化 GridView；固定工具栏；增量加载 |
| DetailView | 背景图、透明标题 Logo、简介、播放、选季选集、媒体信息；当前有翻页交互 | 首版使用可滚动详情页；先完成内容和操作，再评估翻页效果 |
| PlayerScreen / HUD | 视频优先；中央播放与跳转；底部进度/标题/轨道等；HUD 有自己的视觉规则 | 专用视频宿主 + XAML HUD；播放器主题独立于浏览页面 |
| MyHomeView | 观影空间含历史、放送日历、待看/在看、下载及订阅摘要 | 分模块加载的观影页；集成关闭时隐藏相应模块及入口 |
| SettingsHub | 服务 / 播放与界面 / 应用三组 | 设置总览 + 独立子页；使用原生表单控件 |

重要细节：无分集图片时保留中性占位，不能拿剧集海报冒充分集剧照；图片和页面缓存按服务器、账号隔离；搜索及切集有取消和防止旧请求回写的机制。

## 3. 窗口与导航

### 主窗口

- 使用系统窗口按钮和可拖动标题栏，支持 Snap Layouts；标题栏交互区域从拖动区域排除。
- Windows 11 使用 Mica 基底；系统不支持材质、关闭透明效果或高对比度时使用主题实色。
- 标题栏显示应用名；其下顶部导航显示首页、观影、设置。首版不强行把全部导航控件塞进标题栏。
- 根页工具区显示服务器/账号切换、打开文件/链接、刷新、搜索；窄窗口收起次要操作。
- 使用 Frame 和显式路由服务，路由携带服务器、账号、媒体条目等稳定标识，不携带 View 实例。
- 媒体库、详情、集成管理和设置子页显示返回键；支持 Alt+Left 和鼠标返回键。
- 返回媒体库时恢复搜索、筛选和滚动位置。切换服务器时取消旧加载并撤销旧账号的页面状态。

建议初始客户区约 1280×800 DIP，最小目标约 720×520 DIP；具体下限由内容及 Windows 10 兼容验证决定。主导航始终只有三项，窄窗口用 NavigationView 的原生溢出菜单承载。

### 播放器窗口

播放器已改为主窗口内的 PlayerView 覆盖层，与 macOS 一致。播放时隐藏浏览界面并保留页面状态，退出后恢复；新播放请求复用当前覆盖层，由 Core 的请求及会话流程控制切换。

- 普通、全屏及置顶模式；CompactOverlay 小窗作为后续阶段。
- 退出全屏恢复原窗口位置/大小；跨显示器移动时重新计算 DPI 与输出能力。
- 关闭播放器按 Core 的停止/上报流程完成收尾；关闭主窗口时显式关闭播放器并结束会话，避免隐形后台进程。
- HUD 层与主窗口主题解耦：视频上采用稳定的深色半透明底，保证白色文字及轨道菜单可读。

## 4. 页面布局与交互

### 首页

保留柔和的海报氛围背景，在独立背景层做裁切、模糊和渐隐，不让背景图改变内容尺寸。前景内容分为四类栏目，顺序使用已保存的栏目配置。

- 媒体库：宽屏显示横向封面入口，如电影、电视剧、合集。
- 继续观看 / 接下来看：16:9 剧照、系列名、S/E 信息和剩余时长；继续观看另有进度条。
- 最近添加：2:3 海报与标题，电影/剧集用一致的卡片规则。
- 首屏就能找到“连接服务器”和“打开文件”；本地播放不依赖登录。
- 点击媒体卡片主体进入详情；卡片上的播放动作直接播放或续播，避免同一区域行为不明确。
- 每栏独立加载；刷新失败时保留已有内容并提供重试，不把整页清空。

横向栏目支持鼠标横滚、触摸和左右按钮。滚轮默认用于页面纵向滚动，不在所有卡片上强行拦截。

### 媒体库与搜索

工具区放库名/条目数、搜索框、排序及观看状态。GridView 保留虚拟化和容器复用；不在外层再套会使虚拟化失效的 ScrollViewer。

海报目标宽约 150–190 DIP，间距约 16 DIP，按可用宽度计算列数。滚动接近末尾时请求下一页；分页错误只出现在末尾，已加载条目继续可用。

搜索采用约 300–350 ms 防抖，取消上一请求，并在回写时校验查询代次与服务器会话。切换来源不会修改用户关键词；默认只查当前媒体服务器。无结果、服务未登录和服务停用分别给出准确提示。

### 详情

宽屏头部左侧约 40% 用于标题 Logo/文字、元信息、简介、播放/续播及观看状态，右侧约 60% 展示背景；下方是季选择、分集、演职员和可折叠媒体信息。

窄屏改为背景横幅在上、文字和操作在下；分集使用可换行网格或列表，不把全部操作压在一行。

- “续播”显示进度；“从头播放”放在邻近的次要动作或菜单。
- 分集卡显示集号、名称、时长、观看标记，缺图时保持尺寸稳定。
- 分辨率、视频编码、HDR 类型、音轨、字幕来自 Core 的类型化结果，不在 UI 重新推断。
- 首版采用自然纵向滚动及短转场；macOS 的翻页式详情单独评估键鼠体验后再加入。

### 播放器

层次为视频 → 内核字幕/弹幕或对应平台渲染层 → HUD → 菜单/对话框。字幕、弹幕最终由哪层绘制，以真实 Windows 播放后端合同为准，避免重复绘制。

- 左上：返回/关闭及窗口模式；右上：音量。
- 中央：后退、播放/暂停、前进；跳转秒数读取 Core 偏好。
- 底部：标题/S/E、进度及时间；音轨、字幕、弹幕、选集、倍速、章节及播放设置。
- 有可跳过片头/片尾时显示短时动作；下一集建议按 Core 决策呈现。
- 鼠标活动显示 HUD，闲置后隐藏；菜单打开、拖动进度、键盘焦点进入控制区时保持可见。播放打开失败要显示可恢复错误。
- 拖动进度条先显示本地预览，提交跳转后由播放快照确认；外部时钟更新不能抢走正在拖动的滑块。

建议快捷键：Space 播放/暂停，左右或 J/L 跳转，上下音量，M 静音，F 全屏，Esc 先退出全屏再关闭播放器；Ctrl+O 打开文件，Ctrl+L 打开链接，Ctrl+F 搜索。输入框、组合键、菜单及焦点控件优先处理自身按键，不在 TextBox 中抢走 Space/J/L。

### 观影空间

以“观看历史 / 待看 / 在看 / 每日放送 / 订阅 / 下载”组织内容；Bangumi 和 MoviePilot 的详细操作进入对应子页。各模块独立加载，登录过期时只影响对应模块。第一版可先提供历史与集成入口，再补摘要、日历和统计。

### 设置与登录

沿用三组：

| 分组 | 子页 |
| --- | --- |
| 服务 | Jellyfin/Emby、Bangumi、MoviePilot、TMDB、网络 |
| 播放与界面 | 播放、弹幕、首页栏目；Windows 外观设置在此适配 |
| 应用 | 维护、配置导入导出、诊断、关于/许可证 |

设置用 ToggleSwitch、ComboBox、NumberBox、Slider 等原生控件；长表单用独立 Page。短确认/新增服务器表单用 ContentDialog，播放器轨道和倍速选择用 Flyout/MenuFlyout。

服务器登录支持地址探测、账号密码，以及 Jellyfin 可用时的 Quick Connect；多地址管理和可达状态展示读取 Core 结果。凭据由 Windows 安全存储服务承载，备份及日志沿用 Core 的排除/脱敏策略。

## 5. 视觉组件与 Windows 适配

先建立一套共享资源，再写页面：

- `ThemeResources.xaml`：浅色/深色/高对比度资源，背景、文字、边框、强调色。
- `Typography.xaml`：Segoe UI Variable，中文使用系统回退；标题、正文、辅助文字明确分级。
- `Spacing.xaml`：4/8 DIP 基础节奏；宽屏横向留白建议 32–48 DIP，窄屏 16–24 DIP。
- `ControlStyles.xaml`：海报卡、剧照卡、库入口、分集卡、状态提示和设置行。
- `PlayerResources.xaml`：单独管理 HUD 间距、半透明表面和控件状态。

WinUI 原生控件承担点击、焦点、禁用、菜单和辅助功能；轻度定制视觉。SF Symbols 替换为 Fluent SymbolIcon/FontIcon；OcPlayer 标识和集成品牌图可沿用原资产。

氛围仅用于浏览背景，菜单和表单保持可读；首版优先静态或低频背景切换，不把高成本模糊铺在全部卡片上。转场建议 120–220 ms，关闭系统动画时直切。

所有控件有 AutomationProperties 名称、键盘路径及焦点反馈；不靠悬停才能找到播放动作。覆盖 100%/150%/200% 缩放、系统文本放大、长中文标题、无海报和高对比度。

## 6. 前端工程结构与 Core 边界

保留现有两个项目，首版不急于扩成大量程序集：

```text
src/OcPlayer.Windows/
  Shell/                 MainWindow、导航、标题栏
  Features/
    Home/                首页及搜索
    Library/             媒体库
    Detail/              媒体详情及分集
    Player/              PlayerWindow、HUD、PlayerViewModel
    Viewing/             历史、Bangumi、MoviePilot 页面
    Settings/            设置及登录
  Controls/              PosterCard、StillCard、EpisodeCard、状态视图
  Resources/             主题、字体、间距、样式、图标、resw
  Services/              页面路由、会话协调、图片呈现服务
  Platform/              文件选择、凭据、窗口、SMTC、电源管理
  Preview/               Debug 数据及场景，复用生产 ViewModel 接口

src/OcPlayer.CoreAdapter/
  OcpCoreClient          低层 C ABI 生命周期
  Contracts/             按实际合同建立 DTO
  Clients/               Media、Playback、Settings、集成能力的类型化门面
  Dispatch/              异步调用、取消、事件分发
  WindowsSurface         Windows 视频表面生命周期
```

使用 CommunityToolkit.Mvvm 建立可观察属性和异步命令，Microsoft.Extensions.Hosting/DI 管理服务生命周期。View 的 code-behind 只处理焦点、指针、窗口/表面等 UI 特有事项；业务调用进入类型化客户端。

**状态归属：**Core 管业务规则、查询组合、续播/连播、来源选择、轨道策略及偏好规则；ViewModel 管当前页面、请求呈现、选中项、滚动锚点和 HUD 显隐；Windows 服务执行文件、凭据、窗口、渲染和系统媒体控制等宿主操作。

Core 返回的 effect/操作收据必须由平台适配执行并正确确认，不能把“Core 已完成”理解为一次命令就替代全部宿主副作用。现有 Apple 文档明确保留了 native decoder、呈现和文件导入等宿主职责。

### 当前 Windows Adapter 需补齐的接入工作

现有 Adapter 已有 create/destroy、Call、Snapshot、PollEvent、surface 和 RenderTick；这足够作为接入起点，但尚未构成页面可直接使用的异步、类型化服务。

1. 校验 ABI 和实际所需导出，按 Core 发布物合同建立能力/版本检查；不能只显示 ABI 数字就认为可播放。
2. 保留原始 JSON 的整数及 nullable 语义，按合同映射 DTO，不把 Int64/UInt64 ID、收据转换成 Double。
3. 将阻塞的原生调用移到工作线程；接入 `request.prepare` / `request.cancel` 及 CancellationToken，按已发布合同执行。
4. 把阻塞调用、事件轮询、渲染时钟及销毁的并发策略明确下来。不能用一个长锁让网络请求挡住取消和渲染；退出时等待在途调用安全收尾。
5. 事件从一个受控入口消费，按 request/session/generation 分发；UI 变更经所属窗口的 DispatcherQueue。轮询按事件队列语义实现，RenderTick 使用单独显示时钟。
6. 统一处理 `ok/code/retryable/message`，区分取消、登录过期、可重试错误及不支持能力；页面保留可恢复操作。
7. 原生句柄、字符串和 JsonDocument 生命周期明确；销毁后不再轮询/渲染，不让事件持有已释放的窗口。

已经在 Apple 适配器中看到 `server.probe/login`、`playback.*`、`playbackPreparation.*`、`playbackTracks.*`、`playbackFlow.*`、`config.*` 和 `diag.*`。实施时以匹配 Core 版本的头文件、命令清单及 JSON 合同为唯一接口依据；不把文档里的示例命令名当作完整 SDK。

不另写一套 C# Jellyfin/Emby、TMDB、Bangumi、MoviePilot 业务实现；Windows 图片服务只负责已授权图像的下载/解码/呈现缓存等宿主工作，协议和业务规则调用 Core。已有 Core 持久化的数据也不再维护另一套 SQLite 真相源；窗口位置等平台偏好单独存放。

## 7. 视频表面必须先做的技术验证

`WindowsPlayerSurface` 当前只是保存句柄并转发 attach/resize/detach，注释写了 HWND/DirectComposition 方向，**它还不是已验证的 WinUI 视频控件**。

第一轮用最小 PlayerWindow 验证：

1. 对齐实际 DLL 的 `surfaceKind`、句柄类型、线程要求、物理像素尺寸及 scale 语义。
2. 依合同选择 SwapChainPanel/Composition 或独立 Win32 视频宿主。直接交一个顶层 HWND，不能证明 Core 会在预期区域绘制。
3. 视频上叠加真实 XAML 按钮、Slider 和 Flyout，验证层级、透明、输入及全屏。若使用子 HWND，必须处理 airspace，不能假定普通 XAML 会覆盖它。
4. 验证大小变化、跨 DPI 显示器、最小化/恢复、窗口关闭和播放会话切换；按合同供给单调渲染时钟并管理 detach。
5. 检查真实帧输出、字幕/弹幕位置、颜色输出及不支持能力的 UI 呈现。HDR/杜比视界/增强能力只按 Windows 后端和显示器实际支持开放。

该验证通过后再固定完整 HUD 结构；页面和离线样式可同时推进，但播放器完成度必须以真实媒体验证。

## 8. 实施顺序与验收

| 阶段 | 交付物 | 完成标准 |
| --- | --- | --- |
| A：壳与接入验证 | 顶部导航、主题、路由、Debug 场景；类型化调用/取消/事件骨架；最小视频表面验证 | 无 DLL 能浏览离线场景；匹配 DLL 可读取快照；真实视频上 XAML 控件正常 |
| B：本地播放闭环 | 文件/链接打开、播放器 HUD、进度、音量、轨道、全屏及错误 | 本地媒体可完整播放；退出/切集不残留句柄；DPI/窗口模式行为正确 |
| C：媒体服务器闭环 | 登录、服务器切换、首页、媒体库、搜索、详情、选集/续播 | 实测 Jellyfin 和 Emby；服务器/查询切换不串内容；播放后进度正确刷新 |
| D：功能对齐 | 弹幕设置/手动匹配、章节/跳过/连播、完整设置、备份和诊断、观影空间与集成管理 | Core 决策与 Windows 宿主执行闭环；停用集成隐藏全部对应入口 |
| E：桌面完善与发布 | SMTC/媒体键、防休眠、小窗、辅助功能、性能及 MSIX | 真实设备验证系统集成；x64/ARM64 交付范围及 Windows 10/11 支持符合后端实际能力 |

先实现代表性页面和真实闭环，再扩展功能。不按未知团队规模及 DLL 集成情况承诺日历工期。

验证分为三层：

- 离线视觉：加载、空内容、无图、长标题、未登录、断网、局部失败和缓存提示；浅/深色、文本缩放和键盘操作。
- 接入测试：DTO 数值/nullable 边界、取消与旧结果、事件会话归属、退出生命周期及失败的轨道操作不更新成功状态。
- 真机播放：本地/网络媒体、续播/连播、外挂字幕、弹幕、全屏、多显示器、DPI 和系统媒体键。命令行编译不能代替这些验收。

## 9. 参考来源

- [README：视觉截图与产品功能](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/README.md)
- [AppShell：当前导航与播放器分层](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppShell.swift)
- [AppShellChrome：当前三分区入口](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppShellChrome.swift)
- [HomeView](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift)、[LibraryView](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift)、[DetailView](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift)
- [MyHomeView：观影空间](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift)、[SettingsHub：设置分组](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsHub.swift)
- [共享 Core 完成审计说明](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Docs/SHARED-CORE-COMPLETION.md)
- [Swift Core 客户端：异步、取消与类型化边界](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/OcPlayerCore/Sources/OcPlayerCore/OcpCoreClient.swift)
- [播放准备的宿主操作合同](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Docs/SHARED-PLAYBACK-PREPARATION.md)、[轨道操作边界](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Docs/SHARED-PLAYBACK-TRACKS.md)
