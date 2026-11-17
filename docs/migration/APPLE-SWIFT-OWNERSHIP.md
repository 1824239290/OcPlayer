# Apple Swift / Rust Core 职责清单

基线：Apple `888ccdd8`、Core `7e3968e2`。这是合仓的领域级源码审计，不是删除旧业务实现的批准，也不是全部平台运行时验收的替代品。

## 迁移不变量

- 冻结的结构迁移快照中，Apple 原生平台、业务和测试 Swift 文件共 706 个保持原 Git blob 和文件模式。
- 原 Apple 公共绑定与 Core 公共绑定共 23 个文件内容一致，包含 README；其中 Swift/fixture 文件模式有差异，统一沿用 Core 的模式。
- 唯一公共绑定在 `core/bindings/apple/OcPlayerCore`；只修改六个 Package.swift 与 Xcode 包路径，没有改变 SDK 或业务方法。
- `OcpCoreFeature.isEnabled` 仍按环境变量、UserDefaults、Info.plist 决定，未配置时为 false。实际激活还依赖可用的 Core client；关闭、加载失败与注入依赖时按各入口原合同执行。
- 原生库加载失败不等于所有操作都可重放；已经提交的写入或请求必须保留单一执行者。

`scripts/verify-monorepo.py` 始终核对冻结的结构迁移快照；`--migration` 还核对当前候选。用户在完整 CI 失败后另行批准基线问题修复：当前候选仅解析器及其回归测试两份 Swift 文件改变，前后精确 blob 和理由见 [后续修复审计](follow-up-repairs.json)，另外 704 份与原模式不变。额外或未审计的修改仍被拒绝，公共 SDK 也未改变。日后业务修改保留独立提交和测试，不需要改写历史源清单，也不受旧 Swift 文件内容永久冻结的限制。

## 领域归属

路径相对 `apps/apple`；Rust command 以生产 routing 为事实源。原 `core/docs/public-command-inventory.json` 记录 370 条，生产已有 372 条；后续修复补齐两个缓存命令，并保留严格的全清单 C ABI 合同。旧审计报告中的 370 是历史结果，不改写为新的通过记录。

| 领域 / Swift 生产入口 | Rust command / 门面 | 实际选路与保留的原生职责 | 验收位置 |
| --- | --- | --- | --- |
| 全局激活：公共 SDK `OcpCoreClient` | C ABI 加载、版本与导出校验 | 开关与 client 成功加载分开判断；Swift 包存在不代表 dylib / 静态分发已接入 | 公共 SDK 边界测试、`AppTests/RustCoreActivationTests.swift` |
| 服务器发现/登录：`JellyfinKit/ServerProbe`、Jellyfin/Emby LoginSession | probe / login、`RustServerLogin`、`RustEndpointPolicy` | `usesCoreTransport` / `usesCorePolicy`；注入 transport 或 in-memory server 保持原生；设备信息与凭据持久化保留原生 | JellyfinKit probe/login/endpoint fixture 与激活测试 |
| 媒体浏览：`JellyfinKit/RustCoreMediaServer` | `server.*`、`browse.*`、`media.*`、`playback.info` | 只替换明确支持的原生服务器实例；保留 profile、凭据和未替换的平台接口；错误不自动重放原生写操作 | JellyfinKit Rust projection / nullable / playback preparation tests |
| 元数据缓存：`MetadataKit/Store/MetadataStore`、`RustMetadataDatabase` | `cache.*`、`metadataDatabase.*` | `usesCoreCache`；初始化失败保留 Swift GRDB；抽查的写入口在 Rust 成功分支 return；Codable 和兼容数据库适配仍原生 | MetadataKit Rust cache/database tests、Core SQL/contract suites |
| 媒体仓储：`MetadataKit/Media/MediaRepository` | `mediaRepository.*` | `usesCoreRepository`；Swift 仍投影 DTO/UI 状态，关闭路径的原仓储策略保留 | MetadataKit repository/parity tests、Core repository contracts |
| TMDb 请求/匹配/补全：`MetadataKit/TMDb` | `tmdb.*`、`tmdb.matcher`、`tmdbEnrichment.*` | `usesCoreTransport` / `usesCoreMatching` / `usesCoreEnrichment`；原生 key/endpoint 供应、注入 session 与无 Core 分支保留 | RustTMDb wire/matcher/enrichment tests、Core TMDb contracts |
| Bangumi 数据/同步/进度：`BangumiDatabaseOperator`、`RustBangumiSync`、`RustBangumiProgress` | `bangumiStore.*`、`bangumiSync.*`、`bangumiProgress.*` | `usesCoreStore`；store 的 `try?` 初始化可能退回 Swift，sync/progress 由同一已加载 store 建立；原生 DB 与 UI 投影保留 | RustBangumi store/sync/progress tests、Core Bangumi contracts |
| Bangumi 请求/账户/OAuth：`BangumiAPIClient`、Rust account/auth facade | `bangumi.request`、`bangumiAccount.*`、`bangumiAuthFlow.*` | 成功建立 client 且 transport 支持时接入；账户持久化、浏览器交互、通知等原生效果保留 | BangumiKit request/account/auth tests、Core auth-flow contracts |
| MoviePilot 请求/账户：`MoviePilotAPIClient`、Rust flow/account facade | `moviepilot.*`、`moviepilotAccount.*`、`moviepilotFlow.*` | `usesCoreTransport`；lazy 加载区分显式 libraryPath 和默认尝试；已开始的 native 登录或 relogin 保留其执行者；Swift 保存凭据与任务生命周期 | MoviePilotKit Rust API/flow/account tests、Core MoviePilot contracts |
| 弹幕请求/缓存/策略：`GatewayClient`、`DanmakuCache`、Rust policy/flow facade | `danmaku.*`、`danmakuCache.*`、`danmakuFlow.*` | `usesCoreTransport` / `usesCoreCache`；默认 FileManager 等平台依赖下尝试 Core，原缓存和注入路径保留；渲染不迁入 Rust 业务核心 | DanmakuKit differential/cache/flow tests、Core danmaku contracts |
| 片头片尾与 ID：IntroLearningStore、AniSkip/AnimeSkip、Rust intro facade | `introProvider.*`、`introIdentity.*`、`introIDs.*`、`introLearning.*`、`danmakuIntro.*` | `usesCoreLearning` / `usesCoreResolution` / `usesCoreIDs` 等实际状态；配置、平台文件接口与学习效果保留 | DanmakuKit intro provider/identity/policy tests、Core intro contracts |
| 播放/轨道/UI 状态：`PlaybackKit/PlayerState`、TrackWorkflow、公共 `OcpPlayback*` | `playback.*`、`playbackFlow.*`、`playbackEvents.*` 和 typed track/preparation SDK | workflow 的 `usesCore` 或实际 client；原生解码事件、主线程 Observable 状态、播放器及 Metal/音频效果保留 | PlaybackKit flow/track tests、AppTests、Core playback contracts |
| 播放偏好：`App/Shared/Features/Player/PlaybackPreferences.swift` | `preferences.resolve` / `preferences.schema` | 开关且 preference client 可用才激活；解析无结果仍有旧规则；UserDefaults 写入和原生样式构造保留 | 29 条偏好规则的既有差分测试与实际 Core 调用断言 |
| 备份/诊断与原生效果：公共 SettingsBackup / DiagnosticExport facade | typed backup SDK、`diag.exportFile` | Rust 决策与 Swift 平台执行分离；凭据、设备身份、更新状态、文件选择和 UI 仍按原合同 | SDK backup/export tests、Core backup/diagnostic contracts |

## 保留而非删除

`CoreModel/MediaItem` 是原生 DTO；`PlaybackKit/PlayerState` 是 UI 状态投影；AppDesignKit、ErikaKit、DanmakuRenderKit 等仍承担 Apple 平台职责。旧 SQL、请求、缓存和默认规则分支也仍有关闭或失败模式的调用方，因此此次不删除整个 Swift 领域包。

## 执行阶段验收

普通 macOS/iOS 构建与 Core-enabled macOS 验证分别运行。普通 AppTests 只为偏好差分提供对应平台的实库，默认不开全局 Core；Core-enabled job 必须提供实际构建的 dylib 和启用环境。缺库跳过激活用例不算成功。用现有 fixture 和差分测试检查实际后端、错误/注入路径及写入、同步、登录重试的执行次数。

业务退出必须另行逐函数确认：生产和 iOS 调用方不再依赖旧分支；关闭/缺库合同已明确；Rust 的完整行为和数据兼容性通过；同一操作不重复执行原生副作用；必要旧规则仅作为独立测试对照保留。
