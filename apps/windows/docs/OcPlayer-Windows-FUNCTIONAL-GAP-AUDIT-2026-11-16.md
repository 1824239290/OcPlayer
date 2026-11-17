# OcPlayer → OcPlayer-Windows 功能差异完整审计

> 本文保留补齐前的固定基线差异，不代表当前仍然缺失的功能。补齐实现及本轮构建、真实媒体和界面验证结果见 [补齐收尾报告](parity-completion-2026-11-16.md)。逐项实现入口见各 `parity-*-progress.md`。

本报告按页面、按钮、菜单选项、输入字段、持久化和实际调用链整理差异。**共 298 条编号记录，另有 6 条播放器交互差异**。这是对齐用的细项记录数，不是 298 个互不重叠的独立功能：同一能力在设置入口、播放器执行及详情展示中可能分别列项。某一行含多档选项时，选项已逐一写出，不用一个“设置未完成”概括。

## 对比版本与结论口径

- OcPlayer：GitHub main 经 API 核实为 [`888ccdd8a1098b4426166bb4b09b2f7dca3d8720`](https://github.com/1824239290/OcPlayer/tree/888ccdd8a1098b4426166bb4b09b2f7dca3d8720)，提交日期 2026-11-14。`D:/OcPlayer/OcPlayer` 的本地副本停在 9 月的 `2e34e6f`，没有拿它充当当前产品基线。
- OcPlayer-Windows：`D:/OcPlayer-Windows`，基于 `2903de7`，**包含本次核对时所有未提交和新增源码**。代码在审计期间仍有其他工作流更新，最终复核已把补上的功能剔出缺失清单。
- 以 macOS 共享桌面路径为主；iOS 专属手势、亮度、后台音频等另列平台差异。Liquid Glass、SF Symbols、Windows 系统窗口按钮和字体不混进业务缺失数量。
- 这是源码与调用链审计。没有在 macOS 实机逐页点击，也没有用真实账号提交收藏/订阅/删除操作；解码性能、HDR/Dolby Vision实际画质、真实服务器契约仍需针对性实测。表内“协议差异”“待实测”没有冒充已复现故障。
- “缺失”指没有对应入口或执行链；“部分”指基础能力已存在但行为/选项/数据不足；“缺失入口”指别处能做，但原版该按钮或菜单位置缺少操作；“展示差异”单独标注。不能将 Demo 静态画面或 Core 内部 API 直接算成前端已实现。

## 分区索引

| 分区 | 编号 | 记录数 | 主要差异 |
|---|---|---:|---|
| 服务器、首页、媒体库、详情、TMDB、应用入口 | R-001–R-082 | 82 | 多服务器/多地址、Quick Connect、分页、缓存、详情数据、选集、TMDB补全、细小入口 |
| 播放器与播放行为 | P01–P37；另 B01–B06 | 37 + 6 | 字幕删除、播放偏好记忆、连播、跳片头尾、错误恢复、系统媒体控制、HUD细节 |
| 设置、维护与弹幕 | S-001–S-056、D-001–D-009 | 65 | 缓冲/字幕/画质全部档位、备份、日志、更新、TMDB设置、弹幕字号和匹配细节 |
| Bangumi、MoviePilot、观影空间与集成账号 | I-001–I-114 | 114 | 收藏/评分/章节、关联、订阅字段、资源筛选/排序、自动刷新、统计、镜像和登录 |

## 最先需要关注的差异

1. **会直接影响结果完整性或正确性的项**：R-026/034 媒体库及搜索固定首 500 条；R-029 所有库都限制电影/剧集；R-035 库内搜索按回车变全库；R-051“类似推荐”实际取当前列表前 8 条；I-026 Bangumi章节状态字段不一致；I-060 MoviePilot状态编码不一致。这两处协议问题应先用真实返回样本核验。
2. **观看主流程**：P12–P20 重试、超时、直连回退、选源与换源、自然结束连播及Bangumi同步；P28–P36 跳片头/片尾完整来源与学习；P21–P23 防息屏和系统媒体控制。
3. **真实模式仍缺的大片能力**：多服务器和多地址；TMDB配置/自动补全/手动关联/整库补全；详情演职员、媒体信息、合集成员；配置导入导出、诊断维护、更新及开源信息。
4. **容易被截图掩盖的小选项**：“更多”中的全屏入口、删除单条外挂字幕、简介展开/收起、选集正序/倒序、字幕默认关闭/位置/描边/加粗三态、片尾保留20/30秒、Bangumi十档评分与撤销、单集想看/抛弃、MoviePilot 13项订阅字段、7组资源精确筛选、5种排序、全选/清除/单项移除等，均在后文逐项列出。

## 已确认存在，不能继续误报为缺失

真实 Jellyfin/Emby 登录和保存当前连接、本地/HTTP播放、排序/观看状态筛选、选季选集与观看状态写回、主窗口播放器、全屏与HUD、音轨/字幕选择、服务器外挂字幕自动加载、章节跳转、字幕缩放、播放信息、截图、分享，以及弹幕自动/手动搜索、XML/JSON导入、偏移/透明度/区域/屏蔽/合并/堆叠，均有现行实现。Bangumi OAuth/动画收藏/基础章节更新、MoviePilot基础订阅和下载操作、观看热力图与实播记录也已有。各分区末尾保留了详细“已有”清单和待验边界。

以下保留全部逐项说明及双方代码位置；可以搜索编号直接定位。

---
## OcPlayer 对齐审计：服务器、浏览、详情与应用入口

基线：OcPlayer `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`；Windows 为 2026-11-16 审计中的当前工作树（含未提交文件）。这里只认实际用户入口及调用链，Demo 固定文字不等于真实模式实现。下表为本分区 82 条审计记录，其中 R-081 为展示差异，不计作业务缺失；R-080 的系统关联部分待实测。

### 服务器与登录

| ID | 状态 | 原版功能 / 选项 | Windows 缺口 | 代码证据 |
|---|---|---|---|---|
| R-001 | 缺失 | Quick Connect 入口 | 缺展开/收起 Quick Connect、申请配对码、显示并复制代码、等待授权轮询、失败重试；Windows 仅账号密码。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Onboarding/OnboardingView.swift#L324) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:608) |
| R-002 | 缺选项 | 独立 HTTP / HTTPS 协议选择 | Windows 可以输入 https://，但缺少原版协议选择器及随手输前缀同步的选项。不能据此说 Windows 不支持 HTTPS。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Onboarding/OnboardingView.swift#L202) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:613) |
| R-003 | 部分 | 先探测服务器再登录 | 原版输入地址后先确认服务器身份/名称、自动识别服务；Windows 要用户先选 Jellyfin/Emby 并提交账号密码，登录和读库后才 probe，缺独立探测阶段。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Session.swift#L115) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:46) |
| R-004 | 缺失 | 保存多台服务器及免重输切换 | Windows PasswordVault 仅保存 active-server；连接另一台替换原连接。缺已保存服务器清单与“切换”。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L128) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/CoreRuntime.cs:91) |
| R-005 | 缺失 | 登录页的已保存服务器入口 | 原版可从登录页选择已有档案；Windows 对话框只有当前地址/用户名，没有已存档案列表。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Onboarding/OnboardingView.swift#L408) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:608) |
| R-006 | 缺失 | 删除指定服务器档案 | 缺指定服务器删除及确认，同时保留其他档案；Windows 的断开连接只移除唯一 active-server。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L76) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/CoreRuntime.cs:100) |
| R-007 | 缺失 | 服务器档案状态 | 缺“使用中”“启动默认”星标、“需重新登录”逐服务器状态。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L128) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:562) |
| R-008 | 缺失 | 同一服务器多个地址 | 缺展开地址列表及添加局域网 / Tailscale / 反向代理地址。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L188) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:7) |
| R-009 | 缺失 | 删除单个地址 | 缺删除指定地址、二次确认、至少保留一个地址的管理行为。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L93) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:7) |
| R-010 | 缺失 | 地址重新检测与延迟状态 | 缺“重新检测”、自动探活、每个地址可达性及延迟显示。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L204) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:7) |
| R-011 | 缺选项 | 固定当前地址 / 恢复自动选择 | 两个独立操作均无；Windows 的单 BaseUrl 不是多地址固定模式。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L275) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:7) |
| R-012 | 缺失 | 自动择优与故障换地址 | 缺并发选择最快可达地址、请求失败及网络改变后的自动换地址。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Endpoints.swift#L1) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:86) |
| R-013 | 缺选项 | 不可达地址仍然添加 | 缺“仍然添加”，以及重复地址/不同服务器 ID 的合并校验。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/ServersView.swift#L561) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:608) |
| R-014 | 部分 | 媒体服务器登录过期处理 | 原版失效后停播、清死 token、清会话并引导重登；Windows 将 2001/2003 映射成通用错误，没有对应统一会话失效流程。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Session.swift#L386) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:93) |
| R-015 | 缺失 | 真实账号头像 | 首页头像固定读 Assets/Demo/avatar-nav.png；缺服务器头像请求、缓存、头像更新/删除后的刷新。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Avatar.swift#L125) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:405) |

### 首页与浏览状态

| ID | 状态 | 原版功能 / 选项 | Windows 缺口 | 代码证据 |
|---|---|---|---|---|
| R-016 | 缺失 | 首页冷启动缓存与离线浏览 | 原版先从仓储加载已缓存首页再刷新；Windows 启动只恢复账号和本地播放记录，browse.home 直接请求网络。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Browser.swift#L110) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/CoreRuntime.cs:34) |
| R-017 | 部分 | 部分栏目失败保留旧内容 | Windows browse.home 返回失败栏目后 Clear 全部列表再填空数组；缺原版逐栏目保留上次成功内容。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Browser.swift#L169) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:108) |
| R-018 | 缺失 | 旧内容提示及缓存更新时间 | 缺“离线/更新失败，显示缓存内容、更新于多久以前”等与内容关联的提示；现有 HomeWarning 只是全局刷新告警。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L158) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:137) |
| R-019 | 缺失 | 首页加载骨架与刷新忙碌状态 | 原版按上次栏目存在情况铺骨架，刷新按钮变为忙碌图标；Windows 没有首页加载状态分支。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L113) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:19) |
| R-020 | 缺失 | 隐藏没有内容的栏目 | Windows 无条件创建已启用栏目标题与空轨道；原版只渲染有数据的内容栏目。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L207) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:22) |
| R-021 | 缺失 | 首页栏目全关后的设置入口 | 缺“首页栏目都已关闭”及“去设置”；Windows 全关后为空页面。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L133) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:22) |
| R-022 | 缺失 | 服务器无内容 / 媒体库加载失败专用状态 | 缺空库说明、栏目内失败文案与“重试”入口；Windows 主要显示全局 InfoBar。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L167) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:19) |
| R-023 | 缺失 | 继续观看与接下来看去重 | Windows 直接展示 browse.home 的 resume/nextUp，没剔除同一条目；已交叉核实当前 Core browse.home 也分别取两组后原样返回，没有去重。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Browser.swift#L48) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:122) · [Core](D:/OcPlayer-Core/crates/ocp-core/src/lib.rs:2171) |
| R-024 | 部分 | 续播卡片剧集标题与分集信息 | Windows StillCard 直接用 media.Title，未用 SeriesTitle 组装剧名/分集名；还存在按两部特定片名硬编码展示文案，真实数据也走同一路径。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/DesignSystem/DesignSystem.swift#L632) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Controls/DemoUi.cs:88) |
| R-025 | 部分 | 首页横卡副标题空值与时长格式 | 原版继续观看与接下来看也共用StillCard，都可显示“还剩”。真正缺口是Win无条件拼集号+剩余分钟，缺无集号/无片长/剩余为零时回退集号、剧名、类型的规则，也缺RuntimeText的小时+分钟格式（如1小时27分）；未知/零值时可显示“还剩 分钟”或“还剩0分钟”。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/DesignSystem/DesignSystem.swift#L642) · [时长格式](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/AppDesignKit/Sources/AppDesignKit/Controls/RuntimeText.swift#L5) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Controls/DemoUi.cs:91) |

### 媒体库与搜索

| ID | 状态 | 原版功能 / 选项 | Windows 缺口 | 代码证据 |
|---|---|---|---|---|
| R-026 | 缺失 | 媒体库分页及自动加载下一页 | 固定 startIndex=0、limit=500，不读取总数和下一页游标，超过 500 条不可继续浏览。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L281) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:173) |
| R-027 | 缺失 | “加载更多”及翻页失败重试 | 没有手动加载更多、下一页进度、保留已加载项后重试失败页。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L281) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:49) |
| R-028 | 缺失 | 已加载数量 / 总数量 | 原版显示“已加载 x / y”；Windows 只显示库名和网格，丢弃 totalCount。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L230) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:179) |
| R-029 | 部分 | 按媒体库类型选择条目种类 | Windows 对所有库写死 movie + series；原版电影库 movie、剧集库 series，其余不限制类型。合集/其他类型不能据现有入口视为完整支持。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L309) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:175) |
| R-030 | 缺失 | 媒体库磁盘缓存恢复 | Windows 只在详情往返时暂存一个 UIElement；缺按库/查询恢复仓储缓存及离线数据。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L445) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:177) |
| R-031 | 缺失 | 库页加载/失败/空结果的区分 | Windows 初次加载及查询切换阶段也可能呈现旧数据或“没有匹配的作品”；缺原版骨架、明确失败页与本地重试。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L106) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:49) |
| R-032 | 部分 | 刷新当前媒体库 | Windows 全局刷新在有服务器时调用 LoadHome；重新 Navigate 当前 library 不满足 LoadLibrary 条件，不能保证重拉当前库查询。原版库页刷新直接 reload。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L275) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:445) |
| R-033 | 缺失 | 首页输入即搜索 | 原版 350ms 防抖随输入查询；Windows 首页只在 QuerySubmitted 后进入结果页，TextChanged 仅 library 路由工作。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L409) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:473) |
| R-034 | 缺失 | 全库搜索分页 | 与库页同样固定首 500 条，缺滚动追加与加载更多。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L526) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:173) |
| R-035 | 部分 | 搜索范围不随回车变为全库 | 库内输入会按当前库筛选，但 Windows 按回车无条件清 LibraryId 并改“全部媒体库”；缺保持库内搜索范围的提交行为。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L28) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:433) |
| R-036 | 缺失 | 搜索无结果的具体说明 | 缺短词至少两个字提示、只搜电影/剧集而非单集标题的范围说明。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L476) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:55) |
| R-037 | 部分 | 直接采纳服务端搜索结果 | Windows 收到服务端结果后又用 Title/OriginalTitle.Contains 二次过滤，可能去掉服务端别名/其他匹配结果；原版直接显示服务端累计页。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Home/HomeView.swift#L589) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/ViewModels/DemoViewModel.cs:60) |

### 详情与选集

| ID | 状态 | 原版功能 / 选项 | Windows 缺口 | 代码证据 |
|---|---|---|---|---|
| R-038 | 缺失 | 评分与内容分级 | Windows 已解析 CommunityRating 但详情不展示；OfficialRating 未进入 DemoMedia。缺原版星级评分与年龄/内容分级徽标。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L716) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:74) |
| R-039 | 缺选项 | 展开全文 / 收起简介 | 首屏和第二屏均限制三行，没有展开/收起按钮。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L1408) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:84) |
| R-040 | 缺失 | 第二屏随当前分集改变简介 | Windows 第二屏始终取 media.Description；DemoEpisode 不含 Overview，不能显示所选分集简介。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L919) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:141) |
| R-041 | 缺失 | 切季后显示该季简介 | Windows DemoSeason 仅 ID/标题/号，缺季简介及季级 TMDB 叠加。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailViewModel.swift#L196) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:221) |
| R-042 | 缺选项 | 选集正序 / 倒序 | 原版有按钮且持久化；Windows 总是 OrderBy(Number)，无切换。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L978) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:232) |
| R-043 | 缺失 | 长篇按 30 集分区 | 缺 1–30 / 31–60 等分区条、反向排序联动与当前集自动定位分区。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L1067) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Controls/EpisodePicker.cs:47) |
| R-044 | 缺失 | 智能默认季 | 缺续播季/NextUp 季优先、首个未看完常规季、跳过 SP 季；Windows 无显式入口季时取第一季。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+DetailPrefs.swift#L26) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:225) |
| R-045 | 部分 | 智能默认集 | Windows 支持从具体 episode 定位，但进入 series 时缺续播 → NextUp → 第一集未看完的默认顺序，取第一集。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+DetailPrefs.swift#L59) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:242) |
| R-046 | 缺失 | 切季保留各季所选分集 | 原版每季记住 selection；Windows 切季重新 Detail 并设 InitialEpisodeNumber，丢失先前手动选择。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailViewModel.swift#L410) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:595) |
| R-047 | 缺失 | 真实缺集占位与播出状态 | 缺从 TMDB/Bangumi 建占位、未入库/未播出标签、播出日期、剧照、名称；只有 Demo 1–12 的模拟补位。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L1171) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:228) |
| R-048 | 部分 | 分集缩略图与悬停简介 | 原版使用分集图/简介；Windows DemoEpisode.Artwork 直接取 Project 的 Primary，缺专门 Thumb 选择，tooltip 只有集号/标题/观看状态。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailComponents.swift#L149) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:230) |
| R-049 | 缺失 | 电影“正片”选集卡 | 原版电影也显示正片卡，可双击播放；Windows 非 series 显示“演职员与媒体信息”文字，没有正片卡。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L947) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:136) |
| R-050 | 缺失 | 真实演职员列表 | UI 仅在 Cast 非空显示；MediaServer.Project 从未映射人员，真实电影/剧集不显示演员及角色/头像。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L1280) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:290) |
| R-051 | 部分 | 真正的类似推荐 | Windows 显示当前 Catalog 排除自身后的前 8 条，未请求相似内容；缺原版服务器 similar 查询。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailViewModel.swift#L478) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:164) |
| R-052 | 缺失 | 合集详情与成员导航 | 缺“合集内容”、成员总数、成员网格、成员分页及点击成员详情。Windows Detail 仅专门处理 series，不处理 boxSet。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L1188) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:205) |
| R-053 | 缺失 | 缓存详情与失败后继续查看 | 原版先用详情快照/磁盘缓存、刷新失败保留内容并提示；Windows OpenDetail 必须网络成功才进入。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailViewModel.swift#L434) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:195) |
| R-054 | 缺失 | 分集加载失败的区内重试 | Windows 切季失败只弹全局通知，缺选集区单独加载状态与“重试”。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L1044) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:595) |

### 详情媒体信息字段

| ID | 状态 | 原版功能 / 选项 | Windows 缺口 | 代码证据 |
|---|---|---|---|---|
| R-055 | 缺失 | 视频：分辨率 / 宽高比 | 真实详情仅显示时长；Demo 展示的 1920×1080 等为固定文字。以下 R-055–R-067 均指真实数据。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L179) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-056 | 缺失 | 视频：编码与 Profile | 缺所选文件真实视频编码及 profile。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L181) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-057 | 缺失 | 视频：码率 | 缺文件视频码率。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L185) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-058 | 缺失 | 视频：帧率 | 缺文件帧率。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L188) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-059 | 缺失 | 视频：动态范围 | 缺 SDR/HDR/Dolby Vision 等文件属性。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L191) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-060 | 缺失 | 视频：色彩 | 缺色域原色与传递函数。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L194) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-061 | 缺失 | 视频：位深 / 隔行扫描 | 缺 bit depth 与扫描类型。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L201) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-062 | 缺失 | 音频：逐音轨资料 | 缺各音轨名称/语言、编码、声道数与布局、采样率、码率、默认标记。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L210) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-063 | 缺失 | 字幕：逐字幕轨资料 | 缺字幕名称/语言、编码、外挂、强制、默认标记。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L227) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-064 | 缺失 | 文件：容器 | 缺真实容器信息。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L246) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-065 | 缺失 | 文件：大小 | 缺真实文件大小。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L249) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-066 | 缺失 | 文件：文件名 | 缺文件名字段。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L255) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |
| R-067 | 缺失 | 媒体源版本数量及按集刷新 | 缺“共 n 个版本”、所选集改变后的媒体信息加载/缓存/失败重试；不是播放器 More 的运行时信息。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailMediaInfoSection.swift#L52) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:161) |

### TMDB 与详情外链

| ID | 状态 | 原版功能 / 选项 | Windows 缺口 | 代码证据 |
|---|---|---|---|---|
| R-068 | 缺失 | TMDB 自动识别与文本补全 | 缺基于 provider ID/搜索建立对应，并按文本优先策略补标题、简介、类型、评分等。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailViewModel.swift#L178) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:290) |
| R-069 | 缺失 | TMDB 图片补全 | 缺电影/剧集/季/集海报、背景、分集剧照、演员头像的 TMDB 回退与补全。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailViewModel.swift#L259) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:297) |
| R-070 | 缺失 | 合集的 TMDB 封面补全 | 首页合集库拼成员海报已有；但合集条目本身缺 TMDB 合集封面/背景解析及懒加载补全。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Library/LibraryView.swift#L250) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Controls/MediaLibraryGrid.cs:49) |
| R-071 | 缺选项 | “手动匹配 TMDB 条目”按钮 | 缺详情页匹配入口。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailExternalLinks.swift#L237) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:70) |
| R-072 | 缺失 | TMDB 匹配搜索与候选核对 | 缺按片名/原名搜索、当前匹配来源、结果数、候选海报/年份/简介、选择状态与失败重试。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/TMDbMatchSheet.swift#L30) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:70) |
| R-073 | 缺选项 | 确认关联 / 解除当前匹配 | 两种动作均缺；也缺绑定结果持久化后立即刷新详情的流程。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/TMDbMatchSheet.swift#L61) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:70) |
| R-074 | 缺选项 | 在 TMDB 打开 | 缺正确电影/剧集/季/合集网址的外链按钮。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailExternalLinks.swift#L40) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:74) |
| R-075 | 缺选项 | 在 Bangumi 打开（媒体详情头部） | 集成独立页浏览器按钮不等于媒体详情链接；缺根据当前媒体/季关联直接打开对应 Bangumi 条目的按钮。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailExternalLinks.swift#L83) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:74) |

### 应用入口与平台交互

| ID | 状态 | 原版功能 / 选项 | Windows 缺口 | 代码证据 |
|---|---|---|---|---|
| R-076 | 缺失 | 打开文件 / 直连链接键盘入口 | 原版 Cmd+O / Cmd+Shift+O；Windows 没有对应 Ctrl+O / Ctrl+Shift+O，只有按钮。这里要求同用途键盘操作，不要求照搬 Command 键。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/OcPlayerApp.swift#L201) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:536) |
| R-077 | 部分 | 文件选择器媒体类型范围 | Windows硬编码仅.mkv/.mp4/.mov/.avi/.webm五类，没有“所有文件”入口；原版用系统audiovisual/movie/video类型及Matroska类型。Win无法从该选择器选其他扩展名；具体系统UTType归类范围和每种格式实际解码能力需实测，不能把未知格式清单当成已证实缺失。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/RootView.swift#L297) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:542) |
| R-078 | 缺选项 | 直连链接 AccessToken | 缺“AccessToken（可选）”输入及带认证头打开直连资源的路径。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/RootView.swift#L344) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:551) |
| R-079 | 部分 | 直连对话框输入本地路径 | 原版同一输入支持 file URL / 本地路径；Windows 此对话框只接受 http/https，本地文件需另走文件选择器。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/RootView.swift#L316) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:556) |
| R-080 | 部分 / 关联待实测 | 外部打开事件处理 | 原版已有onOpenURL把非OAuth URL交给presentLocalFile；Windows仅显式--open=参数，缺标准文件激活/裸路径参数处理。两边源码都未发现完整媒体文件类型关联声明，不能声称原版“默认应用/双击文件关联”已经完整、Windows独缺该能力；安装后的系统关联需另验。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/RootView.swift#L125) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:108) |
| R-081 | 展示差异 | 首次欢迎 / 登录海报墙 | 原版有 OnboardingWelcomeView、缓存封面墙与登录阶段；Windows 默认直接进入浏览壳层并用连接弹窗，缺对应首次引导体验。此项与实际播放能力分开统计。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Onboarding/OnboardingWelcomeView.swift#L1) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:106) |
| R-082 | 部分 | 跟随系统浅色 / 深色外观 | 原版浏览界面读取系统 colorScheme 并自动适配；Windows Root 写死 RequestedTheme="Dark"，只能手动二态切换，没有“跟随系统”路径，重启又默认深色。已有浅色模式，不应说成完全不支持浅色。 | [原版](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Detail/DetailView.swift#L681) · [Windows](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml:7) · [切换](D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:376) |

### 核实已有，避免误报

Jellyfin/Emby 账号密码登录、当前账号凭证安全保存及恢复、HTTP/HTTPS/反代路径、直接本地播放、四个首页栏目入口、库卡拼贴、三来源搜索切换、库内防抖及旧请求取消、原版库类型对应的排序字段（名称/最近添加/年份/评分/时长/随机）、升降序、全部/看过/没看过、排序持久化、详情上下翻页、电影及分集观看状态写回、选季、选集、双击播放、续播按钮、详情返回库时恢复网格、主窗口内播放器返回恢复，均已有对应实现或明确路径，不列为整块缺失。

原版也没有的分集标题全库搜索、电影多版本手动片源菜单，不凭想象补为迁移需求。音视频解码格式/性能/HDR 输出实效需要同片源实测，本分区未用静态界面推断它们。



---

## 播放器精细对照审计（分报告）

基线：OcPlayer GitHub main `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`（2026-11-14），源目录 `D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720`。Windows 为 `D:/OcPlayer-Windows` 当前工作树（包括未提交文件），最终复核截止 2026-11-16 04:17 HKT。本次仅静态源码与调用链核对，未宣称逐项真实媒体实机通过。

审计时 Windows 另一个工作流正在修改播放器。早期发现的 More/Tracks 生命周期未接线，在最终复查前已经补齐，**已从缺失清单删除**。播放器设置页的缓冲、默认字幕语言/样式、画质等选项由设置分报告列出；本报告只补其实际播放行为。

### 明确缺失或部分支持

| 编号 | 状态 | 功能粒度 | 原版与Windows差异 | 原版证据 | Windows证据 |
|---|---|---|---|---|---|
| P01 | 菜单项缺失 | “更多”里的“进入全屏 / 退出全屏” | 原版在更多菜单保留此项；Win 更多菜单只有倍速、播放信息、截图和条件分享。Win 顶栏全屏按钮、F 键、双击全屏已存在，因此缺的是这一处入口。 | [1] | [2] |
| P02 | 缺失 | 删除一条外挂字幕 | 原版字幕轨道行按 canRemove 显示删除按钮；Win 只有单选轨道/关闭字幕/导入，没有删除入口，也没有调用 removeSubtitleTrack。删除当前轨后重新按偏好选择的配套行为也缺。 | [3] [4] | [5] [6] |
| P03 | 部分 | 播放信息：杜比视界状态 | 原版能区分“杜比视界”“杜比视界（映射 SDR）”“杜比视界（HDR）”。Win 仅按 transfer=16/18 判断 HDR(PQ)/HLG，其余 SDR，没有杜比源身份参与。此处是信息显示缺口，不能据此断言 Windows 不支持杜比解码。 | [7] | [8] |
| P04 | 缺失 | 播放信息：“输出”行 | 原版显示实际输出编码（SDR / Apple EDR / HDR10 PQ / 扩展线性）、面格式（8bit / 10bit / 16bit 浮点）及 HDR 回退原因；Win 虽有 GetOutputStatus 适配器方法，信息面板未读取或显示。 | [9] [10] | [11] [12] |
| P05 | 缺失 | 记住播放倍速 | 原版跨启动保存 rate，临时快进除外；Win 每个新 PlayerView 从 1× 开始，SetRate 只下发当前会话。 | [13] [14] | [15] [16] |
| P06 | 缺失 | 记住音量 | 原版音量去抖落盘并在开片恢复；Win 滑块初值40，只有当前实例数值，没有音量设置读写。 | [17] | [18] [19] |
| P07 | 缺失 | 记住静音状态 | 原版 muted 独立保存；Win 用 Volume=0 临时模拟静音，仅在当前实例用 _previousVolume 记住原音量，新播放器丢失。 | [20] | [21] |
| P08 | 部分 | 按字幕语言偏好自动选轨 | 原版轨道刷新后支持“简中优先 / 繁中优先 / 跟随文件默认 / 默认关闭”，识别语言和显示名，用户手动选择后本片不再覆盖；原版没有 English 这一档。Win 仅新增服务器侧车字幕在“原来没字幕”时按 zh/chi 粗选一条；不会校正已选中的内封首轨，也不区分简繁或默认关闭。设置项详见设置审计。 | [22] [109] | [23] |
| P09 | 缺失 | 右方向键长按临时2倍速 | 原版按住右箭头进入临时2×，松手/失焦/离开播放器恢复原速，并显示独立2×徽章；Win 右箭头只 Seek(+10)，没有长按状态、恢复或徽章。 | [24] [25] | [26] |
| P10 | 缺失 | 缓冲中指示 | 原版持续缓冲时显示独立中央转圈，短促饥饿经迟滞过滤，HUD关闭也可见。Win 采集 Buffering，但仅用于信息面板的状态字，没有画面转圈或迟滞UI状态。 | [27] | [28] [29] |
| P11 | 缺失 | 准备播放的加载层和取消入口 | 原版从解析播放地址到首帧前保留加载遮罩、片名、取消按钮；Win Play 直接等待 Resolve，失败 Notify，播放器打开后黑背景和控制条，没有对应准备层及明确“取消准备”按钮。返回上页或关闭窗口的间接取消不等同该入口。 | [30] [31] | [32] [33] |
| P12 | 缺失 | 播放错误处原地重试 | 原版准备失败和播放错误徽章都有重试，服务器媒体重新取 PlaybackInfo/会话并按进度恢复；Win InfoBar 仅展示/关闭，Failed 统一 retryable=false，无重试按钮。 | [34] [35] | [28] [36] |
| P13 | 缺失 | 错误类型提示和恢复分流 | 原版区分网络/格式不支持/鉴权/服务器/已取消/未知，并据此决定换源/重试；Win 原生播放失败统一归 decode，显示原始 message。 | [37] | [36] |
| P14 | 缺失 | 开片60秒超时保护 | 原版引擎open超过60秒取消、停止并显示超时，回收挂起开片槽位；Win PlaybackSession.Open/Tick 只等待原生事件，无宿主级open watchdog。此项不等于否认原生HTTP自身可能有超时。 | [38] | [39] [40] |
| P15 | 缺失 | PlaybackInfo失败后直连回退 | 原版准备工作流在 PlaybackInfo 失败后尝试裸直连；Win Resolve 对 playback.info 直接 await，异常回上层 Notify，未走回退。 | [41] [42] | [43] |
| P16 | 缺失 | 优先选择可直放的媒体源 | 原版按 DirectPlay → DirectStream → 首条的策略选择；Win 无条件 sources[0]。同一个条目多个版本/媒体源时可能选错首选。 | [44] | [45] |
| P17 | 缺失 | 开片失败自动尝试备用媒体源 | 原版构建候选源并按错误类型自动切换，最多3次，最后回到可手动重试的错误态；Win PlaybackSource 只存一个URI，没有替代源和恢复流。 | [46] [47] | [48] [49] |
| P18 | 缺失 | 自然播完自动下一集 | 原版预取下一集（排除特殊篇），达到末尾自动开下一集；Win state=5 仅置停止、存进度、上报，无下一集回调。 | [50] [51] | [52] |
| P19 | 缺失 | 没有下一集时自动退出播放器 | 原版自然结束而没有下一集 dismissPlayer；Win停在播放器末尾，须手动返回。 | [53] | [52] |
| P20 | 缺失 | 自然看完同步Bangumi章节已看 | 原版有关联且登录时按集号标记 Bangumi 章节已看，失败不阻断连播；Win结束链仅本地进度和Jellyfin/Emby停止上报，没有触发 Bangumi 集数同步。 | [54] | [55] |
| P21 | 缺失 | 播放期间防息屏 | 原版只在实际播放期间持有防显示器休眠令牌，暂停/错误/退出释放。Win 前端与适配器没有 DisplayRequest/SetThreadExecutionState/PowerRequest 对应实现。 | [56] [57] | [58] |
| P22 | 缺失 | 系统“正在播放”信息 | 原版发布片名、集名、时长、当前位置、速率、播放/暂停状态，退出清除；Win 无 SystemMediaTransportControls/媒体会话发布。 | [59] | [58] |
| P23 | 缺失 | 系统媒体控制命令 | 原版响应系统播放、暂停、切换播放暂停、前后10秒、改变进度；Win只有播放器焦点范围内的普通键盘快捷键，无媒体键/系统媒体面板命令注册。 | [60] | [61] |
| P24 | 缺失 | HUD隐藏时自动藏鼠标指针 | 原版HUD隐藏后指针隐藏到下一次移动，唤醒/退出恢复；Win仅改变HUD透明度和可命中性，未设置 ProtectedCursor/光标隐藏。 | [62] | [63] |
| P25 | 部分 | 持续缓冲时保留已展开HUD | 原版把缓冲纳入禁止自动隐藏条件，不会因此强弹HUD；Win3秒隐藏条件仅检查 playing、scrubbing、菜单、hover、focus，不检查 Buffering。 | [64] | [65] |
| P26 | 部分 | 读屏辅助功能下保留HUD | 原版 VoiceOver 开启会禁止HUD自动收起；Win已有控件Automation名称和键盘焦点保护，但没有读屏开启条件，Narrator运行时仍按普通3秒规则隐藏。 | [66] | [65] |
| P27 | 缺失 | 按视频比例自动调整窗口并恢复 | 原版视频尺寸就绪后fit窗口比例，退出还原原窗口尺寸；Win只监听用户窗口变化去Resize原生surface，不按视频尺寸调整窗口。恢复全屏presenter已经有，不等于恢复按比例调整的窗口。 | [67] [68] | [69] [70] |
| P28 | 缺失 | “跳过片头”悬浮按钮 | 原版位于有效片头区间时显示，点击跳区间末尾并避免重复提示；Win没有SkipPrompt UI/状态。 | [71] [72] | [73] |
| P29 | 缺失 | “跳过片尾”悬浮按钮 | 原版支持准确片尾区间，并在最后90秒提供保底跳过（按设置保留尾声，尾部0.5秒保护）；Win只有普通±10秒/时间轴/章节跳转。 | [74] [75] | [76] |
| P30 | 缺失 | 服务器MediaSegments片头/尾识别 | 原版读服务端Intro/Outro区间，作为最高优先级；Win章节服务只调用 browse.chapters，无mediaSegments调用。 | [77] | [78] |
| P31 | 缺失 | 章节名/位置推断片头片尾 | 原版支持OP/ED等名字及位置/时长兜底、相邻同类章节合并、电影较长片尾上限；Win只构建Name/Start/End供手动跳章节，没有识别规则。 | [79] | [80] |
| P32 | 缺失 | AniSkip片头时间源 | 原版以社区标注补充片头提示；Win danmaku请求明确 aniSkip.enabled=false，播放器也无另一条查询/消费链。 | [81] [82] | [83] |
| P33 | 缺失 | anime-skip片头时间源 | 原版有配置Client ID后启用的社区时间戳；Win provider关闭且无播放器消费链。 | [84] | [83] |
| P34 | 缺失 | TheIntroDB片头时间源 | 原版用TMDB身份查TheIntroDB；Win provider关闭且无播放器消费链。 | [85] | [83] |
| P35 | 缺失 | 弹幕报点推断片头 | 原版将弹幕推导的introHint传给播放器，低于服务器/社区信号优先级；Win弹幕加载只渲染，无将introHint变成SkipPrompt的调用。 | [86] [87] | [88] |
| P36 | 缺失 | 从用户快进学习片头 | 原版监听主动seek，持久化学习，后续同作品用于片头提示并按来源优先级合并；Win Seek/SetPosition只更新时间轴/内核，不记学习。 | [89] [90] | [91] |
| P37 | 缺失 | 播放卡住的诊断监测 | 原版在非暂停非缓冲下检测位置不前进，记录stall与恢复事件；Win只轮询状态/进度，没有宿主stall识别。此项是故障诊断能力，非新增按钮。 | [92] | [58] |

### 交互口径差异（有替代操作，不计为整项功能缺失）

| 编号 | 差异 | 证据 |
|---|---|---|
| B01 | 上下方向键原版每次音量±10%，Windows为±5%。 | [93] [94] |
| B02 | 原版点击滑块后，空格/方向键仍归播放器；Windows有键盘焦点的Slider、Button会保留控件自身键行为，播放器不接管。该差异是原生控件选择，是否要求严格一致由产品决定。 | [95] [96] |
| B03 | 原版静音为独立mute状态，滑块保留原音量；Windows把滑块直接归零，再用_previousVolume恢复。 | [97] [21] |
| B04 | 原版字幕侧车下载最多4并发并按原顺序挂载；新Windows实现逐个await下载，且整批2分钟超时。大量侧车字幕/慢源加载体验未对齐。 | [98] [99] |
| B05 | 原版常规开关键忽略autorepeat；Windows KeyboardAccelerator没有显式重复抑制，实际系统是否重入需要按住Space/Enter/M/F实测，不直接判为已发生缺陷。 | [100] [101] |
| B06 | 原版±10秒快进等有距片尾0.5秒的seek保护；Win可钳到精确片长。内核版本影响实际结果，应针对EOF播放错误实测。 | [102] [76] |

### 已对齐的重要按钮与选项（防止误报）

- 返回、顶部全屏、双击全屏、单击HUD、播放/暂停、前后10秒、时间轴拖拽、当前位置/总时长、集号与剧名、音量滑块和静音都已有；Space/Enter/←/→/J/L/↑/↓/M/F/Esc均有绑定。
- “更多”→播放速度的 **0.5、0.75、1、1.25、1.5、2倍**完全一致，没有缺1.75倍（原版本来也无该选项）。播放信息、画面截图、条件分享已接入；不能再写成缺失。
- 音轨单选、无多音轨提示；字幕轨道单选、关闭字幕、打开外挂字幕（ASS/SSA/SRT/VTT）、外挂显示名；字幕字号减小/重置/加大（50%–300%、10%步进）已有。缩放偏好落盘、恢复及开片应用现已接上。
- 服务器章节列表、时间点、点击跳转、当前章节播放高亮现已接入；Win额外有章节加载/失败重试状态。不能再写“没有章节功能”。
- HUD3秒隐藏、菜单/滑块拖动/键盘焦点期间保留、窗口变窄调整尺寸、系统减弱动画、出错提示、原生进度保存/续播、服务器开始/进度/停止上报已有。
- 服务端侧车字幕已补齐到调用链：`PlayerView.ServerSubtitles.cs`与`ServerSubtitleService.cs`已有下载、取消、换片隔离、失败重试和中文兜底。04:17最终复查已确认主播放器在101/180/204行分别调用ResetServerSubtitles、StartServerSubtitlesIfReady、DisposeServerSubtitles，**不再属于待接线或整项缺失**；自动语言偏好差异见P08。

### Apple平台能力与待验证项

- iOS画面手势：双击播放暂停、长按临时2×、横滑进度预览/松手提交、左半屏纵滑亮度、右半屏纵滑系统音量，Windows没有等价触屏手势；这是相对iOS端的差异，不能冒充macOS现有功能。源：[103] [104]。
- iOS后台仅音频播放、前后台解码恢复、音频中断后恢复、系统音量桥、刘海/灵动岛安全区属于平台专属；Windows最小化/换音频设备效果应单测，而不是照抄UIKit机制。源：[105] [106]。
- 原版macOS会上报当前屏幕EDR headroom并随换屏更新；Windows适配器固定OutputMode=3、headroom=10000/203，但Windows原生输出链可能自行探测能力。现有代码足以确认信息面板字段缺失（P03/P04），不足以直接判定HDR/杜比视觉效果缺失；需SDR/HDR双屏实测。源：[107] [108]。
- 原版本地文件并未提供独立容器章节提取（只服务端章节+保底片尾），因此不把“本地章节提取”当Windows落后项；画中画也不能因占位图标像PiP就写为原版现有功能。

### 证据定位

[109]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/PlaybackKit/Sources/PlaybackKit/SubtitleSelection.swift#L11> "SubtitleLanguagePreference"

[1]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift#L555> "App/Shared/Features/Player/PlayerHUDActions.swift:555"
[2]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:126> "src/OcPlayer.Windows/Features/PlayerView.More.cs:126"
[3]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift#L693> "App/Shared/Features/Player/PlayerHUDActions.swift:693"
[4]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController+Tracks.swift#L258> "App/Shared/Features/Player/PlaybackController+Tracks.swift:258"
[5]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Tracks.cs:177> "src/OcPlayer.Windows/Features/PlayerView.Tracks.cs:177"
[6]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:195> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:195"
[7]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDChrome.swift#L317> "App/Shared/Features/Player/PlayerHUDChrome.swift:317"
[8]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:187> "src/OcPlayer.Windows/Features/PlayerView.More.cs:187"
[9]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDChrome.swift#L139> "App/Shared/Features/Player/PlayerHUDChrome.swift:139"
[10]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDChrome.swift#L375> "App/Shared/Features/Player/PlayerHUDChrome.swift:375"
[11]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:42> "src/OcPlayer.Windows/Features/PlayerView.More.cs:42"
[12]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:216> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:216"
[13]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L153> "App/Shared/Features/Player/PlaybackController.swift:153"
[14]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift#L33> "App/Shared/Features/Player/PlaybackPreferences.swift:33"
[15]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:26> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:26"
[16]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:271> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:271"
[17]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L162> "App/Shared/Features/Player/PlaybackController.swift:162"
[18]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml:77> "src/OcPlayer.Windows/Features/PlayerView.xaml:77"
[19]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:70> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:70"
[20]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L181> "App/Shared/Features/Player/PlaybackController.swift:181"
[21]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:426> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:426"
[22]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController+Tracks.swift#L306> "App/Shared/Features/Player/PlaybackController+Tracks.swift:306"
[23]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:113> "src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:113"
[24]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L923> "App/Shared/Features/Player/PlayerScreen.swift:923"
[25]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1944> "App/Shared/Features/Player/PlaybackController.swift:1944"
[26]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:77> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:77"
[27]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L166> "App/Shared/Features/Player/PlayerScreen.swift:166"
[28]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml:161> "src/OcPlayer.Windows/Features/PlayerView.xaml:161"
[29]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.More.cs:174> "src/OcPlayer.Windows/Features/PlayerView.More.cs:174"
[30]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreenComponents.swift#L7> "App/Shared/Features/Player/PlayerScreenComponents.swift:7"
[31]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L458> "App/Shared/AppModel+Playback.swift:458"
[32]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:271> "src/OcPlayer.Windows/MainWindow.xaml.cs:271"
[33]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:122> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:122"
[34]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreenComponents.swift#L124> "App/Shared/Features/Player/PlayerScreenComponents.swift:124"
[35]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L844> "App/Shared/AppModel+Playback.swift:844"
[36]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:259> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:259"
[37]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackOpenError.swift#L24> "App/Shared/Features/Player/PlaybackOpenError.swift:24"
[38]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1132> "App/Shared/Features/Player/PlaybackController.swift:1132"
[39]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:57> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:57"
[40]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:85> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:85"
[41]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L99> "App/Shared/AppModel+Playback.swift:99"
[42]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/JellyfinKit/Sources/JellyfinKit/PlaybackPreparationWorkflow.swift#L87> "Packages/JellyfinKit/Sources/JellyfinKit/PlaybackPreparationWorkflow.swift:87"
[43]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:273> "src/OcPlayer.Windows/Services/MediaServer.cs:273"
[44]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/JellyfinKit/Sources/JellyfinKit/PlaybackInfo.swift#L127> "Packages/JellyfinKit/Sources/JellyfinKit/PlaybackInfo.swift:127"
[45]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/MediaServer.cs:276> "src/OcPlayer.Windows/Services/MediaServer.cs:276"
[46]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L202> "App/Shared/AppModel+Playback.swift:202"
[47]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L211> "App/Shared/AppModel+Playback.swift:211"
[48]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:5> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:5"
[49]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:254> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:254"
[50]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L907> "App/Shared/AppModel+Playback.swift:907"
[51]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L918> "App/Shared/AppModel+Playback.swift:918"
[52]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:119> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:119"
[53]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L921> "App/Shared/AppModel+Playback.swift:921"
[54]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L924> "App/Shared/AppModel+Playback.swift:924"
[55]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:125> "src/OcPlayer.CoreAdapter/PlaybackSession.cs:125"
[56]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackWakeLock.swift#L27> "App/Shared/Features/Player/PlaybackWakeLock.swift:27"
[57]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L443> "App/Shared/Features/Player/PlaybackController.swift:443"
[58]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:168> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:168"
[59]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackNowPlayingCenter.swift#L195> "App/Shared/Features/Player/PlaybackNowPlayingCenter.swift:195"
[60]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackNowPlayingCenter.swift#L274> "App/Shared/Features/Player/PlaybackNowPlayingCenter.swift:274"
[61]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:75> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:75"
[62]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L772> "App/Shared/Features/Player/PlayerScreen.swift:772"
[63]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/PlayerHudVisibilityController.cs:31> "src/OcPlayer.Windows/Services/PlayerHudVisibilityController.cs:31"
[64]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDGates.swift#L17> "App/Shared/Features/Player/PlayerHUDGates.swift:17"
[65]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:194> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:194"
[66]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDGates.swift#L23> "App/Shared/Features/Player/PlayerHUDGates.swift:23"
[67]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L421> "App/Shared/Features/Player/PlayerScreen.swift:421"
[68]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/macOS/PlayerWindowFitter.swift#L1> "App/macOS/PlayerWindowFitter.swift:1"
[69]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:297> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:297"
[70]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:324> "src/OcPlayer.Windows/MainWindow.xaml.cs:324"
[71]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L220> "App/Shared/Features/Player/PlayerScreen.swift:220"
[72]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift#L1004> "App/Shared/Features/Player/PlayerHUDActions.swift:1004"
[73]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml:118> "src/OcPlayer.Windows/Features/PlayerView.xaml:118"
[74]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackChapter.swift#L338> "App/Shared/Features/Player/PlaybackChapter.swift:338"
[75]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1773> "App/Shared/Features/Player/PlaybackController.swift:1773"
[76]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:264> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:264"
[77]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1841> "App/Shared/Features/Player/PlaybackController.swift:1841"
[78]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/PlaybackChapters.cs:17> "src/OcPlayer.Windows/Services/PlaybackChapters.cs:17"
[79]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackChapter.swift#L147> "App/Shared/Features/Player/PlaybackChapter.swift:147"
[80]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/PlaybackChapters.cs:50> "src/OcPlayer.Windows/Services/PlaybackChapters.cs:50"
[81]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackChapter.swift#L48> "App/Shared/Features/Player/PlaybackChapter.swift:48"
[82]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L365> "App/Shared/Features/Player/DanmakuCoordinator.swift:365"
[83]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:134> "src/OcPlayer.Windows/Services/DanmakuService.cs:134"
[84]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L377> "App/Shared/Features/Player/DanmakuCoordinator.swift:377"
[85]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L380> "App/Shared/Features/Player/DanmakuCoordinator.swift:380"
[86]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L767> "App/Shared/Features/Player/DanmakuCoordinator.swift:767"
[87]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1756> "App/Shared/Features/Player/PlaybackController.swift:1756"
[88]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuCoordinator.cs:1> "src/OcPlayer.Windows/Services/DanmakuCoordinator.cs:1"
[89]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L789> "App/Shared/Features/Player/DanmakuCoordinator.swift:789"
[90]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1664> "App/Shared/Features/Player/PlaybackController.swift:1664"
[91]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:263> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:263"
[92]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1388> "App/Shared/Features/Player/PlaybackController.swift:1388"
[93]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L961> "App/Shared/Features/Player/PlayerScreen.swift:961"
[94]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:79> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:79"
[95]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L914> "App/Shared/Features/Player/PlayerScreen.swift:914"
[96]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:291> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:291"
[97]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1968> "App/Shared/Features/Player/PlaybackController.swift:1968"
[98]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/AppModel+Playback.swift#L1116> "App/Shared/AppModel+Playback.swift:1116"
[99]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:56> "src/OcPlayer.Windows/Features/PlayerView.ServerSubtitles.cs:56"
[100]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L947> "App/Shared/Features/Player/PlayerScreen.swift:947"
[101]: <D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.xaml.cs:283> "src/OcPlayer.Windows/Features/PlayerView.xaml.cs:283"
[102]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1638> "App/Shared/Features/Player/PlaybackController.swift:1638"
[103]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L471> "App/Shared/Features/Player/PlayerScreen.swift:471"
[104]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L518> "App/Shared/Features/Player/PlayerScreen.swift:518"
[105]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController.swift#L1423> "App/Shared/Features/Player/PlaybackController.swift:1423"
[106]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackAudioInterruptions.swift#L1> "App/Shared/Features/Player/PlaybackAudioInterruptions.swift:1"
[107]: <https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerScreen.swift#L337> "App/Shared/Features/Player/PlayerScreen.swift:337"
[108]: <D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/ErikaPresenter.cs:17> "src/OcPlayer.CoreAdapter/ErikaPresenter.cs:17"



---

## 设置、维护与弹幕精细审计（2026-11-16）

基准：OcPlayer 固定提交 `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`；Windows 当前工作树（包含未提交新增文件）。仅审查源码与调用链，没有把 Demo 外观或 Core 孤立能力当成真实功能，也没有声称完成实机端到端验收。

范围：设置每个选项、TMDB配置、维护/更新/许可、弹幕操作和匹配。媒体服务器管理完整流程、Bangumi/MoviePilot镜像与账号业务、播放器通用功能分别见主报告/对应片段，避免重复计数。

特别说明：Windows 弹幕搜索代码在审计期间发生并发更新；最终复读时“当前匹配 / 作品类型 / Episode ID / 清空集数重新搜索”已经接通，本片段不再把它们列缺失。

### 设置及应用维护缺口

[DemoSettings.cs:43][sdref79] 表明真实模式除首页栏目外全部走 RuntimeSubpage。Bangumi/MoviePilot另由 [MainWindow.xaml.cs:181][sdref80] 转交真实 IntegrationPages，因此不能把它们误判为 DemoSettings 的占位页。下面“Win缺失”指真实运行路径。

| ID | 状态 | 功能/选项 | 细节与缺口 | OcPlayer证据 | Windows证据 |
|---|---|---|---|---|---|
| S-001 | 缺失 | 启动时默认服务器选择 | 原版可选“上次使用的服务器”或任一保存服务器；Win 只恢复唯一 active-server，没有此选择。不是 Demo 的“不自动连接”假选项。 | [SettingsPagesIntegrations.swift:41][sdref5] | [CoreRuntime.cs:39][sdref6] |
| S-002 | 缺失 | 自定义全局 User-Agent | 空值用默认；输入控制字符过滤；媒体浏览与拉流即时生效且无需重新连接。Win 真实“网络”页只有待开放说明。 | [SettingsPagesNetwork.swift:20][sdref7] | [DemoSettings.cs:146][sdref4] |
| S-003 | 缺失 | 网络预读缓冲 | 默认（2 MiB）、8、16、32 MiB；原版持久化并在开流时传内核。Win 真实设置无控件，Open 只传 uri/httpHeaders。 | [SettingsPagesPlayback.swift:41][sdref8] | [DemoSettings.cs:122][sdref1]；[PlaybackSession.cs:79][sdref9] |
| S-004 | 缺失 | 回退缓冲 | 默认（16 MiB）、32、64、128 MiB；Win 真实模式缺全部选择，Demo 连 128 MiB 也缺。 | [SettingsPagesPlayback.swift:55][sdref10]；[PlaybackPreferences.swift:291][sdref11] | [DemoSettings.cs:122][sdref1] |
| S-005 | 缺失 | 跳过片头开关 | 原版默认开且播放中改动即时生效；Win 真实播放设置无此偏好。具体跳过执行链路见播放器审计。 | [SettingsPagesPlayback.swift:71][sdref12] | [DemoSettings.cs:122][sdref1] |
| S-006 | 缺失 | 跳过片尾开关 | 原版默认开；关闭后禁用“片尾保留”。Win 真实设置无此开关及联动。 | [SettingsPagesPlayback.swift:76][sdref13] | [DemoSettings.cs:122][sdref1] |
| S-007 | 缺失 | 片尾保留档位 | 不保留、5、10（默认）、15、20、30 秒；不保留也停在结束前 0.5 秒。Win 真实模式缺全套，Demo 还缺 20/30 秒。 | [SettingsPagesPlayback.swift:81][sdref14]；[PlaybackPreferences.swift:322][sdref15] | [DemoSettings.cs:122][sdref1] |
| S-008 | 缺失 | 默认字幕语言 | 中文优先（简体）、中文优先（繁体）、跟随文件默认、默认关闭；手选本片轨道后不再自动覆盖。Win Demo 的 English 不能代替原版的默认关闭，真实模式没有选择。 | [SettingsPagesPlayback.swift:95][sdref16]；[SettingsPagesPlayback.swift:112][sdref17] | [DemoSettings.cs:122][sdref1] |
| S-009 | 缺失 | 字幕位置 | 不设置、底部居中、左下角、右下角、顶部居中，修改后实时应用。Win 真实模式缺失，Demo 只画了不设置/底部/顶部。 | [SubtitleAppearanceSection.swift:40][sdref18]；[SubtitleAppearanceSection.swift:215][sdref19] | [DemoSettings.cs:122][sdref1] |
| S-010 | 缺失 | 字幕上下边距 | 0=不设置，0–200，步长10；可还原为不干预。 | [SubtitleAppearanceSection.swift:49][sdref20] | [DemoSettings.cs:122][sdref1] |
| S-011 | 缺失 | 字幕颜色 | 任意 RGBA 颜色（含透明度）、显示色值、单独“还原”为不设置；不是只有白/黄。 | [SubtitleAppearanceSection.swift:58][sdref21]；[SubtitleAppearanceSection.swift:180][sdref22] | [DemoSettings.cs:122][sdref1] |
| S-012 | 缺失 | 描边颜色 | 任意 RGBA 颜色（含透明度）、显示色值、单独“还原”为不设置；不是只有黑色。 | [SubtitleAppearanceSection.swift:66][sdref23]；[SubtitleAppearanceSection.swift:180][sdref24] | [DemoSettings.cs:122][sdref1] |
| S-013 | 缺失 | 描边粗细 | 0=不设置，0–32，步长1；实时应用。 | [SubtitleAppearanceSection.swift:74][sdref25] | [DemoSettings.cs:122][sdref1] |
| S-014 | 缺失 | 字幕加粗三态 | 未设置/明确加粗/明确不加粗，以及设过后出现的“还原”按钮；Win Demo 的二态假开关也不完整。 | [SubtitleAppearanceSection.swift:85][sdref26]；[SubtitleAppearanceSection.swift:158][sdref27] | [DemoSettings.cs:122][sdref1] |
| S-015 | 缺失 | 覆盖字幕自带样式 | 默认关；关时只补缺值、开时覆盖 ASS 自带布局与特效，切换后实时应用；不支持当前内核时给说明。 | [SubtitleAppearanceSection.swift:98][sdref28] | [DemoSettings.cs:122][sdref1] |
| S-016 | 缺失 | 画质增强档位 | 关闭、ArtCNN F16、ArtCNN F32、ArtCNN F16 去噪；下次播放生效，并提示后端回退到原生采样。Win 真实无设置，Demo 的“2×”不等价；是否所有 Windows GPU 后端可执行另需实机验证。 | [PlaybackKernelSection.swift:70][sdref29]；[PlaybackTypes.swift:195][sdref30] | [DemoSettings.cs:122][sdref1] |
| S-017 | 部分 | 实际播放内核版本 | 原版内核名称带真实 version tag；Win 设置/关于仅写 Erika · D3D11 / WASAPI 或“Windows HDR 修复版本”，没有对应内核版本。Core版本不能替代内核版本。 | [PlaybackKernelSection.swift:36][sdref31] | [DemoSettings.cs:122][sdref1]；[DemoSettings.cs:116][sdref3] |
| S-018 | 缺失 | TMDB 凭据设置与替换 | 保存/替换 v3 API Key 或 v4 Read Access Token，已配置状态、空输入禁用提交。Win 真实 TMDB 整页为待开放。 | [SettingsPagesTMDb.swift:38][sdref32] | [DemoSettings.cs:146][sdref4] |
| S-019 | 缺失 | TMDB 元数据语言 | 简体中文、繁體中文、English、日本語、한국어五档；缺翻译字段回退英文。Win 真实无，Demo 也只有简体/English。 | [SettingsPagesTMDb.swift:97][sdref33]；[TMDbCoordinator.swift:346][sdref34] | [DemoSettings.cs:146][sdref4] |
| S-020 | 缺失 | TMDB 文本优先开关 | 可选以 TMDB 标题/简介/类型替换服务端，或只补缺字段。 | [SettingsPagesTMDb.swift:108][sdref35] | [DemoSettings.cs:146][sdref4] |
| S-021 | 缺失 | TMDB 图片替换开关 | 可选替换已有海报/背景/分集剧照，或只补缺图。 | [SettingsPagesTMDb.swift:118][sdref36] | [DemoSettings.cs:146][sdref4] |
| S-022 | 缺失 | 未入库剧集占位开关 | “显示未入库剧集占位”；不要求已有TMDB Key，允许已关联 Bangumi 章节兜底。实际占位表现见详情审计。 | [SettingsPagesTMDb.swift:80][sdref37] | [DemoSettings.cs:146][sdref4] |
| S-023 | 缺失 | TMDB 使用镜像源开关 | 原版默认关，可不配 Key 先改镜像；下次请求即时生效。 | [SettingsPagesTMDb.swift:275][sdref38] | [DemoSettings.cs:146][sdref4] |
| S-024 | 缺失 | TMDB API 镜像地址 | 可独立填写；只填域名补 /3，带自定义路径保留，非法值提示。 | [SettingsPagesTMDb.swift:289][sdref39] | [DemoSettings.cs:146][sdref4] |
| S-025 | 缺失 | TMDB 图片镜像地址 | 可独立填写；只填域名补 /t/p，粘图片URL自动去尺寸段；留空单独回官方，非法值提示。 | [SettingsPagesTMDb.swift:309][sdref40] | [DemoSettings.cs:146][sdref4] |
| S-026 | 缺失 | TMDB 最终请求地址预览 | 分别显示规范化后的“当前 API”和“当前图片”，帮助检查实际线路。 | [SettingsPagesTMDb.swift:330][sdref41] | [DemoSettings.cs:146][sdref4] |
| S-027 | 缺失 | TMDB 官方备用域快捷填充 | “填入官方备用域 …”按钮。 | [SettingsPagesTMDb.swift:334][sdref42] | [DemoSettings.cs:146][sdref4] |
| S-028 | 缺失 | TMDB 恢复官方直连 | 一次清空API/图片镜像并关掉镜像开关。 | [SettingsPagesTMDb.swift:338][sdref43] | [DemoSettings.cs:146][sdref4] |
| S-029 | 缺失 | 补全整个媒体库 | 整库补全电影/剧及各季；取消/退出后再次执行跳过已有成功结果。 | [SettingsPagesTMDb.swift:204][sdref44] | [DemoSettings.cs:146][sdref4] |
| S-030 | 缺失 | 批量补全进度与结果 | 显示完成/总数、当前标题、新补/跳过/匹配不上/失败/季数；显示上次结果及错误。 | [SettingsPagesTMDb.swift:210][sdref45] | [DemoSettings.cs:146][sdref4] |
| S-031 | 缺失 | 取消补全 | 批量进行中的取消按钮及取消后已处理数量。 | [SettingsPagesTMDb.swift:223][sdref46] | [DemoSettings.cs:146][sdref4] |
| S-032 | 缺失 | TMDB 已补全计数与清除 | 已补全条目数、清除TMDB补全数据、确认/取消、清除后反馈；对应关系与下载数据一起清。 | [SettingsPagesTMDb.swift:146][sdref47]；[SettingsPagesTMDb.swift:184][sdref48] | [DemoSettings.cs:146][sdref4] |
| S-033 | 缺失 | 图片缓存占用 | 实际已用/总容量；Win Demo写死140.8 MB / 536.9 MB，真实维护页不提供。 | [SettingsPagesMaintenance.swift:59][sdref49] | [DemoSettings.cs:141][sdref2] |
| S-034 | 缺失 | 清空图片缓存 | 清空按钮、确认/取消、清理期间禁用与刷新占用。 | [SettingsPagesMaintenance.swift:62][sdref50] | [DemoSettings.cs:141][sdref2] |
| S-035 | 缺失 | 媒体元数据缓存占用 | 实际数据库字节数、尚未就绪/不可用状态。 | [SettingsPagesMaintenance.swift:120][sdref51] | [DemoSettings.cs:141][sdref2] |
| S-036 | 缺失 | 清空媒体元数据缓存 | 清当前租户缓存、确认/取消与“已清空”反馈；不与图片清理混为一项。 | [SettingsPagesMaintenance.swift:124][sdref52] | [DemoSettings.cs:141][sdref2] |
| S-037 | 缺失 | 导出配置文件 | 导出JSON；含TMDB配置/Key、播放与字幕、弹幕、常规及镜像偏好；无服务器账号密码。Core已有 backup 命令但Win无入口或调用。 | [SettingsPagesMaintenance.swift:350][sdref53]；[SettingsPagesMaintenance.swift:418][sdref54] | [DemoSettings.cs:141][sdref2] |
| S-038 | 缺失 | 从文件恢复配置 | JSON选择、解码校验、覆盖恢复/取消；成功即时应用与失败提示。 | [SettingsPagesMaintenance.swift:372][sdref55] | [DemoSettings.cs:141][sdref2] |
| S-039 | 缺失 | 恢复前内容预览 | 显示导出时间/来源设备、TMDB Key尾部和语言、将恢复的各类偏好；不能用一个无内容确认框代替。 | [SettingsPagesMaintenance.swift:475][sdref56] | [DemoSettings.cs:141][sdref2] |
| S-040 | 缺失 | 详细日志开关 | 默认关；App最低日志级别立即改变，内核trace下次播放改变。Win Demo可见但只写内存字典，真实无。 | [SettingsPagesMaintenance.swift:174][sdref57] | [DemoSettings.cs:141][sdref2] |
| S-041 | 缺失 | 日志路径展开 | 点击“日志文件”在文件名与完整路径之间切换。 | [SettingsPagesMaintenance.swift:195][sdref58] | [DemoSettings.cs:141][sdref2] |
| S-042 | 缺失 | 日志记录数/大小 | 真实记录条数及字节数，后台读日志。 | [SettingsPagesMaintenance.swift:209][sdref59] | [DemoSettings.cs:141][sdref2] |
| S-043 | 缺失 | 最近日志记录查看 | 可展开最近记录、选择复制消息，展示级别/时间/抑制条数；无记录状态。 | [SettingsPagesMaintenance.swift:212][sdref60] | [DemoSettings.cs:141][sdref2] |
| S-044 | 缺失 | 导出诊断包 | 导出真实日志和诊断信息、保存文件与错误提示；Core拥有 export 能力不代表 Win UI已接通。 | [SettingsPagesMaintenance.swift:233][sdref61] | [DemoSettings.cs:141][sdref2] |
| S-045 | 缺失 | 清空日志 | 带确认/取消，清空后刷新日志摘要。 | [SettingsPagesMaintenance.swift:255][sdref62] | [DemoSettings.cs:141][sdref2] |
| S-046 | 缺失 | 弹幕诊断日志开关 | 默认关，立即控制时间轴/弹幕诊断；与详细日志是两个独立设置。 | [SettingsPagesMaintenance.swift:39][sdref63] | [DemoSettings.cs:141][sdref2] |
| S-047 | 缺失 | 应用版本与 Build | 原版显示 AppVersion.displayString；Win 真实关于只显示“Windows”和Core版本，无应用版本/Build。 | [SettingsPagesAbout.swift:21][sdref64] | [DemoSettings.cs:116][sdref3] |
| S-048 | 缺失 | 手动检查/重新检查更新 | 真实网络检查，检查中、已最新、发现新版状态，失败后“重试”。 | [SettingsPagesAbout.swift:80][sdref65] | [DemoSettings.cs:116][sdref3] |
| S-049 | 缺失 | 自动检查并提醒新版 | 原版启动后检查，并通过全局release sheet提醒；Win无相应调用。 | [OcPlayerApp.swift:165][sdref66]；[RootView.swift:260][sdref67] | [DemoSettings.cs:116][sdref3] |
| S-050 | 缺失 | 新版说明页 | 版本、发布日期、更新日志（可选择文本）、无日志兜底。 | [UpdateReleaseSheet.swift:20][sdref68] | [DemoSettings.cs:116][sdref3] |
| S-051 | 缺失 | 忽略此版本 | 持久化忽略版本并抑制自动提醒；设置页仍可重新查看已忽略新版。 | [UpdateReleaseSheet.swift:50][sdref69]；[SettingsPagesAbout.swift:117][sdref70] | [DemoSettings.cs:116][sdref3] |
| S-052 | 缺失 | 前往下载新版 | release sheet 的“前往下载”按钮，打开当前 Release 下载页面；Win 整块缺失。 | [UpdateReleaseSheet.swift:57][sdref71] | [DemoSettings.cs:116][sdref3] |
| S-053 | 缺失 | 开源许可证入口及项目数 | 真实关于页缺入口；Demo链接只导航到离线说明占位，不是许可证页。 | [SettingsPagesAbout.swift:34][sdref72] | [DemoSettings.cs:116][sdref3] |
| S-054 | 缺失 | 开源依赖清单/详情 | 按组列依赖和社区数据服务，名称、版本、许可证、用途；需按Windows实际依赖适配，不应照抄Swift组件。 | [OpenSourceLicensesView.swift:399][sdref73]；[OpenSourceLicensesView.swift:482][sdref74] | [DemoSettings.cs:116][sdref3] |
| S-055 | 缺失 | 依赖主页/许可链接与随包文本 | 组件详情可打开主页、许可证URL、阅读并选择复制随包许可证文本。 | [OpenSourceLicensesView.swift:494][sdref75] | [DemoSettings.cs:116][sdref3] |
| S-056 | 部分 | 首页栏目设置跨启动保存 | 上下移和显隐已存在，关闭行也保留；但Win HomeSections/HiddenSections仅为内存集合，重启丢失，真实Hub还未显示栏目数。首页具体表现由主报告覆盖。 | [SettingsPagesHomeSections.swift:13][sdref76] | [DemoViewModel.cs:18][sdref77]；[DemoSettings.cs:25][sdref78] |

### 弹幕缺口

| ID | 状态 | 功能/选项 | 细节与缺口 | OcPlayer证据 | Windows证据 |
|---|---|---|---|---|---|
| D-001 | 部分 | 字号菜单“减小 / 加大 / 重置” | 新版原版每次减/加10%（基准22pt，即2.2pt），偏离基准后出现“重置”。Win HUD仍为小18/标准22/大26/特大30四档，设置页数字框不能代替播放器内这三个操作。 | [PlayerHUDActions.swift:620][sdref81]；[PlaybackController+Tracks.swift:174][sdref82] | [PlayerView.DanmakuMenus.cs:101][sdref83] |
| D-002 | 部分 | 弹幕字号完整范围 | 原版50%–200%=11–44pt；Win验证和NumberBox仅允许14–36，11–13.9及36.1–44无法设。默认22已对齐。 | [PlaybackPreferences.swift:245][sdref84] | [DanmakuSettings.cs:28][sdref85]；[DanmakuSettingsEditor.cs:28][sdref86] |
| D-003 | 缺失 | 内核/App层弹幕渲染切换 | 原版“用内核渲染弹幕”可切换内核与App overlay，并下次播放生效（默认内核）。Win固定内核，真实设置无开关、无App overlay路线。不同平台不必移植同一个Swift渲染库，但用户可选第二路线的能力缺失。 | [SettingsPagesDanmaku.swift:62][sdref87] | [PlayerView.Danmaku.cs:27][sdref88]；[DanmakuSettingsEditor.cs:16][sdref89] |
| D-004 | 缺失 | anime-skip Client ID设置 | 原版可选填 Client ID 启用额外片头源；Win只在Demo有输入框，真实弹幕设置无此项。AniSkip/TheIntroDB/学习跳过执行链路见播放器审计。 | [SettingsPagesDanmaku.swift:53][sdref90] | [DanmakuSettingsEditor.cs:16][sdref91] |
| D-005 | 缺失 | 匹配/加载已等待秒数 | 原版显示“正在匹配 · Ns / 正在获取弹幕 · Ns”，HUD与选择页可见；Win只写静态状态，没有计时器与elapsed字段。 | [DanmakuCoordinator.swift:35][sdref92]；[DanmakuCoordinator.swift:662][sdref93] | [DanmakuCoordinator.cs:25][sdref94] |
| D-006 | 缺失 | 手动搜索作品别名 | 原版主关键词检索与Bangumi别名检索并发，短预算后合并去重；Win Search仅请求一次原始anime关键词。搜译名/原名时可能漏出原版能找到的结果。 | [DanmakuCoordinator.swift:538][sdref95] | [DanmakuService.cs:154][sdref96] |
| D-007 | 缺失 | 自动匹配作品别名 | 原版为orchestrator注入BangumiTitleAliasProvider；Win调用Core danmaku.load未传aliases；Core run只使用传入aliases，默认空，故单有共享匹配流程仍缺别名增强。 | [DanmakuCoordinator.swift:368][sdref97]；[DanmakuLoadOrchestrator.swift:1070][sdref98] | [DanmakuService.cs:117][sdref99]；[danmaku_load.rs:373][sdref100] |
| D-008 | 部分 | 规范化匹配文件名 | 原版 canonicalMatchName 避免在规范剧名/季/集后再拼原始文件名，防尾部裸数字误导匹配。Win仍拼“剧名 第N季 ENN 原始文件名”。不是完全没自动匹配，而是缺新版的规范化规则。 | [DanmakuCoordinator.swift:104][sdref101] | [DanmakuService.cs:76][sdref102] |
| D-009 | 部分 | 特典/OVA等专用匹配上下文 | 原版季0+集号与本地special关键词生成special target，使用special/extra/other命名空间及回退顺序。WinContext没有special字段、未调用对应规则、只传普通episode/season；Core虽支持special但未收到。手动SP类搜索已实现，不能替代自动特典识别。 | [DanmakuCoordinator.swift:234][sdref103]；[DanmakuCoordinator.swift:98][sdref104] | [DanmakuService.cs:9][sdref105]；[DanmakuService.cs:128][sdref106] |

### 已对齐、不要再列成缺失

- 设置Hub的三组/十个入口已齐；服务器连接/退出、Bangumi/MoviePilot真实账号设置均已接线。完整多服务器管理差异见主报告。
- 首页栏目上下移、显隐、关闭后仍能重新打开已有；差异是持久化和Hub值预览（S-056），不是整页缺失。
- 弹幕自动加载默认开；显示默认开；默认网关/公共额度、自定义HTTPS网关/API Key、安全持久化、保存校验、恢复默认已有。
- 弹幕启用、选择弹幕、重新匹配已有；偏移提前0.5/重置/延后0.5、范围±30s已有；不透明度25/50/75/100%、顶部区域25/50/75/100%已有。默认不透明度85%、区域75%与原版一致。
- 滚动/顶部/底部、合并重复、允许堆叠五个开关已有，默认都不屏蔽且合并/堆叠关闭；Win固定内核因此显示合并开关合理。证据：[PlayerView.Danmaku.cs:86][sdref107]、[PlayerView.DanmakuMenus.cs:96][sdref108]、[DanmakuSettings.cs:5][sdref109]。
- 真实手动搜索已支持作品名+集数、Enter、自动初搜、返回作品列表、选集加载、空输入禁搜、清空集数重新搜索、当前Episode关联、包含当前匹配、作品类型、每集ID和当前匹配标记。最终复查证据：[PlayerView.Danmaku.cs:128][sdref110]、[PlayerView.Danmaku.cs:155][sdref111]、[PlayerView.Danmaku.cs:191][sdref112]、[DanmakuService.cs:13][sdref113]。
- 本地XML/JSON弹幕导入、远程指纹、本地身份/父目录推断、自动匹配/重匹配、手动纠错缓存、换片取消、防过期结果、无匹配/空弹幕/失败状态已有。源码证据为[DanmakuService.cs:40][sdref114]、[DanmakuService.cs:100][sdref115]、[DanmakuCoordinator.cs:18][sdref116]；这不等同于所有媒体源的实机正确率已验收。

### 不计为确定缺失的边界/待验

- 原版只有一个已注册内核。不能因为Windows没有多内核Picker，就声称少了可用第二内核；原版的选择器仅在注册数>1时才出现。画质增强是独立已存在功能，已单列S-016。
- AirDrop/iCloud/Time Machine是Apple系统能力；缺失的是可移植的JSON导出/恢复功能，不是要求Windows复制Apple分享渠道。
- 原版有定期清理应用管理的字幕/截图/弹幕目录（[StorageMaintenance.swift:127][sdref117]），Windows App层未找到同等调度。但不同输出目录/用户选择保存策略及Core缓存策略需联合评估，不把所有旧阈值逐个机械计为功能缺失。
- 原版新版弹幕配置弹窗文字说“API Key留空关闭网络弹幕”，但实际DandanplaySettingsStore仍会回落内置公共Key；本报告以执行代码为准，不将Win相同行为误判为少了关闭方式。
- Win现在保护自定义网关不会自动收到默认网关公共Key，且允许HTTP loopback用于测试；这是行为差异，不作为缺失功能。
- 原版当前SettingsHub没有单独“海报氛围背景”开关，旧9月源码中的该开关不计入11月基准缺口。

本片段共56项设置/维护差异与9项弹幕差异，合计65项（含部分实现）。表内某项有多个选项时已逐一枚举；不代表每个选项各算一项。Bangumi镜像、MoviePilot记住密码/静默重登由集成审计集中列出，避免重复计数。未修改产品源码，也未运行可能登录/清缓存/写账号的实机操作。

[sdref1]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:122
[sdref2]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:141
[sdref3]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:116
[sdref4]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:146
[sdref5]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L41
[sdref6]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/CoreRuntime.cs:39
[sdref7]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesNetwork.swift#L20
[sdref8]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift#L41
[sdref9]: D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:79
[sdref10]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift#L55
[sdref11]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift#L291
[sdref12]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift#L71
[sdref13]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift#L76
[sdref14]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift#L81
[sdref15]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift#L322
[sdref16]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift#L95
[sdref17]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift#L112
[sdref18]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L40
[sdref19]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L215
[sdref20]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L49
[sdref21]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L58
[sdref22]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L180
[sdref23]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L66
[sdref24]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L180
[sdref25]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L74
[sdref26]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L85
[sdref27]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L158
[sdref28]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift#L98
[sdref29]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/PlaybackKernelSection.swift#L70
[sdref30]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/PlaybackKit/Sources/PlaybackKit/PlaybackTypes.swift#L195
[sdref31]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/PlaybackKernelSection.swift#L36
[sdref32]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L38
[sdref33]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L97
[sdref34]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/TMDbCoordinator.swift#L346
[sdref35]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L108
[sdref36]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L118
[sdref37]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L80
[sdref38]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L275
[sdref39]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L289
[sdref40]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L309
[sdref41]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L330
[sdref42]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L334
[sdref43]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L338
[sdref44]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L204
[sdref45]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L210
[sdref46]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L223
[sdref47]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L146
[sdref48]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift#L184
[sdref49]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L59
[sdref50]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L62
[sdref51]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L120
[sdref52]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L124
[sdref53]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L350
[sdref54]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L418
[sdref55]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L372
[sdref56]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L475
[sdref57]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L174
[sdref58]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L195
[sdref59]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L209
[sdref60]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L212
[sdref61]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L233
[sdref62]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L255
[sdref63]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift#L39
[sdref64]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift#L21
[sdref65]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift#L80
[sdref66]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/OcPlayerApp.swift#L165
[sdref67]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/RootView.swift#L260
[sdref68]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/UpdateReleaseSheet.swift#L20
[sdref69]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/UpdateReleaseSheet.swift#L50
[sdref70]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift#L117
[sdref71]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/UpdateReleaseSheet.swift#L57
[sdref72]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift#L34
[sdref73]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/OpenSourceLicensesView.swift#L399
[sdref74]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/OpenSourceLicensesView.swift#L482
[sdref75]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/OpenSourceLicensesView.swift#L494
[sdref76]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesHomeSections.swift#L13
[sdref77]: D:/OcPlayer-Windows/src/OcPlayer.Windows/ViewModels/DemoViewModel.cs:18
[sdref78]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:25
[sdref79]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:43
[sdref80]: D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:181
[sdref81]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift#L620
[sdref82]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController+Tracks.swift#L174
[sdref83]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.DanmakuMenus.cs:101
[sdref84]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift#L245
[sdref85]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuSettings.cs:28
[sdref86]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DanmakuSettingsEditor.cs:28
[sdref87]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesDanmaku.swift#L62
[sdref88]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Danmaku.cs:27
[sdref89]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DanmakuSettingsEditor.cs:16
[sdref90]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesDanmaku.swift#L53
[sdref91]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DanmakuSettingsEditor.cs:16
[sdref92]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L35
[sdref93]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L662
[sdref94]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuCoordinator.cs:25
[sdref95]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L538
[sdref96]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:154
[sdref97]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L368
[sdref98]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/DanmakuKit/Sources/DanmakuKit/DanmakuLoadOrchestrator.swift#L1070
[sdref99]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:117
[sdref100]: D:/OcPlayer-Core/crates/ocp-core/src/danmaku_load.rs:373
[sdref101]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L104
[sdref102]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:76
[sdref103]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L234
[sdref104]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift#L98
[sdref105]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:9
[sdref106]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:128
[sdref107]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Danmaku.cs:86
[sdref108]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.DanmakuMenus.cs:96
[sdref109]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuSettings.cs:5
[sdref110]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Danmaku.cs:128
[sdref111]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Danmaku.cs:155
[sdref112]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Danmaku.cs:191
[sdref113]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:13
[sdref114]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:40
[sdref115]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:100
[sdref116]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuCoordinator.cs:18
[sdref117]: https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/StorageMaintenance.swift#L127



---

## OcPlayer 与 OcPlayer-Windows 集成功能精细审计（2026-11-16）

比较基线：OcPlayer 固定 GitHub 提交 `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`（已由主审计确认）；Windows 当前工作树，包含未提交文件。此片段覆盖 Bangumi、MoviePilot、观影空间；只做源码审计，未登录真实账号执行远程写操作。`缺失入口` 表示能力别处存在但原版该按钮/菜单入口尚未对齐；`协议差异` 有明确代码差异，需真实服务进一步验证结果。纯视觉风格不计为功能缺失。

原版引用均指向此次固定快照。Windows 正有其他任务修改，本文以最终复查时的代码为准。基础 Bangumi OAuth、动画五种收藏、章节看过/未看/看到此集、MoviePilot 订阅 CRUD、站点搜索/下载动作、观看热力图/按月切换/实播记录均已存在，不能整块列为未实现。

| ID | 状态 | 核对项 | Windows 缺口 / 原版行为 | 原版证据 | Windows 证据 |
|---|---|---|---|---|---|
| I-001 | 缺失 | Bangumi 搜索类型选项 | 原版有“全部、动画、书籍、游戏、音乐、三次元”；Windows 固定 subjectType=2，仅动画，缺其余五个筛选选项。 | [BH:364](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiHomeView.swift#L364) | [WI:181](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:181) |
| I-002 | 部分 | Bangumi 在看范围 | 原版在看进度模型覆盖动画及三次元；Windows Collections 固定 subjectType=2，真人剧等在看条目不进入片单/章节管理。 | [BDB:578](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/BangumiKit/Sources/BangumiKit/Database/BangumiDatabaseOperator.swift#L578) | [WS:127](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingIntegrations.cs:127) |
| I-003 | 缺失 | 在看排序菜单 | 缺“按收藏时间”“按放送时间”及跨启动记忆排序偏好。 | [BH:42](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiHomeView.swift#L42) | [WI:157](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:157) |
| I-004 | 缺失 | 在看列表内的本篇、SP 章节网格 | 原版不进详情即可逐集标记；Windows 收藏行只有“条目与章节”入口。 | [BH:625](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiHomeView.swift#L625) | [WI:169](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:169) |
| I-005 | 缺失 | 在看卡片的“看完下一集”快捷操作 | 缺自动找下一未看本篇、“看完 XX”按钮、“等待更新”“已看完”状态。 | [BH:768](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiHomeView.swift#L768) | [WI:169](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:169) |
| I-006 | 缺失 | 在看卡片的整季收藏状态菜单 | 缺列表内“待看/在看/看过/搁置/抛弃”菜单和当前项勾选；Windows 只能进详情修改。 | [BH:720](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiHomeView.swift#L720) | [WI:170](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:170) |
| I-007 | 缺失 | 在看进度展示 | 缺每条作品已看/总集数、进度条、章节尚未同步提示。 | [BH:702](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiHomeView.swift#L702) | [WI:169](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:169) |
| I-008 | 缺失 | Bangumi 个人主页 | 缺 @用户名、签名与个人主页入口；Windows 观影页已有头像/昵称，不能算完全缺用户身份展示。 个人页内退出登录入口也缺（Windows 设置中退出账号已存在）。 | [BP:47](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiProfileView.swift#L47) | [WD:19](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:19) |
| I-009 | 缺失 | 个人收藏的非动画类型 | 缺书籍、音乐、游戏、三次元四个收藏分区，以及每类全部五种收藏状态。 | [BP:17](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiProfileView.swift#L17) | [WS:127](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingIntegrations.cs:127) |
| I-010 | 缺失 | 五种收藏状态的数量 | 原版切换项带数量；Windows 片单下拉没有计数，观影页只另显示待看/在看/看过动画三项总数。 | [BC:117](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCollectionListView.swift#L117) | [WI:157](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:157) |
| I-011 | 缺失 | 收藏卡片信息 | 缺原名、播出年份、总话数/已看话数、全站评分、我的评分及收藏短评；Windows 通用 Item 仅标题、摘要、封面。 | [BC:215](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCollectionListView.swift#L215) | [WI:125](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:125) |
| I-012 | 缺失 | Bangumi 搜索结果信息 | 缺类型标识、评分、排名、已有收藏状态与原名；Windows 仅通用标题/摘要/封面。 搜索结果 info 行也未显示。 | [BH:819](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiHomeView.swift#L819) | [WI:125](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:125) |
| I-013 | 缺失 | 我的评分菜单全部十档 | 缺 10 超神作、9 神作、8 力荐、7 推荐、6 还行、5 不过不失、4 较差、3 差、2 很差、1 不忍直视，并缺当前评分展示/勾选。 | [BD:476](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L476) | [WI:196](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:196) |
| I-014 | 缺失 | 撤销评分 | 原版有当前评分时提供“撤销评分”，Windows 无评分写操作。 | [BD:506](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L506) | [WI:199](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:199) |
| I-015 | 缺失 | Bangumi 详情头部资料 | 缺封面、原名、条目类别、平台、开播日期、总话数、评分、排名、评分人数、已看话数。 | [BD:188](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L188) | [WI:196](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:196) |
| I-016 | 缺失 | Bangumi 作品信息 Infobox | 缺制作人员等完整键值信息区。 | [BD:655](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L655) | [WI:196](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:196) |
| I-017 | 缺失 | Bangumi 相关标签 | 缺前 20 个标签及使用数量。 | [BD:690](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L690) | [WI:196](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:196) |
| I-018 | 缺失 | Bangumi 全站收藏概况 | 缺想看、在看、看过、搁置、抛弃各项全站人数。 | [BD:716](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L716) | [WI:196](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:196) |
| I-019 | 缺失 | 简介展开/收起 | Windows 直接显示简介文本，没有“展开全文”“收起简介”开关。 | [BD:558](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L558) | [WI:196](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:196) |
| I-020 | 缺失 | 在浏览器中打开 Bangumi 条目 | 缺详情工具栏原站链接按钮。 | [BD:751](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L751) | [WI:187](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:187) |
| I-021 | 缺失 | 单集“想看” | Windows 只有标记看过、标记未看、看到此集，缺单集想看状态写入口。 | [BE:58](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiEpisodeCell.swift#L58) | [WI:207](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:207) |
| I-022 | 缺失 | 单集“抛弃” | Windows 无单集抛弃入口；共享 Core 的 update_episode_collection 目前还限制 collectionType 为 0..2，补 UI 时也需补协议层。 | [BE:58](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiEpisodeCell.swift#L58) | [WI:207](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:207) |
| I-023 | 缺失 | 章节分类切换 | 缺“本篇、SP、其他”三个分组、各组数量；Windows 平铺所有章节。 | [BD:599](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L599) | [WI:202](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:202) |
| I-024 | 部分 | 未播章节状态与禁用 | 原版 airdate 尚未到/未知显示“未播”且禁用修改；Windows 未检查开播日期，仍显示三个可点击按钮。 | [BE:29](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiEpisodeCell.swift#L29) | [WI:205](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:205) |
| I-025 | 部分 | “看到此集”的作用条件 | 原版只给已播本篇此操作；Windows 对 SP、其他、未播集也一律提供。 | [BE:59](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiEpisodeCell.swift#L59) | [WI:210](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:210) |
| I-026 | 协议差异 | 章节已看状态读取 | 原版 DTO 为 collection.status；Windows 读 collection.type，Core p1 章节接口原样透传。按原版契约将错误显示“未看”；当前 Win fixture 也人工使用 type，真实服务仍需复现验证。 | [BAS:562](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/BangumiKit/Sources/BangumiKit/Client/Basis.swift#L562) | [WI:206](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:206) |
| I-027 | 部分 | 未收藏与读取失败的区分 | 原版无收藏显示“加入收藏”，收藏读取失败保留既有状态；Windows 默认 SelectedIndex=2（在看），捕获 InvalidOperationException 后仍留“在看”，无法区分未收藏/读取失败。 | [BD:435](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L435) | [WI:197](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:197) |
| I-028 | 缺失 | 媒体库条目自动关联 Bangumi | 缺首次自动匹配和“自动匹配”按钮，Windows 只是按媒体标题跳 Bangumi 搜索。 | [BS:243](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiChapterSection.swift#L243) | [WP:156](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:156) |
| I-029 | 缺失 | 手动关联与重新关联 | 缺搜索候选、选择、确认关联和重新关联按钮；选中 Bangumi 详情不等于为媒体库条目保存关联。 | [BL:210](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiLinkPicker.swift#L210) | [WP:157](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:157) |
| I-030 | 缺失 | 按季保存关联 | 原版按剧/季保存关联，首季可回退剧级关联；Windows 无关联存储/季级映射。 | [BS:50](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiChapterSection.swift#L50) | [WP:157](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:157) |
| I-031 | 缺失 | 媒体详情内嵌真实 Bangumi 章节 | 缺详情内本篇/SP/其他章节管理及关联条目标题直达；Demo 网格只为示例，真实模式只有搜索按钮。 | [BS:195](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiChapterSection.swift#L195) | [WP:156](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoPages.cs:156) |
| I-032 | 缺失 | Bangumi 本地数据库快照及全收藏同步 | 原版先读本地条目/章节后远端刷新，首页可同步所有收藏；Windows 直接请求远端，仅保存账号，刷新片单只拉当前动画分类，无对应本地数据库消费。 | [BD:774](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L774) | [WS:124](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingIntegrations.cs:124) |
| I-033 | 缺失 | 完整放送日历星期筛选 | 缺“今天”、周一至周日单日筛选、“全部”及各项数量，缺默认定位今天；Windows 完整日历只把所有日分组往下铺。观影页的七日按钮不能替代完整日历过滤。 | [BA:289](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCalendarView.swift#L289) | [WI:223](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:223) |
| I-034 | 缺失 | 完整放送日历搜索 | 缺按中文名、原名、简介实时过滤；Windows 此页没有搜索框。 | [BA:101](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCalendarView.swift#L101) | [WI:223](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:223) |
| I-035 | 缺失 | 完整放送日历刷新/重试 | 原版有刷新工具栏和失败重试；Windows 完整日历只有首次加载，失败后需离开重进。 | [BA:486](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCalendarView.swift#L486) | [WI:227](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:227) |
| I-036 | 缺失 | 完整放送日历打开原站 | 缺打开 bgm.tv/calendar 按钮。 | [BA:477](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCalendarView.swift#L477) | [WI:223](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:223) |
| I-037 | 缺失 | 完整放送日历信息 | 缺年份/季度、全周总数、卡片原名/评分/评分人数/排名/放送日期/在看人数/个人收藏状态。 | [BA:280](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCalendarView.swift#L280) | [WI:232](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:232) |
| I-038 | 部分 | Bangumi 详情部分失败仍显示已有资料 | 原版先渲染本地详情并把章节刷新错误独立处理；Windows 先 await subject 再 await Episodes，章节失败时连标题/简介也未渲染。 | [BD:774](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiSubjectDetailView.swift#L774) | [WI:193](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:193) |
| I-039 | 缺失 | MoviePilot 订阅分类 | 缺“全部、电影、剧集”三项分类及各分类数量、追更中数量。 | [MH:413](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotHomeView.swift#L413) | [WI:241](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:241) |
| I-040 | 缺失 | 订阅卡片状态与进度 | 缺年份、季数、追更/暂停/完成徽章、评分、已下载/总集数/缺集数、下载进度条；Windows 列表仅通用 Item。 | [MH:932](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotHomeView.swift#L932) | [WI:248](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:248) |
| I-041 | 缺失 | 执行全站追更检索 | Windows“刷新追更”调用 subscription.refresh；缺另一个 subscription.search 动作，不能把两者视为同一功能。 | [MH:241](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotHomeView.swift#L241) | [WI:265](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:265) |
| I-042 | 缺失入口 | 订阅卡片“在 MoviePilot 刷新” | 原版卡片右键菜单还有此项；其实际执行的是全局刷新订阅，Windows 只有页面级刷新，卡片缺该入口。 | [MH:1003](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotHomeView.swift#L1003) | [WI:248](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:248) |
| I-043 | 缺失 | 快捷加入订阅 | 缺搜索结果菜单中的“快捷加入订阅”；Windows 只有打开编辑表单的“订阅…”。 | [MC:218](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotMediaGlassCard.swift#L218) | [WI:259](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:259) |
| I-044 | 缺失 | 已订阅识别与重复操作禁用 | 原版搜索结果根据订阅清单显示“已订阅”并禁用重复加入；Windows 每项始终有“订阅…”。 | [MC:235](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotMediaGlassCard.swift#L235) | [WI:259](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:259) |
| I-045 | 缺失 | MoviePilot 搜索结果辨识信息 | 缺年份、类型、评分、来源标签；同名多源条目在 Windows 通用 Item 中不易区分。 | [MC:126](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotMediaGlassCard.swift#L126) | [WI:125](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:125) |
| I-046 | 部分 | 从已选媒体进入资源页携带媒体身份 | 原版查资源直接带完整 MPMediaInfo；Windows 搜索结果/订阅“找资源”仅传 title，资源页必须重新搜索并选择媒体，既有来源 ID 和选择不随路由保留。 | [MH:43](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotHomeView.swift#L43) | [WI:249](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:249) |
| I-047 | 缺失 | 订阅编辑字段：年份 | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:242](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L242) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-048 | 缺失 | 订阅编辑字段：豆瓣 ID | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:271](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L271) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-049 | 缺失 | 订阅编辑字段：Bangumi ID | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:278](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L278) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-050 | 缺失 | 订阅编辑字段：起始集数（0–999） | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:293](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L293) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-051 | 缺失 | 订阅编辑字段：总集数（0=自动识别） | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:296](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L296) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-052 | 缺失 | 订阅编辑字段：缺失集数 | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:306](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L306) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-053 | 缺失 | 订阅编辑字段：包含关键词（逗号分隔） | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:332](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L332) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-054 | 缺失 | 订阅编辑字段：排除关键词（逗号分隔） | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:342](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L342) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-055 | 缺失 | 订阅编辑字段：分辨率/质量偏好：全部/默认、2160p、1080p、4K、WEB-DL、BluRay、Dolby Vision、HDR | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:355](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L355) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-056 | 缺失 | 订阅编辑字段：限定搜索站点：多选、使用全部站点、完成选择、加载失败重试 | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:365](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L365) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-057 | 缺失 | 订阅编辑字段：最佳版本洗版 | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:396](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L396) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-058 | 缺失 | 订阅编辑字段：自定义存储路径 | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:403](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L403) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-059 | 缺失 | 订阅编辑字段：海报链接 | Windows 新建/编辑只提供名称、类型、季、TMDB ID、状态、匹配关键词；该字段和相关控件均无入口。编辑时保留旧 raw 不等于可修改。 | [MS:413](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L413) | [WI:272](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:272) |
| I-060 | 协议差异 | 暂停/完成订阅状态编码 | 原版运行/暂停/完成为 R/P/O；Windows 为 R/S/D。原版 P/O 订阅在 Win 会被默认显示为“追更中”，保存又提交 S/D，需验证并修正服务兼容性。 | [MS:561](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L561) | [WI:276](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:276) |
| I-061 | 部分 | 从搜索结果新建订阅保留元数据 | 原版表单带入年份、各源 ID、海报、简介并写入；Windows 新建时从空 JsonObject 开始，仅六字段，丢失搜索结果这些附带资料。 | [MS:479](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotSubscribeSheet.swift#L479) | [WI:284](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:284) |
| I-062 | 缺失 | 资源精确筛选：站点 | 原版从当前结果聚合候选、多选精确匹配；Windows 仅标题 Contains 文本筛选。搜索前站点选择也不能替代返回结果的站点过滤。 | [MT:94](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L94) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-063 | 缺失 | 资源精确筛选：季/季集 | 原版从当前结果聚合候选、多选精确匹配；Windows 仅标题 Contains 文本筛选。搜索前站点选择也不能替代返回结果的站点过滤。 | [MT:95](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L95) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-064 | 缺失 | 资源精确筛选：促销（免费/普通/2x免费等） | 原版从当前结果聚合候选、多选精确匹配；Windows 仅标题 Contains 文本筛选。搜索前站点选择也不能替代返回结果的站点过滤。 | [MT:96](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L96) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-065 | 缺失 | 资源精确筛选：编码 | 原版从当前结果聚合候选、多选精确匹配；Windows 仅标题 Contains 文本筛选。搜索前站点选择也不能替代返回结果的站点过滤。 | [MT:97](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L97) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-066 | 缺失 | 资源精确筛选：质量/版本 | 原版从当前结果聚合候选、多选精确匹配；Windows 仅标题 Contains 文本筛选。搜索前站点选择也不能替代返回结果的站点过滤。 | [MT:98](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L98) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-067 | 缺失 | 资源精确筛选：分辨率 | 原版从当前结果聚合候选、多选精确匹配；Windows 仅标题 Contains 文本筛选。搜索前站点选择也不能替代返回结果的站点过滤。 | [MT:99](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L99) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-068 | 缺失 | 资源精确筛选：制作组 | 原版从当前结果聚合候选、多选精确匹配；Windows 仅标题 Contains 文本筛选。搜索前站点选择也不能替代返回结果的站点过滤。 | [MT:100](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L100) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-069 | 缺失 | 筛选组操作 | 每组缺“全选”“清除”，缺已选数量；原版选项均可逐项勾选。 | [MF:156](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotTorrentFilterBar.swift#L156) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-070 | 缺失 | 已选筛选条件管理 | 缺条件 chips、单个条件移除、清除全部筛选。 | [MF:227](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotTorrentFilterBar.swift#L227) | [WI:337](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:337) |
| I-071 | 缺失 | 资源排序五项 | 缺默认（站点优先级）、站点、大小、做种、时间五个可选排序字段。Windows 显示服务返回顺序，无本地排序入口。 | [MT:60](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/TorrentFilter.swift#L60) | [WI:341](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:341) |
| I-072 | 缺失 | 资源升序/降序与记忆 | 缺升降序按钮，以及字段/方向跨启动保存。 | [MF:100](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotTorrentFilterBar.swift#L100) | [WI:341](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:341) |
| I-073 | 缺失 | 资源搜索边到边显示 | 原版消费 SSE 批次、显示站点搜索进度、已收到条数且可边搜边下载；Windows await 全结果后一次 Render，状态仅“正在加载”。 | [MR:329](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotResourceView.swift#L329) | [WI:361](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:361) |
| I-074 | 缺失 | 资源结果详细标签 | 缺站点、免费标记、资源标签、文件体积、做种人数、发布时间；Windows 通用 Item 仅标题/描述。 | [MR:641](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotResourceView.swift#L641) | [WI:344](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:344) |
| I-075 | 缺失 | 结果数量与筛选命中数量 | 缺“资源 N”“命中 M / 总 N”显示，以及“筛掉全部 N 条”与“未搜索/未找到”的区分。 | [MR:303](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotResourceView.swift#L303) | [WI:356](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:356) |
| I-076 | 部分 | 资源大列表分窗/触底续载 | 原版 60 条展示窗口和触底继续加载；Windows 用 StackPanel 对全部结果逐条建控件，无分窗/虚拟化能力。 | [MR:619](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotResourceView.swift#L619) | [WI:341](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:341) |
| I-077 | 缺失 | 无 TMDB 编号提示 | 原版资源页对非 TMDB 来源提示自动刮削可能缺字段，并显示实际来源编号；Windows 仅通用“保留来源编号”说明。 | [MR:187](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotResourceView.swift#L187) | [WI:326](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:326) |
| I-078 | 缺失 | 下载列表每 5 秒自动刷新 | Windows 仅入页、动作完成或手动刷新才更新，任务进度不持续变化。原版还按前后台暂停/恢复轮询。 | [MD:67](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotDownloadsView.swift#L67) | [WI:320](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:320) |
| I-079 | 缺失 | 下载任务辨识资料 | 缺同时展示下载器原始任务名与媒体名、站点、总大小、下载队列总数；Windows 标题优先 media.title，只显示状态/速度/剩余时间。 | [MD:319](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotDownloadsView.swift#L319) | [WI:307](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:307) |
| I-080 | 部分 | 下载任务状态对应操作 | 原版根据暂停状态只显示开始或暂停，任务忙时整组替换转圈，暂停/近完成隐藏无意义速度/剩余时间；Windows 始终两个按钮且原始速度/剩余文本一直显示。 | [MD:380](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotDownloadsView.swift#L380) | [WI:309](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:309) |
| I-081 | 缺失提示 | 删除下载说明 | 原版确认框明示“只删下载器任务，已下载文件不会被删”；Windows 只有任务名和确定/取消。删除动作本身已接。 | [MD:72](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotDownloadsView.swift#L72) | [WI:313](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:313) |
| I-082 | 缺失入口 | MoviePilot 会话失效时直接重新登录 | 原版失效页/错误卡有“重新登录”弹窗；Windows 只报登录失效，需自行返回设置重新输入。 | [MH:170](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotHomeView.swift#L170) | [WI:27](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:27) |
| I-083 | 缺失 | 观影头像服务器优先规则 | 原版优先 Jellyfin/Emby 用户头像，缺省再回退 Bangumi；Windows 只尝试 Bangumi 头像，无媒体服务器头像来源。 | [YA:23](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/ViewingProfileAvatar.swift#L23) | [WD:20](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:20) |
| I-084 | 缺失 | 观影页快捷菜单中的 Bangumi 个人主页 | 原版“观影页面操作”含个人主页；Windows 没有对应路由。章节管理/MoviePilot/数据来源设置已有其他可达入口，不能整菜单判缺。 | [YH:125](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift#L125) | [WD:28](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:28) |
| I-085 | 缺失 | 番剧放送按显式关联匹配 | 原版媒体库手动关联优先，且已关联其他番剧不再按名错配；Windows 没有 links 输入，仅标题匹配。 | [YB:158](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyBroadcastTimeline.swift#L158) | [WB:44](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/BroadcastTimeline.cs:44) |
| I-086 | 缺失 | 番剧放送按外部编号匹配 | 缺 MAL、AniList、TMDB 剧级及季级（含父剧 TMDB ID）匹配；不同语种标题但 ID 相同会漏掉。 | [YB:171](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyBroadcastTimeline.swift#L171) | [WB:66](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/BroadcastTimeline.cs:66) |
| I-087 | 部分 | 番剧放送标题归一化 | 原版处理繁简、全半角、大小写、音调；Windows 仅 FormKC+字母数字+大写，缺繁简及音调折叠。 | [YB:192](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyBroadcastTimeline.swift#L192) | [WB:105](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/BroadcastTimeline.cs:105) |
| I-088 | 缺失 | 观影页下载摘要自动刷新 | 原版可见且前台时每 15 秒刷新；Windows 只进入/点刷新时读取。 | [YH:549](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift#L549) | [WD:103](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:103) |
| I-089 | 缺失 | 观影页观看记录自动刷新 | 原版前台可见时每 60 秒刷新、回前台和重新显示页面时刷新、监听播放记录改变；Windows 无对应轮询/激活监听。 | [YH:539](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift#L539) | [WD:115](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:115) |
| I-090 | 缺失 | 本月观看 TOP3 | 缺按作品汇总（剧集归到剧）前三名、各自时长与排行条。 | [YS:257](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingSection.swift#L257) | [WD:162](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:162) |
| I-091 | 部分 | 月观看柱图分类 | 原版逐日区分剧集、电影、本地/直连，带颜色图例与坐标；Windows 只一个总量色条，不能查看三类贡献。 | [YS:202](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingSection.swift#L202) | [WD:160](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:160) |
| I-092 | 部分 | 完整类型分布及统计口径 | 原版基于全部已同步记录，展示总时长、首要类型百分比、前三类+其余汇总；Windows 随所选月变化，只取前5项且不汇总余类，缺百分比文本与完整占比覆盖。 | [YS:282](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingSection.swift#L282) | [WD:169](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:169) |
| I-093 | 缺失 | 近 7 天类型趋势卡 | 缺近期前两种类型逐日趋势图、七日总时长。 | [YS:356](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingSection.swift#L356) | [WD:169](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:169) |
| I-094 | 缺失 | 与前 7 天类型时长对比 | 缺增减箭头、增减小时与“对比记录尚不足”。 | [YS:365](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingSection.swift#L365) | [WD:169](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:169) |
| I-095 | 缺失提示 | 统计数据覆盖与缺片长说明 | 缺统计更新时刻、从哪天开始同步、月统计仅覆盖部分日期、缺失片长的条目数；Windows 已有无观看日期计数，不能将该项重复算缺。 | [YS:79](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingSection.swift#L79) | [WD:188](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:188) |
| I-096 | 部分 | 实播记录采用服务器补充的类型 | 原版实播条目缺 genres 时用同条服务器记录补充；Windows Merge 直接用 latest 实播替换，未补 Category，类型统计可能把已知类型算成未分类。 | [YT:138](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingStatistics.swift#L138) | [WH:104](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingHistory.cs:104) |
| I-097 | 缺失 | 继续观看摘要信息 | 缺封面、剧名与本集名的分行展示、每条续播进度条；缺“媒体库”分区快捷入口。Windows 仍可点条目打开详情。 | [YH:325](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift#L325) | [WD:50](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:50) |
| I-098 | 缺失 | 观影订阅摘要信息 | 缺每项海报、季数、订阅状态、已下载/总集数/缺集数；Windows 只显示标题和整批缺集总数。 | [YH:614](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift#L614) | [WD:95](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:95) |
| I-099 | 缺失 | 放送摘要海报及数据来源链接 | Windows 仅文字时间按钮，无原版海报条；“bangumi-data”只是文本，没有打开数据来源的链接。 | [YH:260](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift#L260) | [WD:83](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:83) |
| I-100 | 缺失 | 最近/全部观看记录的封面与本集信息 | Windows HistoryRow 只有统一标题和时间/时长文本，缺海报、剧集所属作品标题和集名的分别展示。 最近观看入口也缺“全部 N 条”总数提示。 | [YS:463](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyViewingSection.swift#L463) | [WI:381](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:381) |
| I-101 | 缺失入口 | 观影页未连接账号的连接卡 | 原版启用服务但未登录时仍显示连接 Bangumi、连接 MoviePilot，没媒体服务器时有连接媒体库；Windows 仅有已连接且 Enabled 的模块，缺对应模块内连接入口。 | [YH:224](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/My/MyHomeView.swift#L224) | [WD:31](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/ViewingDashboard.cs:31) |
| I-102 | 缺失 | Bangumi 独立“使用镜像源”开关 | 原版镜像启停独立于账号且关闭时保留镜像配置；Windows 只有账号 API 地址输入，没有镜像开关。 | [SI:216](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L216) | [WI:73](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:73) |
| I-103 | 部分 | Bangumi 镜像根域与四路域名路由 | 原版根域同时派生 api、lain、next 和主站/授权地址，支持端口；Windows 可自定义 API，Cover 仅对以 api. 开头域名尝试替换 lain，缺 next/主站/授权同源映射以及完整根域规范化。 | [SI:262](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L262) | [WI:150](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:150) |
| I-104 | 缺失 | 镜像实际生效地址及输入错误提示 | 缺“当前 API”“当前图床”实际标准化地址，以及镜像根域专用问题提示。Windows 表单仅普通地址验证。 | [SI:240](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L240) | [WI:73](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:73) |
| I-105 | 缺失 | 镜像“填入示例”按钮 | 缺一键填入预置镜像根域。 | [SI:250](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L250) | [WI:73](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:73) |
| I-106 | 部分 | 镜像切换立即生效且保留登录态 | 原版无需重新登录，下一个请求及旧图片 URL 缓存失效即切换；Windows 改 API 后只能重新“验证并保存连接”，需再次提供 Token 或重走 OAuth。 | [SI:206](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L206) | [WI:107](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:107) |
| I-107 | 部分 | 恢复官方直连按钮 | Windows 已有“恢复官方 API 地址”，但仅改 TextBox 文本；原版同时清镜像配置、关闭镜像、立即恢复所有官方域名。不能把 Win 此按钮判为全缺。 | [SI:254](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L254) | [WI:113](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:113) |
| I-108 | 缺失 | MoviePilot 记住密码选项 | 缺“记住密码（令牌过期后免重输）”开关及关闭即清已存密码行为。Windows 登录只保存 accessToken，账号模型没有密码/rememberPassword。 | [SI:308](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L308) | [WS:97](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingIntegrations.cs:97) |
| I-109 | 缺失 | MoviePilot 令牌过期静默重新登录 | 原版选择记住密码后，401 自动单次重登并重放请求；Windows Mp 直接调用 Core，未携带保存密码/重登协调器，过期只能手工登录。 | [MAP:908](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/MoviePilotKit/Sources/MoviePilotKit/MoviePilotAPIClient.swift#L908) | [WS:104](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingIntegrations.cs:104) |
| I-110 | 部分 | 未登录时也能设置集成启停 | 原版 Bangumi/MoviePilot 开关独立于账号，未登录可关闭并保留该偏好；Windows 开关仅 account != null 时构建，未连接前没有启停开关。 | [SI:143](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L143) | [WI:63](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:63) |
| I-111 | 缺失确认 | 设置页退出 Bangumi/MoviePilot 确认 | 原版分别有退出确认及清除范围说明；Windows“退出”直接调用 Logout，无二次确认。退出功能本身已实现。 | [SI:175](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L175) | [WI:71](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:71) |
| I-112 | 部分 | 退出 MoviePilot 后保留服务器配置 | 原版清令牌/账号资料但保留服务器地址用于重新登录；Windows 从 PasswordVault 删除整个 IntegrationAccount，地址/用户名同时丢失。 | [SI:350](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift#L350) | [WS:66](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingIntegrations.cs:66) |
| I-113 | 缺失 | 页面内搜索框 Enter 提交 | 原版 Bangumi、MoviePilot、资源搜索支持提交键；Windows 这些页面 TextBox 没有提交键处理，必须点搜索按钮（顶栏 GlobalSearch Enter 已实现，属另一个入口）。 | [MR:215](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/MoviePilot/MoviePilotResourceView.swift#L215) | [WI:158](D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/IntegrationPages.cs:158) |
| I-114 | 部分 | Bangumi 长列表渐进显示/加载更多 | 原版片单及搜索使用分页 loader、触底/加载更多；Windows Pages 先取齐全部页面再 Render，且上限10000条，无先显示首批或继续加载入口。 | [BC:183](https://github.com/1824239290/OcPlayer/blob/888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Bangumi/BangumiCollectionListView.swift#L183) | [WS:136](D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/ViewingIntegrations.cs:136) |

补充核对与边界：

- I-026 的额外协议证据：Core 的 [p1 章节接口](D:/OcPlayer-Core/crates/ocp-bangumi/src/lib.rs:391) 返回原始 JSON；Windows [测试夹具](D:/OcPlayer-Windows/tests/OcPlayer.Integration/ViewingVerification.cs:178) 构造的是 `collection.type`。因此通过该夹具不能证明与原版 `collection.status` 兼容；此处没有声称已对真实账号复现。
- I-022 的额外 Core 限制：现有 [update_episode_collection 参数检查](D:/OcPlayer-Core/crates/ocp-bangumi/src/lib.rs:447) 只接受 0～2，原版“抛弃”是 3。
- 播放结束自动把 Bangumi 单集标为已看及整部完成的联动，由播放器审计记录；与本表 I-028～I-031 的持久关联缺口一起处理。
- Bangumi 镜像与 MoviePilot 记住密码/过期重登已补入 I-102～I-112；若总报告其他模块有对应项，请用交叉引用去重。
- 新原版 MoviePilot 详情页已经移除旧版“按 TMDB 本地拼媒体、按年份自动挑第一个”的逻辑，因此这些旧功能未计为 Windows 缺口。
- Windows 搜索前多选站点、Access Token 手动登录、资源页手动选择归属媒体是真实功能，不能因原版交互不同当作没有。
- Windows 已支持本地及服务器记录合并、同日实播优先、暂停/缓冲/跳转不计时、跨午夜拆分、近15周热图、月份前后切换、缺少观看日期提示；对应不足仅按表中具体项列出。
- 未把 macOS/iOS 原生手势、玻璃材质、平台弹窗外观计入集成功能缺口。



---

## 审计快照与文件范围

最终汇总时间（香港）：2026-11-16 04:20:52 +08:00。源文件哈希与Windows基准提交见[审计清单](D:/OcPlayer-Windows/reports/feature-audit-2026-11-16-source-manifest.json)。本次只新增审计文档和清单，未修改产品代码。
