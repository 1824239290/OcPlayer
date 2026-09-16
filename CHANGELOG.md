# Changelog

项目变更记录。未发布内容集中在 `[Unreleased]`，提交前应同步更新用户可见行为和验证入口。

## [Unreleased]

### 修复

- **MoviePilot token 过期后不再甩原始 JSON、不再挂着无效的「重试」**：服务端对**过期 JWT** 回的是 403 + 自家信封 `{"success":false,"message":"token 校验不通过","data":null}`（只有缺 token / 解不出 payload 才是 401，jwt 过期签名落在 `verify_token` 的 `InvalidTokenError` → 403 分支），而客户端此前只把 401 当登录失效——403 落进 forbidden，信封里又取不到 FastAPI 的 `detail`，整包原始 JSON 直接当文案甩给 UI，且完全绕过「401 → 静默重登 → 失败才广播」的自愈链路：token 死了页面还显示已登录，「重试」永远失败。三层修复：错误体解析兼容 MP 信封（文案取 `message`，`detail` 兜底）；401/403 带 token 校验措辞一律归为 `requireLogin` 走静默重登——密码没改就无感自愈（订阅/搜索/下载全链路受益），密码改了或登录不上才清 token 广播通知把 UI 拉回未登录态；SSE 流式搜索的 401/403 同口径归一。订阅页与搜索页的错误态区分登录失效：标题「登录状态已失效」，按钮从「重试」换成「重新登录」直弹 MoviePilot 登录窗（预填地址与账号，只补密码）；「未登录」门控同样补了直弹登录窗入口。MoviePilotKit 新增 4 用例（403 信封自愈重放 / 普通 403 不误伤 / 信封文案提取 / 分类契约）。
- **缓冲不再强弹 HUD（issue #2「三十秒闪一次」的可见症状）**：HUD 的显隐判据此前只有一个 `canAutoHideControls`（`(playing||paused) && !isBuffering && 无遮挡`），且「变化即唤出」——于是每轮缓冲起止都强制唤出一次 HUD，跟着弹出来的是全屏压暗遮罩（`PlayerHUDReadabilityScrim`，32% 黑）＋转圈＋弹幕冻结，网络抖动下就是用户看到的「画面暗一下亮一下」。判据拆成 `PlayerHUDGates` 的两个值：`revealTrigger`（该不该唤出：暂停 / 错误 / 字幕导入 / 弹幕选择 / 辅助功能 / 播放起止）与 `canAutoHide`（能不能自动收起，缓冲期间为 false）；`PlayerHUDVisibilityCoordinator` 新增 `refreshAutoHide(canAutoHide:)`——缓冲只续期、不计显隐：HUD 在屏上就留住，已收起则不会被弹出来。**顺带修掉因此暴露的转圈对比度问题**：中央缓冲指示以前靠 HUD 的全屏暗幕托底，HUD 不再强弹后白转圈直接压在亮画面上几乎看不见，改成套 `PlayerHUDPanel` 暗底（与错误徽章 / 2 倍速徽章同族）并常挂载 + `.opacity` 淡入淡出（HUD 收起期间没有容器动画托底，`if` 挂载会是硬闪）。App 层新增 6 用例（含「缓冲只改收起资格」「不弹已收起的 HUD」两条回归）。
- **UI 缓冲态加迟滞，单帧饿数据不再闪动控件**：`PlayerState` 新增 `isBufferingSustained`——进缓冲要**连续持续 300ms** 才置位，恢复时补足 500ms 最短可见时长再收回（期间再进缓冲不重计、不收回）。转圈、HUD 状态行「缓冲中」、弹幕冻结/续播、HUD 收起计时全部改用它；诊断真值 `isBuffering`（`buffer.start/end` 事件、卡死看门狗）不受影响——埋点里不留迟滞。PlaybackKit 新增 4 用例（单帧饿数据完全不惊动 UI / 上沿与最短可见 / 收回前再进不闪 / reset 取消在飞计时）。
- **日志跨进程共写把记录撕碎（116 行残缺）**：`diagnostics.jsonl` 用 `FileHandle(forWritingTo:)` + `seekToEnd()` 打开、各进程各记文件偏移，"App 进程 + 测试宿主进程"共写同一文件时，后写者的 write 落在旧偏移上覆盖对方——实测三份文件共 116 行残缺（两条记录互相插入、或一条被拦腰截断，样本里能看到测试假内核名混进真实日志）。改为打开后置 `O_APPEND`（每次 write 由内核原子追加到真实末尾），补回归用例 `testAppendLandsAtRealEndWhenAnotherWriterIntervenes`，A/B 验证有牙齿：禁用 `O_APPEND` 时该用例必挂（对方写入被覆盖，3 行变 2 行）。历史残缺行仍在旧归档里，未清理。
- **维护会把「正在写的」日志文件删掉**：保留策略要跳过当前会话文件，但 `contentsOfDirectory` 返回的 URL 会把 `/var` 解析成 `/private/var`，直接比 URL 恒不相等 → 当前文件被判成淘汰候选。改成解析符号链接后比路径。由新写的「按数量淘汰最旧、当前文件永不删」用例抓出（实测确认 URL 字符串差异）。
- **测试宿主污染真实日志目录**：`xcodebuild test` 注入的 App 进程跑真实代码，一次全量 AppTests 会在 `~/Library/Logs/OcPlayer/` 留下 6 个会话文件（也是上面那 116 行残缺的另一半来源）。测试宿主现在改写临时目录（`XCTestConfigurationFilePath` 判定），跑完真实目录文件数不变。
- **弹幕时基混用致偏移非零时弹幕整集不出现（清屏死循环）**：弹幕 overlay 的 seek 跳变检测在 `tick` 里比较**原始媒体时间**，而 `resync`（装载 / seek / 改偏移后对齐）写入的却是**减过偏移的生效时间**——两个时基混用。只要偏移非零（dandanplay 匹配返回的 shift、或 HUD「时间偏移」调出 ±0.5s 以上），对齐后的下一拍算出 `delta ≈ 偏移量 + 1/60s`，越过 seek 阈值被误判成 seek → 再对齐 → **永久循环**：每拍 `view.stop()/play()` 清屏、发射逻辑永不执行，表现为「弹幕一条都不出来」。检测逻辑抽成纯值类型 `DanmakuSeekDetector`（只持原始媒体时间一个时基，类型本身杜绝再次混用），`resync` 的对齐基改回原始时间（积压兜底基维持生效时间同源不改）。修复后「调偏移修对齐」不再把弹幕全部弄没。App 层新增 7 用例：核心回归是「偏移 3s 下对齐后下一拍必须连续」，另覆盖前后向跳变仍被检出、`jumped` 后基准推进、`reset` 回无基准态。
- **Bangumi 集成开关读取吃掉默认值，全新安装的播放结束自动标记静默关闭**：后台门控用 `UserDefaults.bool(forKey:)` 读「启用 Bangumi」——这个开关默认 `true` 但**默认值从不落盘**（Toggle/`@AppStorage` 只写用户拨过的值），键不存在时 `bool(forKey:)` 返回 `false`，于是对所有从未拨过开关的人（含全新安装）实际是「停用」：播放结束不再自动标记看过，只在诊断日志里留一行「集成已停用」。新增 `UserDefaults.bool(forKey:default:)`（键不存在回 fallback，注释写明这个坑并落在 `SettingsKeys` 便于发现），门控改用它；`PlaybackPreferences.storedBool` 的私有同款实现收敛为委托该方法（行为逐字不变）。App 层新增 3 用例。
- **章节 / MediaSegments 链路静默失效（时序竞态）**：`loadChapters` 与引擎 `open` 并发执行（章节请求 28ms 即回，引擎 open 约半秒），但其时效守卫要求 `activeRequest` 已是当前请求——而 `activeRequest` 恰恰要到 open 完成才赋值，守卫因此**每次必败**，三个 await 检查点静默 return：MediaSegments 请求不发、章节与服务端跳过标记全部丢弃、日志零痕迹（媒体库装了 Intro Skipper 插件也不会生效）。守卫改为只认装配层的 `expectedRequestID`（跨请求换片时同步更新，是这路数据真正的失效判据），与引擎 open / 引擎重建解耦；作废路径补日志，不再无声。修复后 Jellyfin / Emby 的章节列表、章节名启发式与 MediaSegments 片头片尾识别首次真正可用。

### 改动

- **设置页「网络预读缓冲」文案改成按带宽取舍**：原文案「公网服务器建议 16 MiB 以上」方向是反的——内核把整个窗口作为**一次** HTTP 请求拉取，单次请求有 15 秒响应上限，等于每 1 MiB 约需 0.55 Mbps 持续带宽（8 MiB≈4 Mbps、16 MiB≈9 Mbps、32 MiB≈18 Mbps）。带宽吃紧的远程服务器调大反而会周期性失败（现场表现：播到一半停 / 每半分钟一次缓冲）。`PlaybackPreferences` 的档位注释、设置页说明与 README 同步改成「数值越大要求越高，带宽吃紧反而要调小」并给出各档门槛；内核改成按块拉取（单请求封顶）后这几档门槛会一起降到 ~2 Mbps，届时同步回落文案。
- **内存 tick 记录补 `output_mode_switches`**：输出模式切换计数此前只参与「这次 tick 要不要记」的判定，日志里看不到值。现在进字段（每次记到的 tick 都带），配合内核 `ERIKA_HDR_DEBUG` 的 `ErikaHDR: … output mode=…` 行，现场就能分辨「显示器侧真的切了 HDR / 刷新率」还是 UI 自己闪（issue #2）。ErikaKit 新增 1 用例。

- **日志系统重整：默认档精简 + 一键诊断包 + 播放事件行 + 内核 stderr 接入**（issue #1/#2 排障暴露的缺口，完整清单见提交历史与 `Docs/LOGGING.md`）。四件事：
  1. **级别口径重定 + 默认 `info` 档**：全仓 119 处 debug 调用点逐条定级（升 info 约 63、升 warning 27、留 debug 18、合并删除 25，另删 6 个无调用方的网络日志死包装）——「一次操作的结果」「状态迁移」必须在默认档可见，守卫与中间态留 debug。管线加了进程级最低级别（默认 info）与实例覆盖，过滤放在**消息求值、脱敏、节流之前**（`@autoclosure` 消息因此不求值；被压掉的记录不污染节流计数）。
  2. **设置页「详细日志」开关 + 「导出诊断包…」**：开关打开 = debug 档并联动内核 `ERIKA_HTTP_TRACE`/`ERIKA_PLAYBACK_TRACE`/`ERIKA_HDR_DEBUG`（内核在引擎创建时读环境变量，**下一次播放生效**）；刻意不含高频开关（`ERIKA_FFMPEG_DEBUG` 实测 1500+ 行/秒、`ERIKA_SUBTITLE_DIAG` 约 100 行/秒，会把诊断文件冲掉，需要时手动加）。导出产出**单个 `.txt`**（头部：版本/构建/commit/平台/系统/当前档位/脱敏说明 → 全部 JSONL 记录 → 内核 trace 文件），走 `.fileExporter` 双端同一实现（不用 zip：iOS 起不了 `ditto`）。验证：设置开关 → 播放 → 导出，文件可直接附件。
  3. **播放生命周期事件行**：`open.start`（源类型/预读窗口/是否续播）、`open.done`（`ok` + `elapsed_ms`）、`first_frame`、`buffer.start`/`buffer.end`（带位置与这轮缓冲时长）、`stall`（宿主看门狗：在播、内核**没**报缓冲、位置连续 5s 不动 → warning，恢复后补 `recovered=true`）、`seek`（`kind` 区分 scrub/skip/chapter/auto/resume）、`error`（带内核原文）、`session.end`（`played_ms`/`buffer_count`/`buffered_ms`/`error_count`/`stall_count` 汇总）。每条记录带**会话标识**（进程级 8 位 id，一次启动一个）与**毫秒时间戳**，按 `session` 过滤即得一次启动的完整时间线（此前秒级精度判不出「续播 seek 与弹幕注入谁先」）。
  4. **内核 stderr 接进诊断管线**：GUI 启动时进程 fd 2 归 launchd，内核 stderr（`ErikaHDR`、结构化事件、Rust panic、ffmpeg 告警）此前完全丢失。现在 fd 2 → 管道，按前缀分类写进同一份 JSONL（`Erika/Output`、`Erika/Open`、`Erika/Stderr`；错误特征行提到 warning/error 让默认档可见），**原 stderr 保留一份 fd 做 tee**（终端/Console 行为不变、崩溃栈照样可见）；内核逐帧 trace 的 stderr 回声不入管线（内容在 trace 文件里），200 行/秒限速兜底。实测（自检模式 + DV/HDR 片源）：同一场景从 3469 条降到 100 条，留下的全是高价值事件（`video_seek_preroll elapsedMs/firstOutputPts`、`ffmpeg_seek`、`video_decoder_changed backend=videotoolbox`）。

- **日志文件改为按会话组织**：一次启动一个 `diagnostics-<时间戳>-<会话id>.jsonl`（写满续编 `-2`），保留最新 10 个 / 总量 ≤50MB / 不超过 30 天，当前会话文件永不删；替掉「单文件 2MB 滚动 + 3 份归档」（长会话的关键行会被切碎、上限一到还会直接删掉正在写的文件）。单条超长记录改成**截断保留**（头 1KB + 标注被截字节数），不再整条换成一条 warning（旧行为等于把内容丢了）。终止路径改有界 `flush(timeout:)`（macOS 2s / iOS 1s）——iOS 此前**完全不 flush 日志**，最后一批排队写入随进程丢。验证：连开三次产生三个会话文件；旧版 `diagnostics.jsonl.1/.2` 被同一策略自然淘汰。

- **降噪两处**：`displayEDRHeadroom` 同值不再下发（屏参通知风暴实测一次播放刷 3155 条同值记录）；内核内存 tick 采样改成「有实质变化才记」（关键分项变化 ≥8MiB 或 ≥10%，或 drawable 数／输出模式切换计数变了），open/stop 基线照常记——播放中每 5s 一条会让 1 小时片子多约 700 行噪声。

- **文档**：新增 [`Docs/LOGGING.md`](Docs/LOGGING.md)（级别规范、模块矩阵、事件字段口径、内核开关、不记什么）与 [`Docs/TROUBLESHOOTING.md`](Docs/TROUBLESHOOTING.md)（症状 → 看哪几行 → 常用命令），README 补链接与「遇到问题先导诊断包」的使用建议。

- **「跳过片头」接入 AniSkip 社区标注（第四路数据源）**：在弹幕报点推导之上再接 [AniSkip](https://api.aniskip.com/api-docs)（社区提交 + 投票背书的 OP/ED 区间库，浏览器扩展/IINA 跳 OP 脚本同源），优先级变为 **MediaSegments > AniSkip > 弹幕 > 章节启发式**。解析链：Jellyfin ProviderIds 直取 MAL ID（`MediaItem` 新增 `malID`/`anilistID` 透出，`Mal`/`MyAnimeList` 键都兼容）→ 缺失时 AniList GraphQL 换算/标题搜索（本地 24 部真实番实测映射成功率 20/24）→ `AniSkipClient` 按集查询 OP/mixed-op 区间。MAL ID 解析结果永久缓存（`aniskip-ids.json`），标题搜不中记负缓存 7 天过期重试，不重复打 AniList；AniSkip 无数据（404）/网络失败静默降级到弹幕推导，查询放在弹幕注入之后不拖慢弹幕上屏。AniSkip 区间转提示时起点直接用 OP 区间起点——有冷开场/前情回顾的集（如 OP 在 638–728s 的命运石之门）按钮只在 OP 区间内出现，比弹幕的最早报点估计更准；区间长度/绝对值双向合理性钳制防错季脏数据。已知局限记账：AniSkip 只认 MAL ID 且集数按条目内计，长篇连载/标题搜索不分季可能错季（有 episodeLength 过滤 + 钳制兜底）；覆盖与弹幕互补（我的朋友很少/来玩游戏吧/蜂蜜柠檬碳酸水等弹幕零信号的番 AniSkip 有数据，2026 新番两边都还没有）。`DanmakuIntroHint` 增加 `source` 字段（存量缓存解码兼容，缺省弹幕来源），`ChapterSession` 合并按 `SkipMarkSource.rank` 取舍、同级别刷新原位覆盖。DanmakuKit 新增 AniSkip 客户端 5 用例 + ID 解析器 3 用例 + 编排层优先级 2 用例，App 层 1 用例。

- **弹幕驱动的「跳过片头」**：播放器已有的片头/片尾跳过系统（Jellyfin MediaSegments 优先、章节名启发式兜底）接入第三路数据源——**弹幕报点推导**。弹幕文化里观众跳 OP 时会发「跳伞/空降 02:12」报出落点，落地后再发「空降成功/感谢指挥部」确认；两批独立行为在真实缓存弹幕上收敛到同一秒（54 集标定：报点主簇中位数与着陆确认逐秒吻合，同集冷开场长短差异也能如实区分）。新增 `DanmakuKit.DanmakuIntroDetector`：报点目标按 25s 间距聚类取最大簇（片头结束点 = 簇中位数），着陆/正片标记做交叉确认（无确认时要求 ≥3 个不同目标值），片尾玩笑报点（22:17）、中段跳过（11:50）被目标区间 + 聚类自然剔除，片头起点由最早报点帖估计（有冷开场的集不从 0 跳）。提示按 episodeID **永久缓存**（`intro-hints.json`，独立于弹幕正文的 1h TTL），之后弹幕过期或网关不可达跳过按钮照样可用。`DanmakuLoadOutcome.loaded/.empty` 带出提示，`DanmakuCoordinator` → `PlaybackController` 注入 `ChapterSession`（requestID 守卫防旧代迟到回调；章节与弹幕两条异步链路谁后到谁负责合并）；`SkipMark` 增加 `source` 字段标注来源，合并按可信度取舍：MediaSegments > 弹幕 > 章节启发式。顺带修掉 `performSkip` 跳过目标不钳制片长的隐患（越过 EOF 会触发内核错误风暴，与 `skip(by:)` 同一道防线）。UI 零新增：现有悬浮「跳过片头」按钮、窗口判定与会话内去重全部复用。DanmakuKit 新增检测器用例 9 个（真实形态回归含全角冒号/`2.21`/`3:9` 变体解析与「跳伞1.5倍」防误伤）+ 提示链路用例 4 个，App 层注入用例 6 个。

- **液态玻璃文字/图标动态颜色修复**：跳过片头/片尾按钮此前沿用 HUD 的固定白调色板（`PlayerHUDPalette`），但它挂在 HUD 之外、不享受全屏压暗暗幕的保护——HUD 自动隐藏后玻璃直接采样原视频，亮场面下玻璃翻浅变体、白字图标随之看不见；改用动态色 `.primary`（玻璃上的动态色随玻璃明暗变体自动翻转，WWDC25 session 284 确认），`PlayerHUDPalette` 补注释钉死「固定白仅限 HUD 暗幕之内」的使用契约。iOS 横滑 seek 预览条（白字白条裸压视频、拖动期间 HUD 不唤醒）包进实底 `PlayerHUDPanel` 背板，与音量/亮度 OSD 同族，任何画面下对比度都有保证。弹幕选择弹窗与 MoviePilot 资源页 4 处写死白的描边/行高亮改 `Color.primary` 同值——深色模式渲染零变化，浅色模式（浅玻璃下白描边隐形）修复。

- **设置页信息架构重排为六组**：原 10 个 Section 平铺一条龙（服务器/播放/播放内核/界面/弹幕/MoviePilot/关于/存储/诊断/无名登出）重排为 **通用 → 播放（含播放内核）→ 弹幕 → Jellyfin 服务器 → Bangumi → MoviePilot → 关于 → 维护**，并按「说明文字一行为辄」瘦身：「播放内核」删掉构成行、永久禁用的弹幕渲染开关与内核 notes（工程信息归开源许可证页），只留内核信息行与「下次播放生效」提示；「关于」删掉直连策略 / 弹幕来源两条静态文案；弹幕网关的 API Key / 状态行收进配置弹窗语境，区块缩为一行 + 条件提示；MoviePilot 介绍长文删除；存储 + 诊断合并为「维护」。**服务器管理抽成「管理服务器」子页**（新增 `ServersView`）：当前服务器首次进入列表（带「使用中」标），切换 / 删除 / 默认星标都在子页完成，不再需要先「连接其它服务器」才能看到自己的档案；页尾无名 Section 的 Jellyfin「退出登录」并入服务器区块并改名「退出 Jellyfin」，与 MoviePilot 的「退出 MoviePilot」消除同名歧义。

- **播放入口迁出设置页（首页工具栏「打开」菜单 + macOS 文件菜单）**：首页工具栏新增「打开」菜单（本地视频文件 / 直连链接，macOS / iOS 共用）；macOS 补上惯例的文件菜单——`CommandGroup(replacing: .newItem)` 提供「打开本地视频文件…」⌘O、「打开直连链接…」⇧⌘O。`fileImporter` 与 `URLEntrySheet` 上移到 `RootView`（`isPresented` 绑 `AppModel` 的请求标志，工具栏菜单 / 文件菜单只置标志，任何分区下都能触发，⌘O 在设置页按下也有效），`URLEntrySheet` 随迁 RootView；设置页「播放」区块只剩网络预读缓冲。

- **播放内核选择失效自愈**：装配点（`PlaybackEngineAssembly.registerAll`）注册完成后若发现存的选择指向本构建不存在的内核（MPV 实验分支残留的 `mpv-that-does-not-exist`），就地清除回退第一个可用内核并记 PlaybackLog——失效偏好在启动时自愈，不再常驻；设置页「播放内核」的橙色回退告警随之删除，本机 defaults 残留已清。

- **Bangumi / MoviePilot 集成启用开关（设置页）**：不用这两个集成的人可以整体停用——关闭后侧栏 / iPhone Tab 的对应入口消失（停用瞬间正停在该分区则选中回落首页）、详情页的 Bangumi 章节区块与 MoviePilot 资源区块 / Bangumi 条目页「MoviePilot下载」按钮隐藏、播放结束的 Bangumi 自动标记与 MoviePilot profile 校验等后台活动一并停止。默认开（现有行为不变）；关闭只藏 UI 停网络，登录凭据、服务器配置、条目关联与本地缓存全部保留，重新打开即恢复。开关 key 收进 `SettingsKeys`（`bangumi.enabled` / `moviepilot.enabled`），各触点经 `@AppStorage` 读同一登记 key。

- **macOS 菜单栏与系统界面中文化**：App 声明支持简体中文（新增 `App/Shared/zh-Hans.lproj/Localizable.strings` 声明载体 + Info.plist `CFBundleLocalizations` 登记），系统语言为中文时 AppKit/SwiftUI 提供的标准菜单（文件/编辑/显示/窗口/帮助）、菜单项（关闭/全部关闭等）与系统面板按钮（打开/取消）跟随中文渲染——此前整个菜单栏落在开发区域语言（英文）上；App 自有文案本就是中文硬编码不受影响。无障碍树里合并子标签的连接符也随语言变为顿号（如卡片「标题、年份」），VoiceOver 朗读更自然。

- **设置页内核行带版本号**：「内核」行显示为「Erika v0.1.9+dolby.1」。`PlaybackEngineDescriptor` 增加可选 `version` 字段（多内核时选择器同样带版本）；版本来源为新增的 `Packages/ErikaKit/Sources/ErikaKit/ErikaVersion.swift`——由 `Scripts/fetch-erika.sh` 在每次拉取内核时重写，与 vendored 二进制保持同源（该文件入库、diff 可见，拉了新内核不提交它会立刻暴露漂移）。

## [0.1.6] · 2026-09-11 · 前端组件化重构、HUD 液态玻璃与内核 v0.1.9

### 改动

- **修复 Bangumi 搜索「请求参数有误」**：带类型过滤的搜索（关联条目选择器、自动匹配的动画优先搜索、主页分类筛选）此前把 `filter.type` 编码成 `{"type":{"0":2}}` 对象——`BangumiJSONValue` 缺数组 case，只能用字典伪造，Bangumi 服务端校验拒绝直接 400（`body/filter/type must be array`），UI 报「请求参数有误，请检查后重试」。现在 `BangumiJSONValue` 补 `.array` case，搜索请求体改为 `{"type":[2]}` 正确数组形态；自动匹配原先靠吞 400 回退全类型搜索才没挂，修复后不再依赖兜底。新增 2 个请求体形状单测钉住编码。

- **弹幕网关瞬断自动重试**：匹配偶发「弹幕服务暂时不可用」的根因是网关（Cloudflare Workers）冷启动/子请求超时导致的瞬时 502/503/504——该文案是 `httpStatus` 兜底，此前 `GatewayClient` 一次请求即弃、四层降级只是换参数重试。现在接入阶段 3 的共享 `RetryPolicy`（3 次尝试、指数退避带抖动、429 尊重 Retry-After 封顶 60s，判据与 Bangumi 同口径）：网络超时/断网、502/503/504、429 自动重试；任一降级层命中网关级错误即短路剩余层，不再连打必败请求（也避免自触网关限流）；403 拆出独立语义「网关拒绝了请求（API Key 无效或已被限制）」，不再误报「暂时不可用」。匹配/搜索/弹幕正文接口全部幂等只读，重试天然安全；手动搜索与手动选集同享。新增重试用例 8 个（客户端 7 + 编排层短路 1），既有网关失败用例加请求计数断言。

- **macOS 26 全屏顶栏衔接层**：全屏时系统把工具栏搬进独立的 `NSToolbarFullScreenWindow`，顶部画一条与窗口底色同源的不透明硬底条带，氛围图被拦腰截断。新增 `FullscreenTitlebarFade` 衔接层（顶部 52pt 保持窗口底色、再 84pt 渐隐进氛围图），挂在整窗氛围层（`AppShell.windowAmbienceLayer`）与首页轮播两处；**衔接层必须放在氛围层的动画作用域之外**——放进去会被切页/换片时的 `Motion.ambient` 交叉淡入卷着一起动，背景里滑出一条渐变带（全屏专属症状）。工具栏本身不藏：实测 `.windowToolbarFullScreenVisibility(.onHover)` 会在全屏进详情页后留下旧页面残影并吃掉那片点击，AppKit 改 `toolbar.isVisible` 会把窗口踢出全屏——两条藏工具栏路线均已否决并留档。

- **播放器收边（阶段 4）**：弹幕偏好到引擎的映射合并为单一 `DanmakuPrefsSnapshot` 通路（原来 open 队列闭包的静态版与实例版各写一份字段对应表）；Erika 弹幕 JSON 的解析从 App 层（DanmakuOverlay）下移到 DanmakuKit（新增 `DanmakuJSONParser`，与写入侧 `DanmakuJSONConverter` 同包同 schema），App 不再认识内核数据格式；新增解析器测试 5 用例（含 converter↔parser 往返一致）。手势分类纯逻辑此前已抽 `PlayerPanGestureModel`（有测试），PlayerScreen 剩余的触摸编排评估后保留在视图（与控制器/HUD/亮度耦合，换壳无收益）。

- **网络层收敛（阶段 3）**：共享 HTTP 执行层落到 DiagnosticsKit——`HTTPClient`（请求构造/发送/计时日志/传输错误映射，状态码 ≥400 记失败级）+ `RetryPolicy`（指数退避 + 抖动 + 429 Retry-After，封顶 60s，支持 `sending` 闭包与调用方隔离域继承）。BangumiKit（`BangumiAPIClient.request`）、MoviePilotKit（`sendOnce`）、DanmakuKit（`GatewayClient.send`）三个客户端的手写「组请求/发送/URLError 分类/状态分支」全部替换为共享执行器；各域只保留自己的鉴权与状态语义。新增 `HTTPClientTests`（6 用例钉住退避/重试/取消语义）。新增 `SettingsKeys` 登记表，收编跨文件重复的 UserDefaults key（`ambientBackdrop`、`httpReadAheadMiB` 等曾各写三份）。纯重构，无行为变化。

- **状态层重构（阶段 2）**：
  - `AppModel` 域模型全部改为 init 显式注入（`store/bangumi/moviepilot/danmakuModel`，默认值不变），`bangumi.setup()` 从 init 挪进 `bootstrap()`——构造 AppModel 不再有副作用，测试拿到干净实例。
  - `BangumiCoordinator` 支持注入 `BangumiContext`（默认 `.shared`）。
  - **MoviePilot 凭证存储收敛为单实例**：`MoviePilotStore.shared`——此前协调器与 `MoviePilotAPIClient` 各持一个实例、只靠同一份 UserDefaults 碰巧同步。
  - 401 凭证失效接线收敛：RootView 里 Bangumi/MoviePilot 两段几乎相同的 `onReceive` 合并为共享的 `onAuthenticationRequired` 修饰符 + `AuthNotification` 解码。
  - **`DetailView` 数据面抽成 `DetailViewModel`**（1342→1083 行，@State 21→6）：详情/季/集/类似的加载、SWR 快照缓存、按季缓存、选中态与智能默认季/集全部进 VM，视图只剩布局与交互编排。详情页行内错误条并入共享 `ErrorNotice`，集列表空态/失败态并入 `EmptyState`。
  - 决策记录：`AppModel+Playback` 的播放编排**不**再抽独立对象——它要协调导航层/上报/弹幕/Bangumi/首页缓存五方，抽出来只是把同一份耦合换个壳；`@Observable` 本身已按属性粒度隔离重绘。播放侧的真正整改在阶段 4（PlaybackController 职责拆分）。

- **前端组件化重构：设计系统下沉为新包 `AppDesignKit`，卡片/胶囊/分页/空态向共享原语收敛**（`refactor/component-reuse`）。
  - 动效/尺寸 token、骨架屏、卡片原语、横向滚动、液态玻璃、远程图管道（`ImagePipeline`/`RemoteImage`）从 `App` 移入新包 `Packages/AppDesignKit`——只吃纯值、不依赖任何域模型，新 Feature 直接复用。
  - 新增模型无关原语：`MediaArtwork`（海报/剧照画幅 + overlay 槽）、`CardProgressTrack`（3pt 胶囊进度细轨）、`PillChip`（分类/印章徽章，三档语义色）、`RatingPill`（评分徽章统一橙）、`EmptyState`、`ErrorNotice`、`PagedListLoader` + `LoadMoreFooter`（分页状态机：代次守卫/追加去重/满页判断，含 `replace`/`remove`/`reportError`）。
  - 收起重复卡片：Bangumi 的 `CollectionTile`/`ProgressCard`/`CollectionRow`/`SearchResultRow`/`CalendarItemCard` 与 MoviePilot 的 `MoviePilotSubscribeCard`/`MoviePilotMediaGlassCard`/`MoviePilotTorrentGlassCard`，以及 `PosterCard`/`StillCard`，全部落到 `MediaArtwork`/`CardProgressTrack`/`PillChip`/`RatingPill`。
  - 收起手写分页：Bangumi 首页在播/搜索两套分页 + 收藏列表页改用 `PagedListLoader`。媒体库 `LibraryView` 因分页数据住在 `AppModel.libraryPages` 缓存而有意保留自管状态机，避免再造一个数据源。
  - 收起错误/空态/胶囊：`BangumiNotice` 并入 `ErrorNotice`；LibraryView/AppShell/Home/Bangumi 收藏列表空态并入 `EmptyState`；展示型标签用 `PillChip`，交互型菜单/状态胶囊按钮保持原生。
  - 净效果：App 层约 -1000 行；`BangumiHomeView` 999→836、`BangumiCollectionListView` 160→151。新增 `AppDesignKitTests`（12 用例）。纯 UI 重构，无视觉/行为变化，播放器 HUD 零改动。

- **HDR 片首次真出 EDR**：内核在 macOS 不探测屏幕，HDR 输出档位全靠宿主喂 headroom，而 App 从 v0.1.0 起一直传 `Auto + 0`——HDR 片始终被映射成 SDR（播放详情的「映射 SDR」标注只是让它显形）。现在引擎创建时按窗口所在屏的 `maximumPotentialEDR` 传 `edr_headroom`（SDR 屏 = 1.0 行为不变，XDR 屏 ≈8 真出 EDR），`PlaybackEngine` 增 `updateDisplayEDRHeadroom`（默认实现防静态派发坑），PlayerScreen 监听换屏/显示配置变化并首报、引擎重建时补推。非 macOS 不查不推。**限制**：运行时切换要等内核 Metal 后端实现 `set_output_headroom`（当前只在创建时生效，播放中换屏档位不跟手）。

- **关于页与产物可追溯到提交**：构建号与 Git commit 全程注入——`App.xcconfig` 增 `CURRENT_PROJECT_VERSION` 默认值，`Info.plist` 增 `GitCommit` 键（构建时注入，字面量兜底为 nil）；AppVersion 新增 `gitCommit`，关于页显示 `v版本 (Build N · 短哈希)`、启动诊断日志带 commit；构建脚本 Build 号 CI 取 run number、本地取提交总数，dirty 构建带 `-dirty` 后缀，本地产物文件名带 build + commit 后缀，打包脚本语义版本校验前置。补 `AppVersion.displayString` 单测。

- **弹幕匹配成功率提升（模糊候选打分 + 四级降级检索）**：`isMatched == false` 的模糊候选接入 `DanmakuCandidateScorer`（集数 / 季度 / 标题打分）救回有效弹幕；检索引入四级瀑布流降级——Hash 匹配 → TMDB ID 搜索 → 标题+集数精准搜索 → 提纯标题全集匹配（此前每级静默吞错，见「修复」里网关故障误报那条）。新增 `DanmakuFilenameParser`：全角半角转换、中文数字解析、剥离发布组与压制参数噪声；Jellyfin 与单播文件的元数据推断同步优化（解决 `01.mkv` 丢番剧名、单播支持向上回溯父目录）。

- **MoviePilot 与弹幕选择界面重构为液态玻璃 + 多层子菜单**：DesignSystem 增通用 `liquidGlassCard` / `liquidGlassCapsule` 材质修饰器；MoviePilot 媒体搜索结果改通透流式卡片（去掉放大悬浮动效），资源搜索页引入氛围背景、移除 300+ 行实时 glass 着色器与 textSelection、背景启用 Metal 离屏栅格化（此前严重掉帧）；弹幕选择面板重构为「作品 → 选集」两级下钻（平滑层级返回 + 透明液态玻璃背景），播放器为该弹窗配透明背景。

- **播放中 HUD 自动隐藏时一并藏鼠标光标**：用 `NSCursor.setHiddenUntilMouseMoves` 与 HUD 同步显隐，退出播放器强制 unhide 兜底；暂停 / 缓冲 / VoiceOver 时光标保持可见。
- **播放内核升级到 fork 的 `v0.1.9+dolby.1`（macOS）**：基于上游 v0.1.9 + libplacebo 风格 Dolby Vision RPU 映射（P5/P8.1 SSIM≈0.995）。相对 `v0.1.7+dolby.3` 带来上游 0.1.8/0.1.9 一系列播放修复——渲染阻塞恢复后的音画时钟重校准、倍速切换平滑过渡、iOS 前台/音频中断恢复、首条音轨解码失败自动回退后续音轨、弹幕跨规划窗口重现跳轨、`ErikaOpenOptions` 预读（本 App 已在用）。C ABI 与 `v0.1.7+dolby.2+` 一致（`ErikaPresenterConfig` 四字段），App 侧无需改代码。**iOS 暂维持 `v0.1.7+dolby.3`**：该 release 仅手工打包了 macOS arm64 资产，`package-ios.sh` / CI iOS job 继续钉最近一次全平台 tag；`fetch-erika.sh` 支持 macOS-only release（无 iOS zip 时复用本地已有切片并在 Info.plist 登记）。下载哈希 pin、脚本与 CI 钉点同步换版。

- **设置页新增「启动时默认服务器」**：多服务器用户可在设置 → 服务器里选定打开 App 时优先连接的档案，不必再被「上次使用的服务器」绑死。选「上次使用的服务器」保持旧行为；选定具体档案后启动静默恢复优先走它，token 失效仍回退到其它有有效会话的档案。默认服务器在已保存列表带星标；删除该档案会自动清掉默认设置，不留悬空 ID。默认与「当前会话」独立：临时切到另一台看片，下次打开仍回到你指定的默认服务器。

- **媒体库每个库页面右上角新增排序与观看状态筛选**：电影 / 剧集等库的网格页工具栏加「排序与筛选」按钮，点开系统下拉菜单（macOS 26 / iOS 26 原生液态玻璃，与首页 / MoviePilot 菜单同款）三组单选——排序字段（名称 / 最近添加 / 年份 / 评分 / 时长 / 随机，带图标与对勾）、顺序（升序 / 降序）、观看状态（全部 / 没看过 / 看过，服务端 isPlayed / isUnplayed 过滤）。排序完全在服务端生效（items API `sortBy`/`sortOrder`，主键外固定挂名称升序副键），分页大库全量有序；候选集按库类型收敛——剧集库去掉时长（Runtime 是单集时长）、混合内容 / 家庭视频等只留名称 / 最近添加 / 随机，随机无方向不显示顺序组。换字段时方向自动重置到自然默认（评分默认高→低等），排序与观看状态按库独立记忆，变更即作废该库分页缓存从第一页重取。顺带把 MoviePilot 筛选条与 Bangumi 详情页两份逐字节相同的私有 FlowLayout 抽到 DesignSystem 共用（新增 `FlowLayout` / `OptionChip` 共享组件）。

- **资源搜索筛选排序对齐 MoviePilot 网页端**：原先「站点选择 + 一颗筛选按钮弹整表单 + 排序菜单」换成官方同款筛选条——排序（字段 + 升降序）与七组筛选（站点 / 季 / 促销 / 编码 / 质量 / 分辨率 / 制作组）平铺一行，每组点开是候选值 chips 下拉（头部「全选 / 清除」，可多选，点击即时生效；iPhone 紧凑宽度自动升级为半屏 sheet）；激活的分组按钮 tint 玻璃高亮并记数，下方以「站点:观众 ×」样式的已选 chip 汇总、可逐个移除或一键清除。全部走原生 Liquid Glass（`glassEffect` 胶囊），候选值随搜索结果聚合并记忆化（随批次落账，不随界面求值重算）。搜索固定全站（与官方默认一致），「搜索范围」站点选择弹窗整个移除，站点收窄一律走结果筛选；原整表单筛选弹窗移除。
- **资源搜索结果懒加载（MoviePilot）**：聚合结果多时页面内存暴增、操作卡顿——筛选+排序原先在每次界面求值时全量重算（关键词逐键输入、流式批次、下载按钮状态变化都会触发），整表结果也无差别塞进列表。现在筛选+排序结果记忆化，只在搜索批次落账、筛选弹窗勾选/清除、排序切换这几个赋值点重算；列表按 60 条一窗懒加载物化，滚到底部自动续载并显示「已展示 X / Y 条」，视图 diff 与卡片状态只随窗口走。全量结果仍留在内存（筛选候选聚合与下载时原样回传服务端需要），但界面求值与渲染开销不再随结果数线性放大。
- **播放内核升级到 fork 的 `v0.1.7+dolby.3`，修复播放中切换全屏的音画失步**：全屏 Space 切换动画期间 WindowServer 扣住 `CAMetalLayer` 全部 drawable，内核渲染线程的 `nextDrawable()` 会被阻塞（实测 733ms，GPU 本身仅 0.4ms），而音频补泵同在该渲染 tick 上——音频环（原 ~290ms 存货）被抽干，underflow 约 450ms 静音；更糟的是恢复后积压回填让环指针落后时钟 ~0.7s，距离型 stale 判定（250ms）把之后所有时钟重锚永久拒绝，**失步一直持续到手动 seek/暂停**（trace 实测 35,769 次重锚全部被拒）。三处内核修复：Metal surface 启用 `allowsNextDrawableTimeout`（拿不到 drawable 跳帧而非阻塞，含跳过计数与节流诊断）；播放时钟对音频环样本改按设备活性判定（计数推进即重锚，大偏差走既有 snap），积压照常播出、画面短暂定格后重新对齐；CoreAudio 输出环 1.2s 真门控 + worker 预填同步加深，停顿期间音频从积压播出。真机压测：6 次全屏切换 underflow 从 1,140ms 降至 25ms（不可闻）、时钟校正零断流、窗口态渲染 tick 均值 1.35ms。C ABI 无变化，下载哈希 pin、脚本与 CI 钉点同步换版。
- **`build-macos.sh` 支持 `SKIP_ERIKA_FETCH=1`**（与 `package-macos.sh` / `package-ios.sh` 同一开关，含 shim 头防呆）：此前 build 脚本无条件跑 fetch，会把手动铺进 Vendor 的自编译内核按钉点版本静默覆盖回 Release 产物。

- **播放内核升级到 fork 的 `v0.1.7+dolby.2`，新增杜比视界支持**：内核在 HTTP 预读之上引入杜比视界 RPU 处理——profile 5（单层非兼容）自动回落 FFmpeg 软解并按 RPU 逐帧重映射色彩（libplacebo 同路线），profile 8（HDR10 兼容双层）保持硬解走 HDR10 底层；C ABI 无变化，预读链路不受影响。下载哈希 pin、脚本与 CI 钉点同步换版。
- **播放信息面板「动态范围」标注杜比视界**：从 Jellyfin/Emby 的流信息（`MediaStreams.videoRangeType`）识别杜比源，杜比片源不再裸报 HDR (PQ)/SDR——输出端实际映射成 SDR 时显示「杜比视界（映射 SDR）」（SDR 屏上放杜比片的最常见场景），真出 HDR 时显示「杜比视界（HDR）」；输出状态来自内核 `get_output_status` 的新封装（`PlaybackOutputEncoding` 中立枚举进 `PlaybackEngine` 协议）。本地文件/手动 URL 拿不到服务端流信息，维持原有文案。

- **详情页简介在 Mac / iPad 上同样超行折叠**（原先只有 iPhone 折叠、桌面端全文铺开）：超过 3 行截断，底部附「展开全文」/「收起」按钮，与紧凑宽度行为一致（仅字号随宽度）。按钮按实测截断与否显隐——全文不足 3 行不出按钮，窗口拉宽到不再截断时自动消失，收起状态重新截断时恢复。
- **详情页新增 Emby 风格全页氛围背景**（设置 → 界面 →「海报氛围背景」，默认开）：开启时去掉英雄区横幅，海报、标题、元数据与播放钮直接浮在整页 backdrop 氛围背景上——背景低档模糊（能认出是哪部剧）、固定不随滚动，全屏遮罩日间白雾 / 夜间黑纱，无额外压暗带。头部文字与按钮颜色跟随外观自适应（日间深字、夜间白字），白色按钮带柔和投影分界；两种布局共用同一套自适应文字——清晰横幅布局的压字渐变日间换白雾、元数据行同样随外观变色。条目没有 backdrop 图时始终走清晰横幅布局。氛围图为 800 宽小图 + 512px 解码下采样，不为糊图拉原画。
- **首页背景库内随机 backdrop 渐变轮播**（同一开关控制）：服务器端 `SortBy=Random` 从全库随机取 8 张带 backdrop 的电影 / 剧集（查询失败或为空回退首页已加载条目），同样模糊+雾化垫底，每 12 秒淡入淡出换一张（减弱动态效果时保持静态首图）。首图进缓存后才亮相，其余后台预热，切换零占位闪烁；切换服务器会话或开关时自动重取。
- **播放器 HUD 改用原生 Liquid Glass 液态玻璃（Infuse 风格）**：右下角五个功能入口（弹幕/字幕/音轨/章节/更多）从标题行旁的独立圆钮改为融合成一颗玻璃胶囊，悬浮在进度条上方右侧；点开的按钮整体液态形变为玻璃面板，其余按钮回流成短胶囊，点击面板外任意处收起。面板内容重写为「行 + 子菜单」结构——根层是「图标 + 标题 + 当前值 + 箭头」的行列表（如「不透明度 100% ›」「字幕轨道 简体中文 ›」），点入后子菜单滑入显示选项（选中行带 checkmark）、返回滑出；音轨与章节保持单层选单；弹幕根行含启用开关与匹配状态徽章。面板内不再放关闭/快速切换按钮：切换 Tab 直接点胶囊上其余按钮，与 Infuse 一致。
- **最低系统要求提升至 macOS 26 / iOS 26**：HUD 玻璃改用系统原生 `glassEffect`（原先 26+ 才走玻璃、旧系统回落 ultraThinMaterial 的双轨制移除，旧系统不再支持）。
- **播放器「播放信息」与「播放统计」合并为一个面板**：更多面板里的两个开关收敛为单个「播放信息」开关，面板从两块各自为政的散字改为分区排版——播放（状态/进度/倍速/音量/章节）、视频（分辨率与宽高比、动态范围 HDR/SDR、色彩空间、出画状态）、音频（当前音轨与采样率）、字幕（当前字幕轨，外挂标注）、内核统计（解码/渲染/硬解/软解/零拷贝/音频帧/失败计数，每秒刷新）。
- **首页右上角新增刷新按钮**：长期停在首页也不怕数据过期，点一下重新向服务器请求首页与媒体库数据（等同下拉刷新）；按钮为 macOS 26 / iOS 26 原生液态玻璃工具栏样式，加载中原地转圈，未连接服务器时置灰。
- **设置页新增「弹幕诊断日志」调试开关**（默认关闭）：开启后弹幕 overlay 记录时间轴对齐点、爆发发射与续播定位日志（写入 `~/Library/Logs/OcPlayer/diagnostics.jsonl`），用于排查「续播起播爆出一大片非当前时间点的弹幕」等时间轴错位问题；平时保持关闭以减少日志噪声。

### 修复

- **弹幕装载在主线程解几 MB JSON**：`DanmakuService` 早在 actor 上把弹弹play 弹幕转成了 Erika JSON 串，界面侧拿到后又在**主线程**解码 + 排序一遍——三万条 = 主线程 100–400ms，正好压在「源就绪、视频起播」这一拍。现在转换与排序都留在 actor 上（`DanmakuJSONConverter.entries(from:)`，与 JSON 路线共用一套滤镜判据），overlay 装载只是赋值；JSON 串保留给当前停用的内核弹幕轨路线。新增 2 个包用例钉住「两条产出路径同结果」。

- **2s 阈值内的前向 seek 把窗口内弹幕一帧喷完**：出场循环没有单拍上限，往回跳 1.9s（不到 `seekJumpSeconds` 的 seek 重同步阈值）时窗口里几十到几百条会在同一拍出场，每条都要测字宽、取 cell、建视图。现在发射决策抽成 `DanmakuSpawnPlanner`：每拍最多 24 条、超出顺延（60Hz 下约 1440 条/s，远超正常密度），积压跳变的清屏兜底原样保留。新增 6 个用例（正常节奏 / 上限顺延 / 1.9s 前向 seek 摊成 7 拍 / 跳变清屏 / 指针越界钳制）。

- **截图瞬间整个播放器卡住**：`captureScreenshot` 在主线程一气做完取帧（33MB 缓冲分配 + 持引擎锁整份拷贝）、PNG 编码（再拷一份 + CGImageDestination）与写盘，4K 片可达数百 ms——期间 HUD / 手势 / 弹幕全冻。现在只有取帧留在主线程（必须与渲染线程串行），编码与写盘挪到后台任务，回来后只更新界面提示；顺带加一条「截图编码写盘 宽x高 耗时=Nms」诊断日志。

- **MoviePilot「保存并登录」失败会毁掉原本可用的会话**：改密码打错一次（或把地址改到另一台服务器再登录失败），错误凭据已经落盘、旧 token 已被删——点「取消」也救不回来，之前能用的 MoviePilot 会话彻底没了（gate 变「未登录」，后续请求 401 → 静默重登拿着错密码 → 通知登出）。现在登录前先打「服务器地址 / 用户名 / 密码 / token」四键快照，失败把快照原样还原（含旧 token），错误凭据只作尝试不落盘；成功路径不变（换凭据 ⇒ 旧 token 照旧作废）。同批修掉密码被静默 trim：含首尾空格的密码此前被改写、登录永远失败且无提示，现在密码原样存取与发送（地址与用户名仍 trim，判空用 trim 结果）。快照与回滚落在 `MoviePilotStore.credentialSnapshot()` / `restore(_:)`，新增 3 个包用例钉住「失败不动旧值」。

- **MoviePilot 订阅里清空的字段清不掉**：编辑订阅以服务端原始记录起底，「自定义存储路径」「TMDB / Bangumi / 豆瓣 ID」「海报」「简介」这几个字段只做「非空才写」、清空不回删——用户删掉存储路径或 ID 保存后旧值原样回传服务端继续生效（而关键词 / 包含 / 排除 / 画质同表却是会删的，一张表单两套语义）。现在可清空字段统一走 `MoviePilotSubscribeFieldRules`：空 = 从字典删键；成对键（`tmdbid`/`tmdb_id`、`doubanid`/`douban_id`、`bangumiid`/`bangumi_id`、`poster`/`poster_path`、`overview`/`description`）同进同出——只删一个等于没删，读侧是 `raw["tmdbid"] ?? raw["tmdb_id"]`。简介仍写原值（保留换行）、判空用 trim 结果。新增 5 个规则用例。

- **Bangumi 条目瞬时网络抖动下被清出「在看」**：单条目接口 `p1/subjects/{id}` 本就不返回收藏状态，回读路径（详情页加载、播放结束后的进度对齐）靠附加请求补，补失败即 `nil`——而落库把 `interest == nil` 当成「服务端确认没收藏」，把本地 `interest`/`ctype`/`collectedAt` 一并清零：条目从「在看」消失、已看进度与评分归零，直到下次全量同步才回来。现在「按 nil 清空」改成显式参数 `authoritativeInterest`：只有收藏全量同步（每页都带收藏状态）这条权威路径传 `true`，单条回读与进度对齐默认保留本地收藏态、只更新元数据（本地改收藏走专用方法，从不置 nil，不受影响）。新增 2 个库用例（非权威保留 / 权威仍清空）。

- **GitHub CI 修复：fetch-erika.sh 全角逗号粘连变量名 + v0.1.9+dolby.1 资产哈希 pin 过期**：CI 自 09-10 起秒挂，根因两条——(1) 脚本 4 处 `$var，` 全角逗号直接粘在变量名后（203 行 `$expected，`、三处 `$f，`），在 CI runner 的 bash/locale 下被当成变量名一部分，`set -u` 直接报 `expected: unbound variable`（3b39961 修过同款 `$PINNED，`，本次漏网；已全部改 `${var}` 花括号隔离）；(2) v0.1.9+dolby.1 的 macOS 资产在本地下载（09-10 13:21）之后被重新上传，pin 哈希停留在旧资产（98cde716），缓存过期后 CI 首次实拉即哈希不匹配——粘连 bug 又把真实的「哈希不匹配」报错吞成 unbound。pin 已更新为线上资产哈希（7b622c21），本地全流程（实拉→校验→合成 xcframework→缓存复用）验证通过。

- **播放信息面板打开时快捷键操作后 HUD 不再自动收起**：`canAutoHideControls` 此前把 `showInfoPanel` 一并收进「不许自动隐藏」——面板开着时用快捷键调进度/音量唤出的 HUD 被钉死，直到关面板或鼠标移出窗口才消失。信息面板只读、`allowsHitTesting(false)`、且独立于 HUD 挂载（HUD 卸载后它照常每秒刷新），不依赖 HUD 常驻，从规则中移出后两者各自独立显隐。

- **跳过钮被面板压住、且展开动画被打断**：展开面板高度上提到 PlayerScreen 后，跳过钮保持单实例、锚点改为「簇底距 + 按钮高 + 间距 + 面板高度」平滑上移；上一版挂在卡片 overlay 里的副本会因挂载时的 prompt 状态写入打断 `glassEffectID` 液态展开动画（面板直接弹出），副本已移除；面板切子菜单变高变矮时跳过钮跟随移动，`reduceMotion` 生效。

- **HUD 展开面板被撑满 320pt**：`ScrollView` 是贪婪布局、`frame(maxHeight:)` 只封顶不收缩，只有一个选项的子菜单也撑满 320。改为隐藏镜像（`fixedSize` 实测自然高度）驱动分支——内容 ≤320 原生高度贴合，超出才滚动（`ViewThatFits` 方案在 `GlassEffectContainer` 内实测不生效，弃用）。

- **氛围背景不铺侧栏、顶栏露出窗口底色**：页面的氛围图此前挂在详情列 ScrollView 的背景上，而 macOS 26 的 `NavigationSplitView` 里只有**栈根**的背景能铺满全窗（首页轮播正是这样垫到侧栏玻璃底下的），pushed 页被裁在详情列内、导航栈宿主自带不透明底——在列内垫什么都连不到侧栏，侧栏整列（尤其下半截）空玻璃，详情页顶部工具栏区域还会露出一条窗口底色。现在有氛围图的页面出现时经 `windowAmbience(_:)` 向 `AppModel.windowAmbience` 声明、离屏时撤回（MoviePilot 资源搜索页声明海报、详情页声明 backdrop，与「海报氛围背景」开关一致），AppShell 把声明图垫在整块 `NavigationSplitView` 后面——透明的 pushed 页、侧栏玻璃和顶部工具栏透出的都是同一张连续的图，观感与首页完全一致；返回或切到无氛围页自动回落系统玻璃，iPhone 紧凑布局没有整窗层、页面自垫不受影响。实现坑：氛围图的 fill 溢出若作为 ZStack 兄弟参与布局会把 split view 撑出窗口，必须走 layout 隔离的 `.background` 挂载；层必须在调用点显式 `ignoresSafeArea()`——详情页这类自带顶部 ignoresSafeArea 滚动视图的页面会改变层继承到的安全区，让图片被 `.clipped()` 裁到工具栏以下。
- **iPad 氛围布局海报被顶部导航栏按钮遮挡、上沿发糊**：详情页氛围头部内容整体越过顶部安全区，顶部只留 64pt，而 iPadOS 26 导航栏的玻璃按钮（侧栏开关 + 返回）悬深到 ~76pt、滚动边缘渐进模糊尾部到 ~82pt——海报顶部正好压进两者：上沿一截被系统渐进模糊洗掉，收起侧栏后海报左缘（52pt）正对按钮列，左上角直接被玻璃圆钮盖住（侧栏展开时返回键也压着海报一角）。现在 iOS 上头部顶距抬到 104pt，海报整张落在模糊带与按钮之下；Mac 工具栏浅，维持原深度不变。
- **看完一集退出到详情页，Bangumi 章节格子不变「已看」**：播放结束的自动标记走「远端 PATCH → 写本地库 → 广播失效通知」，而详情页内嵌的 Bangumi 章节区块一直没监听这条通知——它唯一能感知的刷新（退出播放器触发的 `detailRefreshGeneration` 重载）通常赶在标记落库之前，自动标记完成后也没有任何信号再推它重读，格子就停在旧的未看状态（手动点标记因为更新完自己重读，所以有转圈和即时刷新）。现在章节区块与进度页 / Bangumi 条目详情页同款：监听失效通知、按关联条目过滤后重读本地库，自动标记落库后格子立刻刷新。
- **弹幕网关挂掉时误报「未匹配到剧集」**：自动匹配的四级降级检索（Hash → TMDB → 标题+集数 → 提纯标题）每级都把请求错误静默吞掉，网关宕机、断网、额度用完最终都落成「未匹配到剧集」，用户误以为这部剧没弹幕且日志无告警。现在任何一级检索抛错都会落到「失败可重试」态并复用稳定文案（额度用完 / 网络请求失败 / 服务暂时不可用），全部干净无结果才报未匹配；错误路径升 warning 日志。同批顺带：open 在飞期间字幕缩放 / 弹幕设置 / 选轨等入口不再撞引擎长持锁（loading 中动菜单不再卡主线程）；loading 中按下的暂停在起播后生效；弹幕解析的 ~20 个正则改静态编译，长篇全集搜索不再卡主线程；文件名解析支持行首发布组位与年份括号剥除（VCB-Studio 等枚举外组名不再污染标题、[2023] 不再混进标题）。
- **网络差时播放加载页让整个 App 卡死（繁忙光标、取消按钮点不动）**：内核打开媒体源是在调用线程上同步完成网络连接与格式探测的，而这条调用整个跑在主线程上——弱网下连接 + 探测可达数十秒（DNS 解析甚至没有超时），主线程不处理事件就是 macOS 的「繁忙」转圈光标，loading 层的取消按钮根本点不了；就算点得了，取消路径的 stop / detach 也要和正在进行的 open 抢同一把引擎锁，照样卡死。现在 open 的阻塞段移到专用串行后台队列（完成后回主线程落状态，代次守卫防串台）；引擎适配层加「让位契约」——open 在飞期间 stop / detach / resize 只登记意图立即返回、由 open 收尾补做，play / seek / 改速率音量直接丢弃，统计快照与媒体时间一样走独立小锁，loading 轮询首帧标志不再撞锁。取消、换片（自动连播）、失败重试全程主线程零阻塞，取消按钮即点即生效；另加 60 秒看门狗，open 卡死时强制转「连接超时」给重试入口，不再无限黑屏；同请求重入不会二开。
- **关闭播放器时闪现「画中画样式」的占位画面**：点 × / ESC 后引擎被同步停掉，无引擎占位图（画中画样式图标 + 剧集标题）与常驻 HUD 在停播到退出播放器的约 0.25s 窗口期裸露闪现。现在关闭时窗口先带着正在播的画面缩回原位（与打开时的展开动画对称）、HUD 同步淡出，缩完再停引擎并退出播放器，全程看不到占位图；停播前校验屏上仍是被关的那片，不会误停窗口期内新开的内容。
- **继续播放起播时爆出一大片非当前时间点的弹幕**：续播 seek 与弹幕注入竞速，注入时媒体时间还在片头 0.5s，弹幕出场指针被对齐到片头；seek 跳到续播位后跳变检测又被 resync 后的首拍空窗吞掉，0.5s~续播位之间的弹幕被一次性补发。现在 resync 后首拍照常做 seek 跳变检测，且发射端增加兜底——两次发射机会之间媒体时间前进超过 2s（漏检跳变）时清屏重对齐、跳过积压的过期弹幕，任何路径的漏检都不可能再把一大片旧弹幕喷出来。
- **首页「继续观看」与「接下来看」重复**：播了一部分但没看完的剧集会被服务器同时算进两条 Rail——Resume 按 IsResumable 收录它，NextUp 又把它当「第一部未看完的剧」（服务端只认 PlayCount，半集仍是未看）。现在有播放进度的条目只留在「继续观看」，从「接下来看」剔除；首页骨架屏有无记录与剧集详情页「播放」按钮的条目复用同步适配。

## [0.1.5] · 2026-08-30 · Emby 适配、iOS 安装包与自编译预读内核

### 服务器支持

- **新增 Emby 服务器适配**：登录流程探活时自动识别服务器类型（`ProductName` 含 Emby / 主版本 4.x），Emby 走 `/emby` API 前缀与老式路由（媒体库 `/Users/{id}/Views`、继续观看 `/Users/{id}/Items/Resume`），账号密码登录、浏览、播放、图片、字幕、播放上报全链路可用。Emby 没有 Quick Connect（Jellyfin 独有），登录页在 Emby 服务器上只显示账号密码表单；Emby 老版本密码错误返回 400 时也归入「账号密码不对」提示。服务器卡片显示所属类型（Jellyfin / Emby）。
- `ServerProfile` 新增 `kind` 字段（jellyfin/emby）；旧版本落盘的档案无此字段，解码默认 Jellyfin，静默恢复不受影响。
- **多服务器记忆与快速切换**：登录页新增「已保存的服务器」区块，token 还在的一键重连；设置页「服务器」区块列出其余已保存的服务器，支持就地切换和删除（删除连 token 一起清，有确认弹窗）。登出不再等于遗忘——档案持续保留，来回切服务器不用重新输地址。启动恢复也更聪明：当前服务器 token 失效时自动尝试其它有有效 token 的档案，而不是直接弹登录页。

### Emby 真机联调修复

- **标记已看/取消已看失败**：`/UserPlayedItems/{id}` 是 Jellyfin 新式路由，Emby 上不存在（404）。Emby 改走老式 `/Users/{uid}/PlayedItems/{id}`；详情页「标记已看」按钮在 Emby 上恢复可用。
- **播放时 MediaSegments 404 日志噪音**：`/MediaSegments/{id}` 是 Jellyfin 插件提供的端点，Emby 没有。Emby 服务器现在跳过该调用直接回退章节启发式。
- **外挂字幕下载路径**：路由第二段原先硬编码为条目 id，多版本条目（同一影片挂多个 MediaSource）会 404。现从 `/Items` 响应透传真实的 MediaSource id；单源条目行为不变。
- **章节与条目详情解码失败**：Emby 响应洗白规则误伤顶层 `Type` 字段，SDK 解码报 "Cannot initialize BaseItemKind from invalid String value Default"，章节列表每次都拉取失败。改为按 `MediaSources` key 精确处理子树；回归测试覆盖真实机场景。

### iOS

- **首次提供 iOS 安装包**：release 附带未签名 IPA（`OcPlayer-<版本>-ios-unsigned.ipa`），通过 AltStore / Sideloadly / TrollStore 等工具重签安装；与 macOS 包同一内核、同一测试门禁。iPhone 与 iPad 均已真机验证。
- **播放画面手势**：长按 2 倍速（HUD 独立「▶▶ 2.0x」徽章，不唤醒面板）、横滑 seek（独立进度条）、纵滑调节亮度/音量；手势收敛为单一状态机，双击暂停不再被吞，多指不再误触发，切后台/来电自动收尾。
- 打开播放器自动转横屏；iPad 浏览态跟随重力旋转，不再锁竖屏；iPhone 首页横向卡片收紧显示更多内容、详情页紧凑重设计、海报上下渐变适配全端。
- iOS 测试链路修复：测试 target 改为零产品依赖 + BUNDLE_LOADER，Archive 链接失败修复。

### 播放内核（Erika）

- **网络预读缓冲可调**：设置 → 播放 新增「网络预读缓冲」（默认 2 MiB / 8 / 16 / 32 MiB）。公网高延迟服务器（远程 Emby 等）建议 16 MiB 以上，可显著减少播放中的反复缓冲。基于自编译 Erika 内核新增的 `erika_presenter_open_with_options` C API（fork 分支 `feat/http-readahead-option`，已提上游），逐请求生效，本地文件自动忽略。
- 发版内核 `v0.1.7+readahead.1` 的下载哈希固化入仓（`Scripts/erika-v0.1.7+readahead.1.sha256`），构建时可复验。
- 修复拉取脚本 zip-slip 防护对绝对路径归档必然误报的问题（会让全新 CI 环境无法拉取内核）。

### 应用内更新

- 关于区显示版本号，可手动检查 GitHub Release 更新；应用启动与进入设置页时静默检查，发现新版本自动弹窗，支持「忽略此版本」。

### 新功能与优化

- **Jellyfin Clear Logo**：媒体库与详情页支持服务器提供的透明 logo 展示。
- **Bangumi**：播放结束自动标记已看时先把条目推进为「在看」；番剧候选打分算法多维度优化并与剧集季信息联动。
- 详情页海报顶部/底部渐变过渡适配全端。

### 播放器修正

- 弹幕颜色为负数时先夹紧再转换，修复内核 trap 崩溃（P0）。
- seek 不再越过片长；内核重复错误事件去重。
- 保底跳过片尾记入会话，按钮不再原地循环。
- 弹幕「时间偏移」按 overlay 数据显隐；暂停态下弹幕恢复逻辑不再被误触发。
- 音量落盘 300ms 尾去抖并在停止收口补写，消除丢失窗口；2x 临时倍速不再持久化。

### 稳定性与性能

- 播放停止后 malloc pressure relief 四拍调度（+2/+25/+60/+120s），进程占用回落更快。
- RemoteImage 复合加载键守卫修复：图片悬停闪烁（认证头字典序抖动致缓存键漂移）与全量图片不加载回归。
- 详情页横幅渐变被裁剪的回归修复（图片层定高钳制）。
- Bangumi 数据库换 DatabasePool（WAL 多连接并发）；弹幕网关响应单遍解码、mapping 内存缓存；overlay 采样 Timer 频率自适应；Erika idle 帧率档。
- 网络健壮性：429 读取 Retry-After、退避加抖动、鉴权 401 发通知引导重登、用户取消原样透传、MoviePilot 静默重登加看门狗与熔断。

### 工程与质量

- 2026-08-29 全项目 review（161 条）处置完毕：P0–P3 全部收官，覆盖并发、网络、性能、构建与 UI 细节；报告入库 `Reports/review-20260829.md`。
- 发版流水线：tag 构建必过全量测试门禁；Erika 环境准备抽为 composite action；SwiftPM 构建加缓存；`MARKETING_VERSION` 收敛 `App.xcconfig` 单源。
- release 新增 iOS 产物：`OcPlayer-<版本>-ios-unsigned.ipa` 与 `SHA256SUMS-ios.txt`。

### 随 0.1.4 附带但当时说明未展开

以下功能已包含在 0.1.4 的安装包中，当时发布说明过于简略，在此补记：

- Bangumi 全套：OAuth 登录、进度管理、个人主页、收藏列表、番剧日历、播放联动（看完整季自动推进条目状态）。
- MoviePilot 全套：设置页登录、找片下载（搜索 → 选种 → 下载）、订阅管理。
- 播放器章节列表与片头片尾/末 90 秒跳过；弹幕手动搜索选集与 HUD 弹幕菜单。

### 版本

- 版本号 0.1.5。

## [0.1.4] · 2026-08-25 · UI 规范统一与弹幕渲染路线收敛

### 弹幕

- **内核内置弹幕渲染器（Erika DFM+）被禁用**：内核的滑窗重排仍会让在屏弹幕跳轨，本版本起运行时强制走 App 层 overlay（`DanmakuRenderKit`），设置 → 播放内核 中的「用内核渲染弹幕」开关置灰并附原因说明。内核修复后恢复该开关与偏好读取（`PlaybackPreferences.danmakuUseOverlayRenderer` 保留）。

### 界面与交互

- 设计规范统一：状态色、骨架屏、文案、圆角、悬停反馈、键值行展示收敛到同一套样式。
- 高频文案收敛：`UIStrings` 集中常量替代裸字面量。

## [0.1.3] · 2026-08-20 · 弹幕完整链路与播放体验打磨

### 弹幕

- 串起 OcPlay 网关到 Erika 的完整播放链路：已有剧集映射直接复用；首次匹配先用本地文件或带认证头的远程 HTTP Range 数据计算前 16 MiB MD5，再以文件名、哈希、大小和时长一次性匹配；结果与弹幕正文分层缓存，并保留分集时间偏移。
- 播放器 HUD 新增弹幕开关、自动重匹配、手动搜索选集、时间偏移、不透明度、显示区域和顶部 / 底部 / 滚动类型过滤；换片、重试和退出会取消旧任务，并用播放源代次阻止旧弹幕注入新视频。
- 设置页支持编辑 HTTPS 网关地址、以安全输入框保存 API Key 和控制自动加载。未自定义时使用默认网关和内置公共 API Key；显式无效地址才会停用弹幕且不影响视频播放。
- DanmakuKit 增加远程 Range 哈希、匹配编排、缓存格式迁移、请求参数校验和异常弹幕过滤的离线测试。
- 弹幕诊断日志补充安全文件名、大小、时长、匹配模式、哈希是否存在、手动搜索词、Episode ID 和正文数量；不记录完整哈希、媒体 URL、认证头或 API Key。

### 稳定性

- 保护 Erika counted-array 轨道读取：限制填充数量不超过缓冲区容量，并在成功、失败路径释放已填充记录。
- 修复媒体库切换时旧异步请求回写新库状态的竞态；旧请求不能覆盖新数据或提前清除 loading 状态。
- 保证弹幕 fallback ID 避开整批真实 `cid`，并严格校验远程 `206 Content-Range` 的完整性，拒绝截断响应。
- 为 `ServerStore` 的 profile/current ID 复合读改写操作增加统一锁，并补充并发保存回归测试。
- 为字幕副本、播放截图和诊断日志增加启动/每日维护与容量上限；日志同时增加 30 天保留、超大单条保护和旧文件尺寸校验。
- 图片缓存保持 512 MiB 硬上限，设置页新增当前用量和手动清空入口。
- `PlayerScreen`、`DetailView` 拆出独立组件；Jellyfin 客户端版本改为读取 App version/build，弹幕 User-Agent 保持纯 marketing version。
- 从 `AppModel` 抽离 `PlaybackReportingCoordinator`，独立负责 Start / 10 秒心跳 / Stopped 的顺序化与去重；新增 macOS App 测试 target，覆盖后台快照、自然结束与显式退出竞态、重复停止、跨片等待和播放请求身份隔离。
- 明确 Jellyfin 不提供收藏时间；收藏轮播按收藏过滤后使用媒体入库时间倒序，不再描述为“最近收藏”。

### 播放器界面与交互

- 即时播放加载态：loading 覆盖到内核出帧，消除两段式等待；保底 400ms，加载过快不再闪现晃眼；消除出画面白闪。
- 单击播放区切换 HUD，暂停改用空格 / HUD 按钮；点击关闭 HUD 后滑动不再重新打开。
- 加载态隐藏工具栏、取消按钮玻璃化，根治连点取消重来。
- 窗口比例贴合、关闭播放器时窗口先缩再退出、还原同样带弹性动画，不脱节。
- 弹幕开关加 opacity 过渡，弹幕按钮换用 text.alignleft 图标与字幕区分。

### 首页与详情页

- 移除首页轮播图功能。
- 详情页选集改为横向滚动列表，两侧加悬浮箭头（一次滚动 4 集），主按钮按选中集播放；箭头悬停显示。
- 详情页播放旁新增「已看过」按钮，与播放按钮同高胶囊、纯图标样式；继续观看卡角标悬停显示并增加边距。
- 卡片悬停抬升动画更顺滑；首页与横向列表滚动更顺滑；媒体库分页读取与播放体验修正。

### 构建与内核

- Erika 拉取脚本默认解析 GitHub 最新正式版；CI 先解析具体 tag 再建立缓存键，本地构建和打包也会每次检查最新版本并复用同版本完整产物。
- 当前 `v0.1.7` macOS/iOS release 资产已固定 SHA-256；未来未固定的新版本会明确提示校验边界。
- 播放日志统一迁移到 `diagnostics.jsonl`，使用异步串行写入、2 MB 轮转和 3 份保留。
- 设置 → 关于新增独立的开源许可证入口，按依赖图展示 Erika、Jellyfin SDK、SwiftPM 与内核原生组件；发布脚本同步聚合这些组件的许可证文本，缺失时终止打包。

## [0.1.1] · 2026-08-18 · 完善首页海报与播放器界面

### 应用图标与版本

- 新增共享 `AppIcon` 资源集：iOS 使用浅色默认图标和深色外观图标，macOS 使用深色图标并提供 16–1024 px 的完整尺寸。
- macOS / iOS 的 Debug 与 Release 配置均显式使用 `AppIcon`，后续 Xcode 构建会自动编译并写入 App 包。
- 工程版本与 Jellyfin 客户端版本统一更新为 0.1.1；本地打包脚本和 GitHub Release 工作流的默认标签同步为 `v0.1.1`。

### 首页海报与布局

- 轮播横幅宽度改由外层视口真实宽度约束，修复侧栏开合时横向内容宽度泄漏、横幅超出详情列的问题。
- 轮播页码标识从数组下标改为媒体 ID：数据刷新后页码身份保持稳定；冷启动时明确按页首对齐，不再把第一页停在两个页面之间。
- 窗口缩放（live resize）时等布局稳定后无动画重锚当前页，避免用旧页面位置对齐新视口造成错位。
- 修复长标题横幅在窄窗口下左右各被裁掉约 52pt 的问题（边距与约束顺序调整）。
- macOS 窗口最小尺寸设为 960×620，保证英雄区标题边距和操作按钮可读。

### 播放器界面

- 重构播放器 HUD 与本地配置（音量 / 进度 / 倍速等控件布局统一）。
- 新增 P2 HUD 并接入 Liquid Glass 风格。
- 修复音量拖动：拖动过程即时生效，松手不再回弹。

### 播放核心

- 播放地址解析任务支持取消：快速连续切换播放内容时，旧请求不会在新请求之后返回并覆盖播放器；退出、换片、注销时都会取消未完成的解析。
- 系列 / 剧集类条目播放前先解析为具体可播放的剧集（优先「接下来看」，否则取首个未看完的常规剧集），不再把 Series ID 直接送进流地址；续播位置随解析结果联动。

### 验证

- `swift test --package-path Packages/JellyfinKit`：32/32 通过；`swift test --package-path Packages/ErikaKit`：13/13 通过。
- macOS Debug / Release App 构建通过；Release 产物已确认包含 `AppIcon.icns` 与完整 `Assets.car`，App 的 `CFBundleIconName` / `CFBundleIconFile` 均为 `AppIcon`，ad-hoc 签名校验通过。
- iOS target 已解析 `AppIcon` 与浅色 / 深色槽位并进入资源编译阶段；当前机器未安装 iOS Simulator runtime，完整 iOS 构建仍受本机环境限制。

## [0.1.0] · 2026-08-17

### 首页

- 新增轮播：多张英雄图自动切换；设置页新增「轮播使用收藏」开关，可在「最近添加 / 我的收藏」间切换数据来源。
- 修复收藏轮播为空时区域消失的问题：收藏请求失败或收藏全无背景图时按「最近添加」回落，不再整页报错或留空。
- 修复从首页轮播进入详情页时页面背景透明的问题；详情页现在显式使用系统页面底色。

### 修复

- 修复 `JellyfinError.wrap` 错误归类失效：先 `as NSError` 会把 `APIError`（enum）桥接掉，`as? APIError` 永远失败，401/404 全部漏进「其它错误」；改为先判 `APIError` / `JellyfinError`，最后才桥接 `NSError`。
- 图片加载改为「内存解码缓存 + 请求去重」：同一张图并发出现只发一次网络请求（列表快速滚动不重复拉）；任务取消（视图消失 / 换 URL）不再被当成加载失败，换 URL 时旧请求自动作废。
- 保存服务器列表编码失败不再静默吞掉：原来 `set(nil)` 会直接把服务器列表 key 删掉（等于清空已登录服务器），现在失败只记日志、保留旧数据。
- 修复退出播放后立刻再播放时，异步窗口还原可能把新播放窗口误拉回旧帧的问题（还原前校验窗口身份与播放会话）。
- 设置页「关于」的描述同步当前状态：直连策略改为「优先直连直解（DirectPlay），播放前经 PlaybackInfo 选择媒体源；不支持直连的源回退直连流（DirectStream）」（原文案的「码率超限时请求转码」尚未实现）；弹幕改为「暂缓接入」（M3 已暂缓）。
- 修复详情页演员名字 / 角色不显示：演员头像宽高都固定为 108×108（只给宽度时 RemoteImage 占位竖向撑开、文字被挤出可视区），详情请求显式携带 `fields=People,Genres,Overview`（部分服务器版本默认不返回扩展字段）。
- 修复“播放 → 退出播放 → 再次播放”后所有视频都打不开的问题；退出播放时不再把旧源标记为待换片，并直接重建播放引擎，避免旧 presenter 进入不可 reopen 的 closed 状态。
- 修复播放中换片 / 自动连播失败的问题（详情页点另一集、播完自动连播下一集、`onOpenURL` 换片）：换片不再对内核 `close()` 后 `open()`（`close()` 是终态，同一 presenter 不可 reopen，实测抛 `ErikaError "player is closed"`），改为 `stop()` 后丢弃旧引擎重建；播放画面承载视图跟随引擎身份重建（`.id(engine)`），否则新引擎不挂画面、状态事件收不到，换片后 UI 卡在 idle。
- 修复首次连接因网络异常失败后，点击首页重试虽然恢复内容但侧边栏媒体库仍为空的问题；重试和下拉刷新现在会同时重新加载媒体库与首页数据。

### 播放核心

- 接入 `PlaybackInfo` + `DeviceProfile`：播放前先请求服务器媒体源信息，优先选择支持直接播放的 `MediaSource`，并在直连 URL 中带上 `mediaSourceId`；老服务器或 PlaybackInfo 不可用时自动回退到原来的直连 URL。

### 调试

- 增加播放链路文件日志：`~/Library/Logs/OcPlayer/playback.log`，记录引擎创建、open/close/stop/attach/detach、播放状态变化和错误，方便复现“退出后再播放失败”时定位。
- 修复电视剧详情页中系列海报、标题、元数据和播放按钮被 320 pt 横幅裁切的问题。
- 修复分集列表中图片高度随加载状态变化，以及图片和标题在刷新/换季后错位的问题。
- 修复注销后旧会话的首页、媒体库、进度上报、下一集和外挂字幕请求回写新会话的问题。
- 详情页将必要的详情/季/集数据与类似推荐解耦；切季时清空旧集列表并显示加载失败、空列表状态，剧集没有真实集数据时不再播放剧集容器。
- 修复本地视频和手动字幕在 iOS 文件选择器回调结束后失去访问权限的问题；字幕会复制到应用支持目录，视频权限保持到播放结束。
- 修复播放源替换失败后残留当前 URI、音量 0 被当成未保存、字幕字号不持久化等播放状态问题。
- Jellyfin 媒体库浏览改为按 `startIndex` 分页读取全部条目；全剧集请求按季号和集号排序，避免跨季连播顺序错误。
- 自动连播跳过第 0 季（特典/花絮），看完特典不自动跳下一集。
- 首页加载不再因会话切换残留 loading 态；登录后不等首屏数据返回，Quick Connect 轮询流即时结束。
- 网络错误细分：连不上（DNS / 拒绝连接 / 断网）仍提示检查地址，超时 / 连接中断带具体传输错误细节。
- 图片加载失败后，视图再次出现时会重试（之前一次失败永久 404 到退出）。
- 为 iOS 生成的 Info.plist 增加局域网访问说明和 ATS 局域网配置；移除 SwiftPM 锁文件忽略规则，锁定依赖版本。

### Jellyfin 图片数据

- 分集请求显式获取 `Primary` / `Thumb` 图片并按集数排序。
- 分集不再把父剧集的海报 tag 当作自己的图片；`RemoteImage` 在 URL 变化时会清理旧图片状态。

### 验证

- `swift test --package-path Packages/JellyfinKit`
- `swift test --package-path Packages/ErikaKit`
- JellyfinKit 31/31、ErikaKit 13/13 通过（新增「播放生命周期」回归 suite：同源/不同源 `stop` 后重开、`close` 终态锁定、连播换片重建）；macOS Debug App 构建通过。
- macOS Debug App 真实环境人工验证：自动连播下一集（播完 S1E7 → 自动切 S1E8）成功——换片后新引擎重新 attach、状态正常推进到 playing（日志 `playback.log` 实证）；从详情页点另一集与 `onOpenURL` 换片走同一条 `openIfNeeded → open` 路径。
- iOS 模拟器构建因当前机器未安装 iOS Simulator runtime 无法选择 destination；工程配置已写入双端 target。
- macOS Debug App 真实详情页人工验证：系列海报完整显示，分集缩略图与集标题逐行对应。

本轮构建目录均位于 `.local-build/`，不进入版本控制。
