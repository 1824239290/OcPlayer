# 设置、维护与弹幕精细审计（2026-11-16）

基准：OcPlayer 固定提交 `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`；Windows 当前工作树（包含未提交新增文件）。仅审查源码与调用链，没有把 Demo 外观或 Core 孤立能力当成真实功能，也没有声称完成实机端到端验收。

范围：设置每个选项、TMDB配置、维护/更新/许可、弹幕操作和匹配。媒体服务器管理完整流程、Bangumi/MoviePilot镜像与账号业务、播放器通用功能分别见主报告/对应片段，避免重复计数。

特别说明：Windows 弹幕搜索代码在审计期间发生并发更新；最终复读时“当前匹配 / 作品类型 / Episode ID / 清空集数重新搜索”已经接通，本片段不再把它们列缺失。

## 设置及应用维护缺口

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

## 弹幕缺口

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

## 已对齐、不要再列成缺失

- 设置Hub的三组/十个入口已齐；服务器连接/退出、Bangumi/MoviePilot真实账号设置均已接线。完整多服务器管理差异见主报告。
- 首页栏目上下移、显隐、关闭后仍能重新打开已有；差异是持久化和Hub值预览（S-056），不是整页缺失。
- 弹幕自动加载默认开；显示默认开；默认网关/公共额度、自定义HTTPS网关/API Key、安全持久化、保存校验、恢复默认已有。
- 弹幕启用、选择弹幕、重新匹配已有；偏移提前0.5/重置/延后0.5、范围±30s已有；不透明度25/50/75/100%、顶部区域25/50/75/100%已有。默认不透明度85%、区域75%与原版一致。
- 滚动/顶部/底部、合并重复、允许堆叠五个开关已有，默认都不屏蔽且合并/堆叠关闭；Win固定内核因此显示合并开关合理。证据：[PlayerView.Danmaku.cs:86][sdref107]、[PlayerView.DanmakuMenus.cs:96][sdref108]、[DanmakuSettings.cs:5][sdref109]。
- 真实手动搜索已支持作品名+集数、Enter、自动初搜、返回作品列表、选集加载、空输入禁搜、清空集数重新搜索、当前Episode关联、包含当前匹配、作品类型、每集ID和当前匹配标记。最终复查证据：[PlayerView.Danmaku.cs:128][sdref110]、[PlayerView.Danmaku.cs:155][sdref111]、[PlayerView.Danmaku.cs:191][sdref112]、[DanmakuService.cs:13][sdref113]。
- 本地XML/JSON弹幕导入、远程指纹、本地身份/父目录推断、自动匹配/重匹配、手动纠错缓存、换片取消、防过期结果、无匹配/空弹幕/失败状态已有。源码证据为[DanmakuService.cs:40][sdref114]、[DanmakuService.cs:100][sdref115]、[DanmakuCoordinator.cs:18][sdref116]；这不等同于所有媒体源的实机正确率已验收。

## 不计为确定缺失的边界/待验

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
[sdref5]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesIntegrations.swift:41
[sdref6]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/CoreRuntime.cs:39
[sdref7]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesNetwork.swift:20
[sdref8]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift:41
[sdref9]: D:/OcPlayer-Windows/src/OcPlayer.CoreAdapter/PlaybackSession.cs:79
[sdref10]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift:55
[sdref11]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift:291
[sdref12]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift:71
[sdref13]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift:76
[sdref14]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift:81
[sdref15]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift:322
[sdref16]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift:95
[sdref17]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesPlayback.swift:112
[sdref18]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:40
[sdref19]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:215
[sdref20]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:49
[sdref21]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:58
[sdref22]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:180
[sdref23]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:66
[sdref24]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:180
[sdref25]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:74
[sdref26]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:85
[sdref27]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:158
[sdref28]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SubtitleAppearanceSection.swift:98
[sdref29]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/PlaybackKernelSection.swift:70
[sdref30]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/PlaybackKit/Sources/PlaybackKit/PlaybackTypes.swift:195
[sdref31]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/PlaybackKernelSection.swift:36
[sdref32]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:38
[sdref33]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:97
[sdref34]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/TMDbCoordinator.swift:346
[sdref35]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:108
[sdref36]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:118
[sdref37]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:80
[sdref38]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:275
[sdref39]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:289
[sdref40]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:309
[sdref41]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:330
[sdref42]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:334
[sdref43]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:338
[sdref44]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:204
[sdref45]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:210
[sdref46]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:223
[sdref47]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:146
[sdref48]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesTMDb.swift:184
[sdref49]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:59
[sdref50]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:62
[sdref51]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:120
[sdref52]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:124
[sdref53]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:350
[sdref54]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:418
[sdref55]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:372
[sdref56]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:475
[sdref57]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:174
[sdref58]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:195
[sdref59]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:209
[sdref60]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:212
[sdref61]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:233
[sdref62]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:255
[sdref63]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesMaintenance.swift:39
[sdref64]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift:21
[sdref65]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift:80
[sdref66]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/OcPlayerApp.swift:165
[sdref67]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/RootView.swift:260
[sdref68]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/UpdateReleaseSheet.swift:20
[sdref69]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/UpdateReleaseSheet.swift:50
[sdref70]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift:117
[sdref71]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/UpdateReleaseSheet.swift:57
[sdref72]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesAbout.swift:34
[sdref73]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/OpenSourceLicensesView.swift:399
[sdref74]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/OpenSourceLicensesView.swift:482
[sdref75]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/OpenSourceLicensesView.swift:494
[sdref76]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesHomeSections.swift:13
[sdref77]: D:/OcPlayer-Windows/src/OcPlayer.Windows/ViewModels/DemoViewModel.cs:18
[sdref78]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:25
[sdref79]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DemoSettings.cs:43
[sdref80]: D:/OcPlayer-Windows/src/OcPlayer.Windows/MainWindow.xaml.cs:181
[sdref81]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlayerHUDActions.swift:620
[sdref82]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackController+Tracks.swift:174
[sdref83]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.DanmakuMenus.cs:101
[sdref84]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/PlaybackPreferences.swift:245
[sdref85]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuSettings.cs:28
[sdref86]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DanmakuSettingsEditor.cs:28
[sdref87]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesDanmaku.swift:62
[sdref88]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/PlayerView.Danmaku.cs:27
[sdref89]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DanmakuSettingsEditor.cs:16
[sdref90]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Settings/SettingsPagesDanmaku.swift:53
[sdref91]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Features/DanmakuSettingsEditor.cs:16
[sdref92]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:35
[sdref93]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:662
[sdref94]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuCoordinator.cs:25
[sdref95]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:538
[sdref96]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:154
[sdref97]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:368
[sdref98]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/Packages/DanmakuKit/Sources/DanmakuKit/DanmakuLoadOrchestrator.swift:1070
[sdref99]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:117
[sdref100]: D:/OcPlayer-Core/crates/ocp-core/src/danmaku_load.rs:373
[sdref101]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:104
[sdref102]: D:/OcPlayer-Windows/src/OcPlayer.Windows/Services/DanmakuService.cs:76
[sdref103]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:234
[sdref104]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/Features/Player/DanmakuCoordinator.swift:98
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
[sdref117]: D:/tmp/ocplayer-audit-reference-20261116/OcPlayer-888ccdd8a1098b4426166bb4b09b2f7dca3d8720/App/Shared/StorageMaintenance.swift:127

