# OcPlayer 媒体数据面重构

> 目标：参考 `rex_analysis/out/blueprint/16_media_data_pipeline.md`，把「同一内容多套缓存、多处取数、失效口径不同」收敛成**一个读入口、一个写入口、一个代次模型**。
> 播放流、弹幕、TMDB 补全和图片字节缓存各自保留领域边界，不纳入媒体元数据仓储。

## 问题清单（改动前）

| 问题 | 原位置 | 后果 |
|---|---|---|
| SQLite 条目缓存与 App 内存详情快照重复 | `MetadataKit` / `AppModel.detailSnapshots` | 同一详情有两份真相，TTL 与写回路径不同 |
| 库分页只存内存，磁盘 `page` 表无生产读写 | `AppModel.libraryPages` / `MetadataStore.savePage` | 冷启动与页面重建反复整页重拉，持久层留有死代码 |
| 首页、详情、预取、库搜索分别直接调用服务器 | `AppModel+Browser`、`DetailViewModel`、`LibraryView` | 重复请求、各自的取消/错误/代次规则漂移 |
| 播放进度只在部分写回路径落库 | `markPlayed` 与播放返回不同路 | 首页、详情、离线缓存可能展示不同进度 |
| 图片换 URL 时先清空普通内容 | `RemoteImage` | 卡片与详情换图出现灰闪；批量图片各自立即写入 SwiftUI 状态 |
| 图片失败只按 URL 记录 | `ImagePipeline` | 不可用宿主会产生一墙超时请求 |

## 目标边界

```
AppModel / DetailViewModel / LibraryView
                │
                ▼
MediaDataCoordinator（@MainActor，生命周期与维护）
                │
                ▼
MediaRepository（actor，MetadataKit）
  内存投影 → SQLite（MetadataStore） → Jellyfin/Emby（MediaServer）
  同键单飞 / 统一失败分类 / 统一进度写回 / 租户隔离
```

- **仓储只负责媒体元数据**：库列表、首页 rail、条目、季、集、合集成员、库页与搜索页。
- `playbackInfo`、流地址、章节、外挂字幕、上报继续直走 `MediaServer`，不进入缓存。
- 磁盘损坏或建库失败时使用内存仓储，应用不再退回另一套读取实现。
- 视图只保留选中季、滚动锚点等会话内 UI 状态；跨视图内容缓存由仓储持有。

## 落地结果

- `MediaRepository` + `MediaDataTypes` + Home/Detail/Page/Mutation 扩展落在 `MetadataKit`。
- App 侧删除详情快照、预取任务表与旧写穿装饰器；首页 / 详情 / 库页 / 搜索 / 合集封面 / 进度写回统一经仓储。
- 图片层新增 `RemoteImageState`、`ImageArrivalScheduler`、`ImageHostFailureBreaker` 并接入 `RemoteImage` / `ImagePipeline`。
- 超出当前范围、留待后续：按 host 的在途请求上限（首轮风暴）、详情快照磁盘 TTL 策略的产品化配置。

## 实施验收

1. 同一详情预取与页面加载只产生一轮网络请求。
2. 库页和搜索页有真实磁盘读写，冷启动可恢复；排序、筛选、搜索词与分页窗口分键。
3. 播放结束与已看标记都经同一写入口更新内存与 SQLite。
4. 图片换图保留旧帧，旧代次回调不落地，成功到达按帧预算批量应用。
5. MetadataKit / AppDesignKit 包测试与 macOS 构建通过。

## 发版前一致性补强（2026-11-05）

- `MetadataCoordinator` 在服务器实例切换时递增会话代次。等待建库结束后先校验代次，再复用当前仓储；创建与安装之间没有悬挂点。切服、登出、A→B→A 和同租户重新登录都不能让旧创建调用复活。
- `finishReporting()` 在排队前捕获原服务器、仓储和进度快照。本地末次写回串行执行，返回的收尾任务同时等待本地写回与远端 Stopped；重复收尾等待同一份本地写回。退休仓储只允许这条明确归属原租户的末次写回，旧网络响应仍不能回填磁盘。
- 末次进度在一个 SQLite 写事务内读取并更新原条目，保留已看标记及更完整的元数据；缺少条目时用播放会话快照补齐。
- `rail`、`homeSnapshotParts`、`page` 和 `pages(matching:)` 在同一读事务内批量合并 `item` 表的 `playState`，再交给仓储恢复内存。每批最多 900 个 ID，不逐条查询；列表排序、其他元数据、分页窗口与 `fetchedAt` 保留。缺少规范条目或进度时沿用列表快照；季与集原本直接读 `item` 表。这组投影读取本身不需要数据库迁移；后续进度保护的 v3/v4 迁移见下文。

参考的是本机 `rex_analysis` 中针对 Rex 1.0.2 的二进制分析：`out/blueprint/16_media_data_pipeline.md`、`out/blueprint/10_data_catalog.md` §6.5 / §9.4，以及 `REX_PLAYBACK_LOGIC.md` §3.10 / §3.11。采用 SQLite 事实源与投影分离、会话代次和本地/远端进度任务分离的原则；分析中标为推断的具体合并策略不视为 Rex 源码事实。本项目采用上述可测试的合并规则。

回归覆盖：App 的受控建库、切服、登出、重复收尾和同租户新会话时序；MetadataKit 的退休写回闸门、缺失条目、磁盘恢复、跨租户同 ID、已看切换与 1100 条投影批量读取。


## 网络回包与本地末次进度（2026-11-06）

Stopped 超时只表示收尾等待结束，不证明服务器收到了位置。首页刷新既可能覆盖内存，也可能把 `item` 表重新写旧。因此所有网络条目写入统一经 `saveIncomingItems`，SQLite 在一个事务中合并本地进度、写条目及 rail，并把同一份列表交还仓储；分页快照读取继续与条目事实源合并。

增量迁移 `addLocalProgressV3` 增加按租户和条目分键的 `local_progress`；`makeLocalProgressIndependentV4` 保留并搬移原记录，解除其与可淘汰 item 的外键关系。末次进度与保护记录原子写入；重开数据库后继续生效。只保护进度，服务端的新标题、简介等元数据照常接收。空 resume 响应只补回尚未确认且位置大于零的本地未看条目；普通空列表仍清空。

服务端没有位置版本号，冲突策略明确如下：

- 本地末次位置优先，直到在本地写入之后发出的请求读到相同已看状态和位置（容差小于 1 秒）。
- 自然播完附近的末次位置（距片尾不超过 2 秒）允许服务端已看状态作为确认，包括续播位置清零。
- 确认记录保留请求开始时间的界限，确认前发出的迟到请求不能覆盖本地进度，也不能覆盖之后已接受的新服务端位置。
- 确认后的新请求可更新或倒退位置；新的本地播放末次写回替换旧保护；显式已看/未看成功后以该操作为准建立已确认边界：先发回包仍受限，后发请求正常接管。

长时间上报失败时本地末次进度优先，跨设备服务端位置须满足上述确认条件或显式标记后才能重新接管。这是缺少服务端版本号时采用的冲突规则，不把超时或任务结束视为网络成功。仓储的纯内存降级也按同一规则合并。

回归见 [StoppedProgressRegressionTests](../AppTests/StoppedProgressRegressionTests.swift) 与 [LocalProgressConflictTests](../Packages/MetadataKit/Tests/MetadataKitTests/LocalProgressConflictTests.swift)，覆盖正常/超时对照、重开数据库、迁移、倒退播放、确认前迟到回包、空列表、自然播完和跨租户隔离。


## 显式操作与自动淘汰的边界（2026-11-06）

`markPlayed` / `markUnplayed` / 权威 `applyPlayState` 在首次 await 前保存内存进度与操作时间边界，SQLite 在写状态的同一事务内保存同一边界。操作已经网络确认，因此无需等待相同位置再确认；操作之前发出的回包不能撤销它，之后发出的读取可以继续更新，包括倒退进度或其他设备改动。异步末次写回只应用自己的记录代次，较旧的排队写入不能覆盖时间较新的操作或播放记录。

v4 的进度记录独立于可淘汰元数据。自动维护仍按原来的条目/容量策略删除 item；未确认记录保留完整条目，以便重开库后合并新回包或补回空继续观看列表。已确认且 item 已淘汰的记录压缩为 ID、名称、类型、进度与请求边界，保留迟到请求的保护而释放大段元数据。rail/page 在 item 缺失时从独立进度记录补状态，保留投影的顺序与元数据。

元数据容量是回收目标，不通过丢弃未确认的播放事实强行满足上限。轻量确认边界保留到用户主动清缓存，以免未完成的旧请求在淘汰后恢复旧状态；明确的清缓存操作同时清理独立记录和当前仓储的内存保护，纯内存失效与会话卸载仍保留末次写回语义。新增迁移不改 v1/v2/v3 已登记迁移，不重建或清空现有条目、rail/page 和进度记录。

正式回归见 [ProgressOperationBoundaryTests](../Packages/MetadataKit/Tests/MetadataKitTests/ProgressOperationBoundaryTests.swift)、[ProgressEvictionTests](../Packages/MetadataKit/Tests/MetadataKitTests/ProgressEvictionTests.swift) 与 [MetadataCoordinatorTests](../AppTests/MetadataCoordinatorTests.swift)，覆盖未看方向、权威状态入口、跨租户、自动维护、旧回包与写入换序、v3→v4 迁移、离线投影和主动清缓存。


## 淘汰后的状态回补与失败投影安装（2026-11-06）

末次写回的已看/未看状态按当前规范条目、同租户独立进度记录、播放会话快照的顺序取值，位置仍使用末次快照。独立记录只补 playState：完整元数据继续采用规范条目或会话对象，避免压缩后的保护记录覆盖简介等内容。已看和未看两方向均保持最新操作结果，unplayedCount 沿用最新状态，百分比按新位置/片长计算。

纯内存路径在 items 被 LRU 淘汰后仍从 localProgress 取状态；这份状态在创建新记录之前捕获。分集刷新失败时，详情先合并本地保护，再从 content.seasons/content.episodes 安装条目内存，保证详情、cachedItem 与磁盘看到同一状态。

该修复沿用现有 v4 表和排队写入时间检查。主动清缓存后的新末次写回按仍可用的会话数据处理；跨租户同 ID 不共享状态。正式回归见 [PlaybackStateRecoveryTests](../Packages/MetadataKit/Tests/MetadataKitTests/PlaybackStateRecoveryTests.swift)，在 App 锁定依赖下验证已看/未看两方向及内存/磁盘路径。
