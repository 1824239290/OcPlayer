# 开发者文档

面向想从源码构建、改造或排查 OcPlayer 的人。使用说明见 [README](../README.md)。

## 项目结构

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| App | `App/` | 双端 UI、观察式状态（Observation）、`AppModel` 中枢 + 域模型（Bangumi / MoviePilot / 弹幕） |
| PlaybackKit | `Packages/PlaybackKit/` | 内核抽象层：`PlaybackEngine` 协议、注册与失效回退、契约测试 |
| CoreModel | `Packages/CoreModel/` | 纯数据模型，双端共享，无第三方依赖 |
| AppDesignKit | `Packages/AppDesignKit/` | 设计系统：动效/尺寸 token、骨架屏、卡片原语、横向滚动、液态玻璃、远程图管道（RemoteImage/ImagePipeline）。**只吃纯值、不碰域模型**——新 Feature 直接复用 |
| ErikaKit | `Packages/ErikaKit/` | 播放内核封装：引擎、事件流、画面承载、播放状态 |
| JellyfinKit | `Packages/JellyfinKit/` | Jellyfin / Emby 薄封装：登录探活识别服务器类型、媒体库、PlaybackInfo、进度上报；Emby 走 `/emby` 前缀与老式路由适配。**一台服务器可有多个入口**（局域网 / Tailscale / 反代域名）：`ServerAddress` 是地址模型与分类，`ServerProbe` 走 `/System/Info/Public` 探活并用服务器 `Id` 挡住「换到别人家」，`ServerEndpointDirectory` 按实测延迟择优 + 失败自动换址（设计约束见该文件的类型注释） |
| DanmakuKit | `Packages/DanmakuKit/` | 弹弹play 网关客户端：match/search/comments、JSON 转换、缓存、16MiB 哈希 |
| DanmakuRenderKit | `Packages/DanmakuRenderKit/` | vendored 弹幕渲染层（qyz777/DanmakuKit，MIT，见 `PROVENANCE.md`）：轨道池、cell 复用、异步绘制图层（`DanmakuAsyncLayer`） |
| BangumiKit | `Packages/BangumiKit/` | Bangumi OAuth、收藏/章节/搜索/日历 API、GRDB 本地库 |
| MetadataKit | `Packages/MetadataKit/` | 媒体元数据落盘（GRDB）+ `MediaServer` 写穿装饰器 + 离线读。**只写不读**：装饰器把每个响应落盘、返回值与错误与内层完全一致；离线展示由 `MetadataHydrator` 与 UI 层决定（见该包 `CachedMediaServer` 的类型注释） |
| MoviePilotKit | `Packages/MoviePilotKit/` | MoviePilot 登录换 JWT、401 静默重登、订阅/搜索/下载 API |
| DiagnosticsKit | `Packages/DiagnosticsKit/` | 统一日志：会话文件（一次启动一个）+ 级别阈值 + 脱敏 + 节流 + 诊断包导出；网络公共工具 + 共享 HTTP 执行层（`HTTPClient`/`RetryPolicy`：传输/计时日志/传输错误映射/退避重试，各域客户端共用）。口径与排障见 [`LOGGING.md`](LOGGING.md) |

## 构建与脚本

```bash
Scripts/bootstrap.sh             # 可选：生成本地 Secrets.xcconfig 模板，不会覆盖已有文件
Scripts/fetch-erika.sh           # 解析并拉取最新 Erika，生成 Erika.xcframework（不入库，约 750 MB）
Scripts/build-macos.sh           # 检查最新内核，清理上次产物并构建 macOS Debug
Scripts/build-macos.sh release   # Release 构建
Scripts/package-macos.sh v0.2.1  # 本地打包，产出与 CI 相同的 dist/ 产物
Scripts/package-ios.sh           # iOS 打包；不带参数时版本号从 Config/App.xcconfig 读取
```

- 内核版本唯一事实源是 `Config/Erika.version`，可用环境变量 `ERIKA_VERSION` 临时钉到其它 tag；已有同版本完整产物会复用。
- `SKIP_ERIKA_FETCH=1` 让 `build-macos.sh` / `package-*.sh` 直接使用 Vendor 里现成的内核产物，跳过 fetch（手动铺入自编译内核时必开，否则 fetch 会按钉点版本静默覆盖回 Release 产物）。
- macOS 构建必须用 `-scheme`，架构钉死 arm64。手动跑 `xcodebuild` 时请显式传 `-derivedDataPath`，不要写进全局 DerivedData。
- Debug 配置带 `OCPLAYER_SELFTEST` 编译条件，提供一条自动化验收通道（见 `App/Shared/LaunchOptions.swift`）：`OCPLAYER_START_SECTION=home|bangumi|moviepilot|settings` 启动直落分区；`OCPLAYER_SELFTEST_FILE` + `OCPLAYER_SELFTEST_SECONDS` 可开窗播一段、打印 stats 后自退。Release 不编译这段代码。

## 测试

各 SPM 包全部离线测试，不碰真实网络：

```bash
swift test --package-path Packages/<AppDesignKit|CoreModel|DiagnosticsKit|PlaybackKit|ErikaKit|JellyfinKit|DanmakuKit|DanmakuRenderKit|BangumiKit|MetadataKit|MoviePilotKit>
```

- **BangumiKit、MetadataKit 与 ErikaKit 用 swift-testing，别对这三个包加 `--disable-swift-testing`**——会把它们的 swift-testing 套件静默跳过（ErikaKit 那 30 个用例全在里面，它另有 4 个 XCTest 文件，两套并存）。纯 XCTest 包不需要这个开关，输出末尾「0 tests in 0 suites」只是 swift-testing runner 空跑，XCTest 用例照常执行。
- ErikaKit 里实例化 `ErikaPresenter` 的套件要 Metal 与真内核，无 GPU 的机器上会直接 hang 而不是报错，`--skip` 清单见 `.github/workflows/test.yml`。

CI（`.github/workflows/`）在 push / PR 上跑测试门禁——macOS scheme 与 iOS scheme 的 `OcPlayerTests`（同一份用例源码，两个 target）各跑一遍，加 11 个 SPM 包（10 个循环 + ErikaKit 单独一项，因为后者要按套件 `--skip` 掉依赖 GPU/真内核的用例）；iOS 机型用 `simctl` 动态取，不写死。语义化版本标签触发 Release 工作流。

## Erika 内核

内核取自上游 [AimesSoft/Erika](https://github.com/AimesSoft/Erika) 官方 release `v0.2.1`（钉点唯一事实源是 `Config/Erika.version`）：**资源回收**——关闭 / 切换媒体 / seek 时取消旧的网络读取，销毁播放器时等待后台 worker 退出并释放连接与线程，`stop()` 释放 HTTP 缓存与队列占用（保留从头重播能力）；**预读窗口**修复——预取不再跨越条带边界继续读取，窗口按配置生效；**解码**恢复硬件解码不可用时的软件回退（WMV/WMA、8/10-bit AV1）并修正 P010 插值精度；以及供 iOS 弹幕/字幕同步用的新 C API `erika_presenter_render_tick_with_timing`（**已接入**：`RenderLoop` 每帧把 `CADisplayLink` 的「到显示目标延迟」交给 `ErikaEngine`，走 `render_tick_with_timing`；延迟先按内核的 ±0.25 s 硬约束夹过，超界或非有限则退回无 timing 的 `render_tick`）。v0.2.0 引入的 **持久流预取**（worker 持有开放式 GET（`bytes=锚点-`），源站每个 worker 只 seek 一次、背压就是 TCP 本身，替代旧版每 4 MiB 付一次连接 + TLS + TTFB 的分块链；预取窗口按 worker 生产偏移对绝对边界自我节流，不随播放时长增长；回退预算可调 `http_back_buffer_bytes`（0 = 默认 16 MiB），回退落在已播缓存内不发网络请求）仍是当前播放路径的基础——那批改动先在 fork [1824239290/Erika](https://github.com/1824239290/Erika) 上先行、已随 v0.2.0 全部合入上游，钉点自 v0.2.0 起回到官方（公网慢源 A/B 口径不变：开播 13.2 秒、78.3 秒播放零卡顿）。

## 弹幕

### 渲染路线

弹幕统一走 **App 层 overlay**（`DanmakuRenderKit`）：App 在视频画面上方独立绘制，与内核解码/合成解耦，截图不带弹幕。内核内置弹幕渲染器（Erika DFM+）当前版本因滑窗重排（DFM+ 的轨道重算）会让在屏弹幕跳轨而被禁用，运行时强制 overlay（`PlaybackController.resolveOverlayDanmakuRoute()` 恒 true，设置页开关同步置灰）。注：早期的「弹幕定位导致内核把完整视频读进内存」是另一个问题，已随内核 0.1.9 修掉，与此处的禁用无关。等内核修好跳轨后把该判定改回读用户偏好即可切回。

### 网关与凭据

弹幕匹配走弹弹play 协议，经自建网关（Cloudflare Workers 部署，内置公共实例）转发：网关侧持有弹弹play 官方 `AppSecret` 并生成签名，客户端只持 API Key（`X-API-Key` 头），地址必须为 HTTPS origin；不要在日志或界面输出 Key 等凭据。想自建网关 / 换自己的 Key，在「设置 → 弹幕」里改。

首次匹配以本地文件或认证 Range 请求的前 16 MiB MD5 配合文件名、大小和时长识别；「跳过片头」的弹幕报点推导（观众发「跳伞/空降 xx:xx」报出的落点聚类 + 着陆确认弹幕交叉验证）结果永久缓存，弹幕过期 / 网关不可达时跳过按钮仍可用。

## 存储

自有数据都在 `Application Support/OcPlayer/` 下，**路径唯一事实源是 `DiagnosticsKit/OcPlayerStorage`**（新增落盘一律经它取路径，再登记进 `AppStorageDirectories`）。

| 内容 | 位置 | 清理 |
| --- | --- | --- |
| 媒体元数据缓存 | `Media.sqlite` | 设置 → 维护可清空；每日维护按 3 万条 / 200 MB 淘汰最旧 |
| TMDb 补全数据 | `Media.sqlite` 的 `tmdb_entity` / `tmdb_link` 两张表 | 设置 → TMDb 区块可单独清除；过期实体随每日维护清 |
| Bangumi 本地库 | `Bangumi.sqlite` | 登出清账号态；体积随每日维护上报 |
| 弹幕（正文可弃 / 其余永久） | `Danmaku/` | 白名单淘汰，永久文件见 `DanmakuCache.permanentFileNames` |
| 图片字节缓存 | `ImageCache/` | 设置 → 维护可清空；512 MiB 上限 |
| 外挂字幕 / 截图 | `Subtitles/` / `~/Pictures/OcPlayer` | 条数与字节双上限 |

> 维护清单没登记的目录**等于不存在**（不会被清理、体积也不可见）——`Bangumi.sqlite` 就这么漏了几个月，所以「取路径 + 登记」是两件必须一起做的事。

## TMDb 元数据补全

用户自填 API Key（设置 → TMDb 元数据补全，**留空即禁用**）。v3 API Key 与 v4 Read Access Token 都支持。代码在 `Packages/MetadataKit/TMDb/`。

### 三条必须知道的约束

1. **集与季的 `tmdbID` 不是剧集 id。** 实测本机 Jellyfin 12.1.0（`Fields=ProviderIds` 才返回）：
   ```
   剧   ProviderIds["Tmdb"] = 153217      ← 剧集 id，可用于 /tv/{id}
   季   只有 Tvdb，没有 Tmdb              ← 无 id 可用
   集   ProviderIds["Tmdb"] = 3384539     ← 单集 id，拿它查 /tv/{id} 会拉到别的剧或 404
   ```
   所以季/集一律从**父剧**推导 `tv/{剧id}/season/{季号}`。判断收在 `TMDbEntityKey` 的唯一入口。
2. **TMDb 不做语言回退。** `language=zh-CN` 时没翻译的字段返回**空串**（不是 nil），判定必须用「非空」。且只补缺、不整包替换。
3. **缓存期不得超过 6 个月**（TMDb 条款）。`TMDbPreferences.maxCacheDays = 180`，不要调大。

### 分层

| 类型 | 职责 |
| --- | --- |
| `TMDbClient` | 纯网络：详情 / 一季 / 搜索，限流 + 重试 |
| `TMDbMatcher` | 匹配与打分（ProviderIds → 搜索），**不碰网络**（搜索入口是注入的闭包） |
| `MetadataStore+TMDb` | 落库：实体全局共享、对应按租户隔离 |
| `TMDbEnricher` | 串起来：匹配 → 拉取 → 落库 → 只读叠加 |
| `TMDbOverlay` / `DisplayMetadata` | 展示策略（文本与图片**默认都 TMDb 优先**，各自可关），纯函数 |
| `TMDbCoordinator`（App 层） | 设置读写、生命周期、与 `AppModel` 的接线 |

### 季与分集的展示面

**分集/季没有自己的详情页**（首页续播走 `openSeriesDetail(for:)` 解析到所属剧集；搜索只请求 `kinds: [.movie, .series]`），但它们的 TMDb 数据**在剧集页上有展示面**：

| 展示面 | 数据来源 |
| --- | --- |
| 分集卡片的标题 | 该季每一集的 TMDb 标题（占位名「第 N 集」会被顶掉） |
| 分集卡片的剧照 | TMDb 的 `still_path`（默认策略下优先于服务端的图） |
| 分集卡片的悬停提示 | 该集的 TMDb 简介 |
| 页面简介 | 选中某季时优先显示**该季简介**，取不到回落剧集简介 |

**图片策略默认「TMDb 优先」**（`TMDbPreferences.replaceExistingImages` 默认 true，用户口径：填了 key 就是想要完整补全）。海报 / 背景 / 分集剧照三处都走 `TMDbImagePolicy`；用户可在设置页关掉。**改这个默认值时务必同时改 `TMDbImagePolicy.init` 的默认**——同一个概念两个默认值会让「生产优先、测试只补缺」，很难查。

所以 `AppModel.refreshTMDb` 只处理电影与剧集（详情页只会收到这两种），而**季数据由 `loadSeasonOverlay()` 单独取**——入口是「父剧的 link + 季号」（季没有自己的对应关系）。

**两个踩过的坑**（都别再踩）：
1. **季数据不能在 `.task(id: selectedSeasonID)` 里取**：那个 task 在页面初现时就会跑一次，而那一刻 `seasons` 还是空的（实测诊断：与 `/Seasons` 请求同一秒，`selectedSeason` 为 nil），之后 id 变化并没有再触发它。现在由 `load()` 末尾**确定性地**触发（那时 seasons 与 link 都已就位），视图 task 只负责「用户切季」。
2. **占位集名判定不要用 `\d`**：实测 ICU 的 `\d` 会匹配中文数字（「九」被判为 true），于是「第九集」这种真实标题会被误判成占位名。用 `[0-9]`；且中日文形态只锚**结尾**（服务端还有「剧名 - S01E00 - 第 0 集」这种文件名派生形态）。

### 批量补全与手动匹配（Phase 3）

- **批量补全**：`TMDbEnricher.enrichAll(items:tenant:onProgress:)`。库由 App 层枚举（`AppModel.tmdbBatchCandidates()`）后传入——协调器刻意只依赖 `MetadataKit`，这样它能脱离服务端单测。剧集连季一起拉；进度按**条**汇报（不是按请求，一次库级补全有几百个请求）。
- **可续性靠数据库本身**：没有断点文件，`performRefresh` 第一步就是「已有对应且未过期 → 跳过」。
- **手动匹配**：`searchCandidates` / `bindManually` / `unbind`，UI 在 `TMDbMatchSheet`（入口是详情页头部的循环箭头）。手动绑定写 `source: .manual`，`isAuthoritative` 为真，**不会被自动匹配覆盖**。
- ⚠️ **`/Items` 列表接口默认不返回 `ProviderIds`**（`/Items/{id}` 才默认返回）。库级补全全靠它拿 `tmdbID`，所以两个后端的 `itemsPage` 都显式带了 `fields`。改这里之前先想清楚：去掉它 = 批量补全退化成纯标题搜索。

### 两条已知取舍（改之前先看这里）

1. **分集剧照两段式**：首次渲染服务端图 → TMDb 到位后替换。要消掉得让季数据先于分集卡片就绪，代价是选集整条晚出现。
2. **脏 `ProviderIds`（TMDb 上 404）**：每次打开详情页白打一次请求，且因权威对应不会被顶掉而**永不退回搜索**。实测本机库全量 41 个带 Tmdb id 的条目全部有效（0 个 404），故未加退避。修法见 `TMDbEnricher.performFetch` 的 catch 注释。

**展示路径不发网络**：`overlay(for:)` 只读库，`refresh(item:)` 才发请求。详情页先渲染已有 overlay，再在后台补——合成一个方法就没法离线复用、也没法让调用方控制时机。

## 后续方向

M1 媒体库、M2 播放体验、M3 弹幕完整链路、M5 Bangumi 联动与 MoviePilot 找片均已接入；M4 打磨进行中——09-14 全项目 review 的 P1/P2/P3 已全部处置，剩余打磨项（凭据入 Keychain、转码降级、Trickplay 等）排在后续版本。**媒体元数据 TMDb 补全**：Phase 1（SQLite 缓存）、Phase 2（点播式补全：客户端 / 匹配器 / 落库 / 叠加层 / 设置页）与 Phase 3（库级批量补全 + 人工匹配面板）均已落地（v0.2.1）。历史变更见 [CHANGELOG](../CHANGELOG.md)。
