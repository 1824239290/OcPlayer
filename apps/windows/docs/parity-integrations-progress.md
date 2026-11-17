# 集成功能补齐逐项进度（I-001–I-114）

当前收尾：统一原生/Debug/Release 构建、完整 **341 条**集成断言和观影空间/Bangumi/MoviePilot 的真实 WinUI 页面回归均已通过。OAuth 独立回调进程、个人收藏/评分选项、章节分类、日历筛选、资源排序及停用模块隐藏均有 UI 验证；请求使用本地或注入 fixture，未以真实外部账号写入。最终证据见 [补齐收尾报告](parity-completion-2026-11-16.md)。下方分工说明保留实现阶段历史。

本表逐项对应原审计。所有条目实现已落盘。integration.csproj 已构建成功（0 警告 / 0 错误）；ViewingVerification 与 IntegrationParityVerification 全部通过（reports/parity-integrations-recheck-20261116-3/verification.log），包含新增 SSE 渐进事件和 MAL/AniList/TMDB 季匹配。该轮在后续 Settings 别名断言失败；设置 agent 已继续修复，未修改或降低其断言。最近补充独立启停与 OAuth 拒绝后的重授权、评分快照更新，由设置 agent 的统一后续轮次回归。应用编译和 UI smoke 正由 root 验证，未完成前不将纯 UI 项标作最终验收。未登录真实外部账号做写入操作。

主要实现：BangumiPages.cs / MoviePilotPages.cs / MoviePilotResources.cs / IntegrationSettings.cs / ViewingDashboard.cs；服务：IntegrationPersistence.cs / MoviePilotPolicies.cs / ViewingAnalytics.cs / BroadcastTimeline.cs / ViewingHistory.cs。

| ID | 核对项 | 已接真实链路 / 实现位置 | 验证状态 |
|---|---|---|---|
| I-001 | Bangumi 搜索类型选项 | 六种搜索类型；search.subjectType 与选项一致；BangumiPages.CollectionBrowser | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-002 | Bangumi 在看范围 | 动画及三次元均可进入在看章节；Dashboard 使用 Watching 合并两类 | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-003 | 在看排序菜单 | 收藏时间 / 放送时间排序并持久保存；CollectionBrowser.sort | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-004 | 在看列表内的本篇、SP 章节网格 | 在看卡片内本篇 / SP / 其他章节网格；EpisodeOverview | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-005 | 在看卡片的“看完下一集”快捷操作 | 下一 status=0 的已播本篇、等待更新、完成/未同步提示；EpisodeOverview | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-006 | 在看卡片的整季收藏状态菜单 | 在看卡片内五种收藏状态且标识当前项；CollectionPicker | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-007 | 在看进度展示 | 卡片已看 / 总集数、进度条、尚未同步提示；EpisodeOverview | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-008 | Bangumi 个人主页 | 个人页昵称、@用户名、签名、原站链接和确认退出；Profile | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-009 | 个人收藏的非动画类型 | 动画 / 书籍 / 游戏 / 音乐 / 三次元与全部五种收藏状态；CollectionBrowser | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-010 | 五种收藏状态的数量 | 所选类别五种收藏状态总数；CollectionBrowser.Load | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-011 | 收藏卡片信息 | 卡片原名、播出日期、集数、全站/个人评分和短评；BangumiCard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-012 | Bangumi 搜索结果信息 | 搜索卡片类型、评分、排名、原名、info、收藏快照状态；BangumiCard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-013 | 我的评分菜单全部十档 | 未评分及 1–10 完整评分文案，当前值选中并写入 rate；Subject | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-014 | 撤销评分 | 撤销评分发送 rate=0；Subject | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-015 | Bangumi 详情头部资料 | 封面、原名、类型、platform.typeCN、日期、总集数、评分/排名/人数/进度；BangumiCard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-016 | Bangumi 作品信息 Infobox | 兼容 infobox.values/value、v/text/value 的全量键值；Subject | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-017 | Bangumi 相关标签 | 前 20 标签及每项使用次数；Subject | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-018 | Bangumi 全站收藏概况 | 五种全站收藏人数，兼容语义键与数字键；Subject | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-019 | 简介展开/收起 | 简介 5 行 / 全文切换；Subject | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-020 | 在浏览器中打开 Bangumi 条目 | 浏览器打开有效主站 subject 地址；Subject | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-021 | 单集“想看” | 章节菜单想看，写 collectionType=1；BuildEpisodeGroups | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-022 | 单集“抛弃” | 章节菜单抛弃，写 collectionType=3，Core 校验拓展至 0..3 | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-023 | 章节分类切换 | 本篇 / SP / 其他三个章节组及各组计数；BuildEpisodeGroups | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-024 | 未播章节状态与禁用 | airdate 未来或未知章节显示未播且按钮禁用；EpisodeAired | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-025 | “看到此集”的作用条件 | 只有已播本篇出现看到此集菜单，写 batch=true；BuildEpisodeGroups | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-026 | 章节已看状态读取 | 优先读取 collection.status，兼容遗留 type；EpisodeStatus；真实 fixture 已改 status | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-027 | 未收藏与读取失败的区分 | 收藏 request HTTP404 才视为未收藏；其他失败保留快照并提示；SubjectCollection | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-028 | 媒体库条目自动关联 Bangumi | 媒体详情首次自动唯一匹配及自动匹配按钮；MediaAssociation/AutoLinkBangumi | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-029 | 手动关联与重新关联 | 搜索候选、选择、确认关联、重新关联弹窗；MediaAssociation.Pick | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-030 | 按季保存关联 | 按服务器来源 / 剧 / 季保存 JSON 映射，第一季可回退剧级；ResolveBangumiLink | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-031 | 媒体详情内嵌真实 Bangumi 章节 | 媒体详情内嵌真实章节分组/状态操作及关联标题跳转；MediaAssociation | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-032 | Bangumi 本地数据库快照及全收藏同步 | 账号隔离快照、先读本地再刷新、全五类型/五状态收藏与章节同步；SynchronizeCollections | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-033 | 完整放送日历星期筛选 | 今天、周一至周日、全部 9 项及计数，默认今天；Calendar | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-034 | 完整放送日历搜索 | 日历中文名 / 原名 / 简介实时筛选；Calendar.Render | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-035 | 完整放送日历刷新/重试 | 日历刷新/重试按钮；Calendar.Load | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-036 | 完整放送日历打开原站 | 打开镜像/官方 calendar 地址；Calendar | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-037 | 完整放送日历信息 | 年/季度、全周总数、卡片评分/排名/日期/在看数及个人收藏快照；Calendar/BangumiCard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-038 | Bangumi 详情部分失败仍显示已有资料 | 先渲染本地/远端详情，章节失败独立显示；Subject.Refresh | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-039 | MoviePilot 订阅分类 | 全部 / 电影 / 剧集筛选及数量、追更中数量；MoviePilot | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-040 | 订阅卡片状态与进度 | 订阅卡片年/季/状态/评分/集数/进度；MoviePilotCard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-041 | 执行全站追更检索 | 独立全站追更检索调用 subscription.search；MoviePilot | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-042 | 订阅卡片“在 MoviePilot 刷新” | 订阅卡片在 MoviePilot 刷新入口调用 subscription.refresh；MoviePilot | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-043 | 快捷加入订阅 | 快捷加入订阅，保留来源数据；MoviePilotPolicies.NewSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-044 | 已订阅识别与重复操作禁用 | media_id及多来源ID、类型、季共同判断重复并禁用按钮；Subscribed | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-045 | MoviePilot 搜索结果辨识信息 | 搜索卡片年份、类型、评分、media_source、来源ID；MoviePilotCard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-046 | 从已选媒体进入资源页携带媒体身份 | ResourceRoute 携完整原始媒体 JSON，下载保持 media_in 原始对象；Resources | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-047 | 订阅编辑字段：年份 | 订阅年份可编辑并回传 year；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-048 | 订阅编辑字段：豆瓣 ID | 豆瓣ID可编辑/清空，处理 doubanid/douban_id 双键；SetText | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-049 | 订阅编辑字段：Bangumi ID | BangumiID可编辑/清空并正整数验证，处理双键；SetText | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-050 | 订阅编辑字段：起始集数（0–999） | 起始集数 NumberBox 0–999，序列化 start_episode；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-051 | 订阅编辑字段：总集数（0=自动识别） | 总集数 NumberBox，0表示自动识别，序列化 total_episode；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-052 | 订阅编辑字段：缺失集数 | 缺失集数 NumberBox，序列化 lack_episode；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-053 | 订阅编辑字段：包含关键词（逗号分隔） | 包含关键词（逗号分隔），序列化 include；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-054 | 订阅编辑字段：排除关键词（逗号分隔） | 排除关键词（逗号分隔），序列化 exclude；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-055 | 订阅编辑字段：分辨率/质量偏好：全部/默认、2160p、1080p、4K、WEB-DL、BluRay、Dolby Vision、HDR | 默认/2160p/1080p/4K/WEB-DL/BluRay/Dolby Vision/HDR 八项；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-056 | 订阅编辑字段：限定搜索站点：多选、使用全部站点、完成选择、加载失败重试 | 站点多选、全部站点、完成选择、失败重试；加载失败保留原限定 | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-057 | 订阅编辑字段：最佳版本洗版 | 最佳版本洗版 ToggleSwitch 写 best_version；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-058 | 订阅编辑字段：自定义存储路径 | 自定义存储路径可编辑/清空 save_path；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-059 | 订阅编辑字段：海报链接 | 海报URL可编辑/清空 poster/poster_path；EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-060 | 暂停/完成订阅状态编码 | 运行 R / 暂停 P / 完成 O 的读取与保存；MoviePilotPolicies.State/EditSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-061 | 从搜索结果新建订阅保留元数据 | 新订阅保留年份、来源编号、海报、简介，表单可修改；NewSubscription | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-062 | 资源精确筛选：站点 | 当前资源结果站点精确多选过滤；FilterFields[0] | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-063 | 资源精确筛选：季/季集 | 当前结果季/季集精确多选过滤；FilterFields[1] | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-064 | 资源精确筛选：促销（免费/普通/2x免费等） | 当前结果促销精确多选过滤；FilterFields[2] | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-065 | 资源精确筛选：编码 | 当前结果编码精确多选过滤；FilterFields[3] | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-066 | 资源精确筛选：质量/版本 | 当前结果质量/版本精确多选过滤；FilterFields[4] | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-067 | 资源精确筛选：分辨率 | 当前结果分辨率精确多选过滤；FilterFields[5] | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-068 | 资源精确筛选：制作组 | 当前结果制作组精确多选过滤；FilterFields[6] | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-069 | 筛选组操作 | 每个筛选组全选/清除/已选数量/逐项多选；Resources.ChooseFilter | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-070 | 已选筛选条件管理 | 条件 chips、单项移除、清除全部；Resources.Render | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-071 | 资源排序五项 | 默认站点优先级 / 站点 / 大小 / 做种 / 时间五种排序；MoviePilotPolicies.Sort | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-072 | 资源升序/降序与记忆 | 升降序切换、排序字段/方向跨启动持久化；Resources | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-073 | 资源搜索边到边显示 | Core SSE 全量进度投影 requestId 隔离、边搜显示、边搜可下载；TorrentSearch/ReceiveCoreEvent | SSE 首批早于完成/请求隔离/结束解绑自动验证通过；UI待smoke |
| I-074 | 资源结果详细标签 | 站点、促销、季集、编码/版本/分辨率/组、GB、做种、时间；Resources.Render | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-075 | 结果数量与筛选命中数量 | 总量/命中数量，区分未搜索、搜索中、未找到、全部被过滤；Resources.Render | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-076 | 资源大列表分窗/触底续载 | 初始60条、触底增加60条、加载更多按钮；Resources scroll.ViewChanged | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-077 | 无 TMDB 编号提示 | 缺 TMDB 时警示刮削缺字段并显示实际来源编号；Resources.SelectIdentity | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-078 | 下载列表每 5 秒自动刷新 | 下载页前台可见每5秒轮询，卸载停止；Page.Poll/Downloads | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-079 | 下载任务辨识资料 | 下载原始任务名、媒体名、站点、大小、总队列数；Downloads | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-080 | 下载任务状态对应操作 | 暂停任务仅开始，其余仅暂停；忙态替换控制组；近完成/暂停隐藏速度剩余；Downloads | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-081 | 删除下载说明 | 删除确认明确仅删除任务、不删除已下载文件；Downloads | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-082 | MoviePilot 会话失效时直接重新登录 | 各MoviePilot页面直接重新登录弹窗，成功可重试；Reconnect | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-083 | 观影头像服务器优先规则 | 服务器用户头像优先、刷新头像，Bangumi镜像头像回退；Dashboard.Avatar | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-084 | 观影页快捷菜单中的 Bangumi 个人主页 | 观影页个人主页快捷入口；Dashboard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-085 | 番剧放送按显式关联匹配 | 放送显式关联优先且其他已关联条目不再标题误配；BroadcastTimeline.Match | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-086 | 番剧放送按外部编号匹配 | MAL/AniList/TMDB剧/季及父剧编号匹配；BroadcastTimeline.Match | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-087 | 番剧放送标题归一化 | Windows繁简转换、FormKD全半角/音调折叠、大小写归一；Normalize | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-088 | 观影页下载摘要自动刷新 | 观影下载摘要前台可见15秒刷新；Dashboard/Page.Poll | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-089 | 观影页观看记录自动刷新 | 60秒观看记录刷新、前台恢复刷新、记录Changed监听与页面生命周期停止；Dashboard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-090 | 本月观看 TOP3 | 按作品/父剧汇总本月 TOP3 与时长排行条；ViewingAnalytics.Top | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-091 | 月观看柱图分类 | 每日电影/剧集/本地直连堆叠柱及图例/日期坐标/时长提示；BuildStatistics | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-092 | 完整类型分布及统计口径 | 全量已同步记录类型分布、总时长/首要百分比、前三+其余汇总及展开；ViewingAnalytics.Genres | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-093 | 近 7 天类型趋势卡 | 近7天前两种类型每日柱图与七日总时长；BuildTrends | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-094 | 与前 7 天类型时长对比 | 与前7天增减方向/小时、覆盖不足提示；BuildTrends | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-095 | 统计数据覆盖与缺片长说明 | 更新时刻、同步起点、月份部分覆盖、缺片长计数；BuildStatistics | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-096 | 实播记录采用服务器补充的类型 | 实播缺类型时按来源及媒体ID补服务器类型（跨日也补）；ViewingHistory.Merge | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-097 | 继续观看摘要信息 | 续播封面、剧名/本集名分行、进度、媒体库入口；MediaSummary | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-098 | 观影订阅摘要信息 | 订阅摘要复用完整海报/季/状态/下载与缺集卡片；Dashboard.Subscriptions | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-099 | 放送摘要海报及数据来源链接 | 放送摘要海报和 bangumi-data 可点击来源；Dashboard.CalendarLoad | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-100 | 最近/全部观看记录的封面与本集信息 | 最近/全部观看记录海报、剧名/本集信息、全部N条；HistoryRow/BuildStatistics | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-101 | 观影页未连接账号的连接卡 | 启用但未连接的Bangumi/MoviePilot连接卡，无服务器时媒体库连接卡；Dashboard | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-102 | Bangumi 独立“使用镜像源”开关 | 独立镜像开关，关闭保留配置；ConfigureMirror | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-103 | Bangumi 镜像根域与四路域名路由 | 根域规范化派生 api/lain/next/主站授权，带端口；BangumiDomains | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-104 | 镜像实际生效地址及输入错误提示 | 显示四路实际地址，根域校验错误直接反馈；IntegrationSettings | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-105 | 镜像“填入示例”按钮 | 填入示例 bangumi.lat；IntegrationSettings | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-106 | 镜像切换立即生效且保留登录态 | 切换镜像立即更新保存账号API、保留令牌、旧官方图片URL重写；ConfigureMirror/RewriteBangumiUrl | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-107 | 恢复官方直连按钮 | 恢复官方立即关镜像/清根域/恢复四官方域；IntegrationSettings | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-108 | MoviePilot 记住密码选项 | 记住密码开关，密码只进Vault，关闭立即清除；RememberMoviePilotPassword | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-109 | MoviePilot 令牌过期静默重新登录 | 401单次single-flight静默登录并重放，防账号切换/退出后的旧响应覆盖；MoviePilotRequest | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-110 | 未登录时也能设置集成启停 | 账号存在前独立保存集成启停，登录尊重偏好；IsEnabled/Enable | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-111 | 设置页退出 Bangumi/MoviePilot 确认 | Bangumi/MoviePilot退出二次确认及清除范围说明；Settings | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-112 | 退出 MoviePilot 后保留服务器配置 | MoviePilot退出清令牌/密码/会话，保留服务器地址；Logout | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-113 | 页面内搜索框 Enter 提交 | Bangumi/媒体/资源搜索TextBox Enter提交；Submit | 已实现；统一构建通过，具体动态验证范围见收尾报告 |
| I-114 | Bangumi 长列表渐进显示/加载更多 | 收藏与搜索首批立即显示、分页更多/触底续载、取消旧页面；CollectionBrowser | 已实现；统一构建通过，具体动态验证范围见收尾报告 |

验证入口：IntegrationParityVerification.VerifyIntegrationParity（镜像/状态/七筛选/排序/元数据/并发401/密码/季关联/完成同步/广播/统计/Core抛弃协议）；ViewingVerification 已将 fixture 改为真实 collection.status；ViewingPageVerification 额外断言6搜索类型/11评分项/3章节组/9日历项/5排序项，并截取所有路由。

接线：CoreRuntime 每100ms轮询并调用 ReceiveCoreEvent；DemoPages 调 MediaAssociation；播放器以 ViewingHistory.Source(server) 调 MarkLinkedEpisodeWatched。Core Bangumi update_episode_collection 接受 0..3，原生 DLL 已重建并通过本地协议集成测试。
