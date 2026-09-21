# OcPlayer · 橘猫播放器

自用的 Jellyfin / Emby 播放器，SwiftUI 真原生双端（macOS 为主 + iOS/iPadOS），系统要求 macOS 26 / iOS 26 起。播放内核基于 Rust 写的 [Erika](https://github.com/AimesSoft/Erika)（C ABI 接入，内置 FFmpeg 解码 + libass 字幕渲染），弹幕接入弹弹play 并统一由 App 层 overlay 渲染，另集成 Bangumi（番剧追踪）与 MoviePilot（找片 / 下载 / 订阅）。

## 功能

- **媒体库**：Jellyfin / Emby 服务器自动识别（登录探活判定类型），Jellyfin 账号密码 + Quick Connect、Emby 账号密码；多服务器记忆与一键切换（登出不再遗忘档案，token 失效自动尝试其它已存服务器；可指定「启动时默认服务器」，打开 App 优先连接选定档案）；媒体库分页浏览、电影/剧集详情、季/集选择（剧集行可切正序 / 倒序，偏好跨启动保留）；详情页内嵌「媒体信息」——按当前选中集（电影为自身）展示文件参数：分辨率与宽高比、编码与 profile、码率、帧率、动态范围（杜比视界 / HDR10 / HLG / SDR）、色彩、位深，逐轨音轨与字幕（语言 / 编码 / 声道 / 采样率 / 内封外挂），以及容器、文件大小、时长；多版本条目按开播同款规则选源并提示版本数；每个库页面右上角排序与观看状态筛选（名称 / 最近添加 / 年份 / 评分 / 时长 / 随机 + 升降序 + 全部/没看过/看过，服务端排序过滤、按库类型给候选、每库记忆偏好）；首页继续观看、接下来看、最近添加；海报氛围背景（设置可关）：详情页海报/标题浮在模糊 backdrop 上、首页库内随机轮播，关闭恢复清晰横幅
- **播放**：pause / seek / 倍速 / 音轨与字幕切换 / 外挂字幕 / 续播 / 进度上报 / 自动连播下一集 / macOS 键盘快捷键；章节列表跳转；片头片尾识别 + 悬浮「跳过」按钮（识别源四路互补：Jellyfin MediaSegments 智能识别 > AniSkip 社区标注 > 弹幕报点推导 > 章节启发式；跳过片头/片尾可在设置里单独关闭，末 90 秒保底跳过片尾的保留时长可选不保留～30 秒、默认 10 秒）；网络预读缓冲与回退缓冲可调（预读 2 / 8 / 16 / 32 MiB、回退默认 16 / 32 / 64 / 128 MiB；内核用持久流预取——开放式 GET 长连接、背压即 TCP，数值越大越抗带宽抖动，弱网下无需刻意调小；回退落在已播缓存内不发网络请求，高码率片源建议调大回退档）；macOS 走 VideoToolbox 硬解 + IOSurface 零拷贝，HDR 片按窗口所在屏的 EDR 能力输出（XDR 屏真出 EDR）；HUD 为原生 Liquid Glass——右下角功能按钮融合成玻璃胶囊，点开的按钮液态形变为「行 + 子菜单」式玻璃面板（Infuse 风格）
- **弹幕**：已有剧集映射直接复用；首次匹配以本地文件或认证 Range 请求的前 16 MiB MD5 配合文件名、大小和时长识别；手动搜索选集、匹配缓存、时间偏移、不透明度、显示区域与类型过滤；网关瞬断自动重试（3 次，含编排层故障短路）；「跳过片头」弹幕报点推导——观众发「跳伞/空降 xx:xx」报出的落点聚类后即为片头结束点，与着陆确认弹幕交叉验证，提示永久缓存（弹幕过期/网关不可达时跳过按钮仍可用）
- **Bangumi（番剧追踪）**：OAuth 登录、收藏与在看进度、每日放送日历、条目详情与章节标记、播放结束自动标记本集看过；不用可在设置里停用（入口与后台同步全部隐藏，登录状态保留）
- **MoviePilot（找片 + 下载 + 订阅）**：按标题搜站点资源、下载任务列表、订阅管理；不用可在设置里停用（入口全部隐藏，服务器配置保留）
- **本地播放**：首页工具栏「打开」菜单 / macOS 文件菜单（⌘O）打开本地文件或直连链接，支持 iOS 文件选择器权限生命周期管理

## 下载

预编译版本见 [Releases](../../releases)：

- macOS（arm64）：`OcPlayer-<版本>-macOS-arm64.dmg`（或 `.zip`），附 `SHA256SUMS.txt`
- iOS：`OcPlayer-<版本>-ios-unsigned.ipa`（iPhone + iPad，未签名，用 AltStore / Sideloadly / TrollStore 等重签安装），附 `SHA256SUMS-ios.txt`

> macOS 产物为 ad-hoc 签名、iOS 产物未签名，均未经 Apple 公证，首次打开可能出现 Gatekeeper 提示。

## 构建

```bash
Scripts/bootstrap.sh             # 可选：生成本地 Secrets.xcconfig 模板，不会覆盖已有文件
Scripts/fetch-erika.sh           # 解析并拉取最新 Erika，生成 Erika.xcframework（不入库，约 753 MB）
Scripts/build-macos.sh           # 检查最新内核，清理上次产物并构建 macOS Debug
Scripts/build-macos.sh release   # Release 构建
Scripts/package-macos.sh v0.1.8  # 本地打包，产出与 CI 相同的 dist/ 产物
```

各 SPM 包测试（全部离线，不碰真实网络）：`swift test --package-path Packages/<AppDesignKit|CoreModel|DiagnosticsKit|PlaybackKit|ErikaKit|JellyfinKit|DanmakuKit|DanmakuRenderKit|BangumiKit|MoviePilotKit>`。**BangumiKit 与 ErikaKit 用 swift-testing，别对这两个包加 `--disable-swift-testing`**——会把它们的 swift-testing 套件静默跳过（ErikaKit 那 30 个用例全在里面，它另有 4 个 XCTest 文件，两套并存）。纯 XCTest 包不需要这个开关，输出末尾那行「0 tests in 0 suites」只是 swift-testing runner 空跑，XCTest 用例照常执行。ErikaKit 里实例化 `ErikaPresenter` 的套件要 Metal 与真内核，无 GPU 的机器上会直接 hang 而不是报错，`--skip` 清单见 `.github/workflows/test.yml`。

> 内核当前取自 fork [1824239290/Erika](https://github.com/1824239290/Erika) 的预发布 `v0.1.9+dolby.streaming.dev`（上游 v0.1.9 + libplacebo 风格杜比视界 RPU 映射 + **持久流预取**：worker 持有开放式 GET（`bytes=锚点-`），源站每个 worker 只 seek 一次、背压就是 TCP 本身，替代旧版每 4 MiB 付一次连接 + TLS + TTFB 的分块链；回退预算可调 `http_back_buffer_bytes`（0 = 默认 16 MiB），回退落在已播缓存内不发网络请求；含杜比管线与 #137 request-cap/resume/rewind-cache 工作。公网慢源 A/B（三重跳转、单请求延迟 1–5 秒且约一半请求中途挂死）：开播 13.2 秒成功（旧版 60 秒看门狗超时、整场播不起来）、78.3 秒播放零卡顿（`buffered_ms: 0`、`stall_count: 0`）。该 release 附全平台资产，macOS / iOS 用同一内核）。CI 与本地脚本默认都指向 fork；上游合并后用 `ERIKA_VERSION=latest`（可省）+ `ERIKA_REPO` 不设即可切回官方。`SKIP_ERIKA_FETCH=1` 可让 `build-macos.sh` / `package-macos.sh` / `package-ios.sh` 直接使用 Vendor 里现成的内核产物，跳过 fetch（手动铺入自编译内核时必开，否则 fetch 会按钉点版本静默覆盖回 Release 产物）。

> `fetch-erika.sh` 等脚本默认解析 GitHub 最新正式版，已有同版本完整产物会复用；可重复构建时将 `ERIKA_VERSION` 钉到具体 tag。macOS 构建必须用 `-scheme`，架构钉死 arm64。CI（`.github/workflows/`）在 push/PR 上跑测试门禁——macOS scheme 的 `OcPlayerTests` 加 8 个 SPM 包（AppDesignKit 未纳入，ErikaKit 只跑不依赖 GPU 的套件）；语义化版本标签触发 Release 工作流。

## 使用建议

- 支持 Jellyfin（10.x）与 Emby（4.x），登录时显式选择 HTTP/HTTPS；Emby 没有 Quick Connect，只显示账号密码表单
- 弹幕开箱即用：内置公共 OcPlay 网关（Cloudflare Workers 部署，持有弹弹play AppSecret）签发的 API Key；如需自建网关 / 自有 Key，在 设置 → 弹幕 中修改
- 内核弹幕渲染当前因内存问题被禁用，运行时固定走 App 层 overlay 渲染，详见下文「弹幕渲染路线」
- 遇到问题先「设置 → 维护 → 导出诊断包…」：一个 `.txt` 装下版本/设备/全部日志/内核 trace，
  报障直接附件；要更细的记录就在同一处打开「详细日志」（含内核 trace，下一次播放生效）。
  字段口径与排障流程见 [`Docs/LOGGING.md`](Docs/LOGGING.md) / [`Docs/TROUBLESHOOTING.md`](Docs/TROUBLESHOOTING.md)

## 项目结构

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| App | `App/` | 双端 UI、观察式状态（Observation）、`AppModel` 中枢 + 域模型（Bangumi / MoviePilot / 弹幕） |
| PlaybackKit | `Packages/PlaybackKit/` | 内核抽象层：`PlaybackEngine` 协议、注册与失效回退、契约测试 |
| CoreModel | `Packages/CoreModel/` | 纯数据模型，双端共享，无第三方依赖 |
| AppDesignKit | `Packages/AppDesignKit/` | 设计系统：动效/尺寸 token、骨架屏、卡片原语、横向滚动、液态玻璃、远程图管道（RemoteImage/ImagePipeline）。**只吃纯值、不碰域模型**——新 Feature 直接复用 |
| ErikaKit | `Packages/ErikaKit/` | 播放内核封装：引擎、事件流、画面承载、播放状态 |
| JellyfinKit | `Packages/JellyfinKit/` | Jellyfin / Emby 薄封装：登录探活识别服务器类型、媒体库、PlaybackInfo、进度上报；Emby 走 `/emby` 前缀与老式路由适配 |
| DanmakuKit | `Packages/DanmakuKit/` | 弹弹play 网关客户端：match/search/comments、JSON 转换、缓存、16MiB 哈希 |
| DanmakuRenderKit | `Packages/DanmakuRenderKit/` | vendored 弹幕渲染层（qyz777/DanmakuKit，MIT，见 `PROVENANCE.md`）：轨道池、cell 复用、异步绘制图层（`DanmakuAsyncLayer`） |
| BangumiKit | `Packages/BangumiKit/` | Bangumi OAuth、收藏/章节/搜索/日历 API、GRDB 本地库 |
| MoviePilotKit | `Packages/MoviePilotKit/` | MoviePilot 登录换 JWT、401 静默重登、订阅/搜索/下载 API |
| DiagnosticsKit | `Packages/DiagnosticsKit/` | 统一日志：会话文件（一次启动一个）+ 级别阈值 + 脱敏 + 节流 + 诊断包导出；网络公共工具 + 共享 HTTP 执行层（`HTTPClient`/`RetryPolicy`：传输/计时日志/传输错误映射/退避重试，各域客户端共用）。口径与排障见 [`Docs/LOGGING.md`](Docs/LOGGING.md) |

## 弹幕渲染路线

弹幕统一走 **App 层 overlay**（`DanmakuRenderKit`）：App 在视频画面上方独立绘制，与内核解码/合成解耦，截图不带弹幕。内核内置弹幕渲染器（Erika DFM+）当前版本因弹幕定位导致内核将完整视频加载进内存而被禁用，运行时强制 overlay；等内核修复后恢复「用内核渲染弹幕」开关即可切回。

网关侧持有弹弹play 官方 `AppSecret` 并生成签名，客户端只持 API Key（`X-API-Key` 头），地址必须为 HTTPS origin；不要在日志或界面输出 Key 等凭据。

## 许可证

本项目**源代码**以 [GNU General Public License v3](LICENSE)（GPL-3.0）许可发布。

- 发布产物聚合第三方许可证文本到 `Contents/Resources/THIRD_PARTY_LICENSES/`，缺少任一文本会终止打包
- FFmpeg、libass、SoundTouch 等 LGPL 组件需满足 notices、源码与可重链要求

## 感谢

本项目依赖以下开源项目与服务（完整清单见应用 设置 → 关于 → 开源许可证）：

- [Erika](https://github.com/AimesSoft/Erika)（FFmpeg / libass；当前使用 fork [1824239290/Erika](https://github.com/1824239290/Erika) 的内核，杜比视界映射与持久流预取在 fork 上先行）
- [DanmakuKit](https://github.com/qyz777/DanmakuKit)
- [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) / [Jellyfin](https://jellyfin.org/) / [Emby](https://emby.media/)
- [GRDB.swift](https://github.com/groue/GRDB.swift) / [Get](https://github.com/kean/Get)
- [弹弹play](https://www.dandanplay.com/)（弹幕数据，经 OcPlay 网关接入）
- [AniSkip](https://api.aniskip.com/) / [AniList](https://anilist.co/)（社区片头标注与 ID 映射）
- [Bangumi](https://bgm.tv/) / [MoviePilot](https://github.com/jxxghp/MoviePilot)

## 文档

- 更新日志：`CHANGELOG.md`
- 日志与诊断（级别规范 / 字段口径 / 内核 trace / 不记什么）：[`Docs/LOGGING.md`](Docs/LOGGING.md)
- 排障手册（症状 → 看哪几行 → 常用命令）：[`Docs/TROUBLESHOOTING.md`](Docs/TROUBLESHOOTING.md)

## 路线

M1 媒体库、M2 播放体验、M3 弹幕完整链路、M5 Bangumi 联动与 MoviePilot 找片均已接入；Emby 适配（登录探活自动识别、老式路由全链路）已真机验证随 0.1.5 发出。0.1.6 完成前端组件化重构（设计系统下沉 `AppDesignKit`、卡片/分页/空态收敛到共享原语）、播放器 HUD 原生液态玻璃化、整窗氛围背景与 macOS 26 全屏顶栏衔接层、macOS 内核升到 `v0.1.9+dolby.1`（HDR 片真出 EDR）。0.1.7 完成日志系统重整（默认档精简、诊断包一键导出、会话化文件）与弱网播放修复（内核 4 MiB 分块预读 + 回退缓存，播到一半就停问题根治）。0.1.8 完成 Emby 全链路加固（解码契约与 Jellyfin 分家、片头片尾从章节 marker 翻译、4.10「接下来看」兜底、上报会话与 401 兜底）、内核换装持久流预取（公网慢源上「播不动 / 卡死」解决）、详情页「媒体信息」区块与跳过片头/片尾设置开关，并修掉播放器 HUD 的 issue #4 / #5。M4 打磨进行中：09-14 全项目 review 的 P1/P2/P3 已全部处置；剩余打磨项（凭据入 Keychain、转码降级、Trickplay 等）排在后续版本。
