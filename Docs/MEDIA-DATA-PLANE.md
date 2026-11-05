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
- `rail`、`homeSnapshotParts`、`page` 和 `pages(matching:)` 在同一读事务内批量合并 `item` 表的 `playState`，再交给仓储恢复内存。每批最多 900 个 ID，不逐条查询；列表排序、其他元数据、分页窗口与 `fetchedAt` 保留。缺少规范条目或进度时沿用列表快照；季与集原本直接读 `item` 表。沿用现有 schema，无数据库迁移。

参考的是本机 `rex_analysis` 中针对 Rex 1.0.2 的二进制分析：`out/blueprint/16_media_data_pipeline.md`、`out/blueprint/10_data_catalog.md` §6.5 / §9.4，以及 `REX_PLAYBACK_LOGIC.md` §3.10 / §3.11。采用 SQLite 事实源与投影分离、会话代次和本地/远端进度任务分离的原则；分析中标为推断的具体合并策略不视为 Rex 源码事实。本项目采用上述可测试的合并规则。

回归覆盖：App 的受控建库、切服、登出、重复收尾和同租户新会话时序；MetadataKit 的退休写回闸门、缺失条目、磁盘恢复、跨租户同 ID、已看切换与 1100 条投影批量读取。
