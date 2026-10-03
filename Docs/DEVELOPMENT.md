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
| JellyfinKit | `Packages/JellyfinKit/` | Jellyfin / Emby 薄封装：登录探活识别服务器类型、媒体库、PlaybackInfo、进度上报；Emby 走 `/emby` 前缀与老式路由适配 |
| DanmakuKit | `Packages/DanmakuKit/` | 弹弹play 网关客户端：match/search/comments、JSON 转换、缓存、16MiB 哈希 |
| DanmakuRenderKit | `Packages/DanmakuRenderKit/` | vendored 弹幕渲染层（qyz777/DanmakuKit，MIT，见 `PROVENANCE.md`）：轨道池、cell 复用、异步绘制图层（`DanmakuAsyncLayer`） |
| BangumiKit | `Packages/BangumiKit/` | Bangumi OAuth、收藏/章节/搜索/日历 API、GRDB 本地库 |
| MoviePilotKit | `Packages/MoviePilotKit/` | MoviePilot 登录换 JWT、401 静默重登、订阅/搜索/下载 API |
| DiagnosticsKit | `Packages/DiagnosticsKit/` | 统一日志：会话文件（一次启动一个）+ 级别阈值 + 脱敏 + 节流 + 诊断包导出；网络公共工具 + 共享 HTTP 执行层（`HTTPClient`/`RetryPolicy`：传输/计时日志/传输错误映射/退避重试，各域客户端共用）。口径与排障见 [`LOGGING.md`](LOGGING.md) |

## 构建与脚本

```bash
Scripts/bootstrap.sh             # 可选：生成本地 Secrets.xcconfig 模板，不会覆盖已有文件
Scripts/fetch-erika.sh           # 解析并拉取最新 Erika，生成 Erika.xcframework（不入库，约 750 MB）
Scripts/build-macos.sh           # 检查最新内核，清理上次产物并构建 macOS Debug
Scripts/build-macos.sh release   # Release 构建
Scripts/package-macos.sh v0.2.0  # 本地打包，产出与 CI 相同的 dist/ 产物
Scripts/package-ios.sh           # iOS 打包；不带参数时版本号从 Config/App.xcconfig 读取
```

- 内核版本唯一事实源是 `Config/Erika.version`，可用环境变量 `ERIKA_VERSION` 临时钉到其它 tag；已有同版本完整产物会复用。
- `SKIP_ERIKA_FETCH=1` 让 `build-macos.sh` / `package-*.sh` 直接使用 Vendor 里现成的内核产物，跳过 fetch（手动铺入自编译内核时必开，否则 fetch 会按钉点版本静默覆盖回 Release 产物）。
- macOS 构建必须用 `-scheme`，架构钉死 arm64。手动跑 `xcodebuild` 时请显式传 `-derivedDataPath`，不要写进全局 DerivedData。
- Debug 配置带 `OCPLAYER_SELFTEST` 编译条件，提供一条自动化验收通道（见 `App/Shared/LaunchOptions.swift`）：`OCPLAYER_START_SECTION=home|bangumi|moviepilot|settings` 启动直落分区；`OCPLAYER_SELFTEST_FILE` + `OCPLAYER_SELFTEST_SECONDS` 可开窗播一段、打印 stats 后自退。Release 不编译这段代码。

## 测试

各 SPM 包全部离线测试，不碰真实网络：

```bash
swift test --package-path Packages/<AppDesignKit|CoreModel|DiagnosticsKit|PlaybackKit|ErikaKit|JellyfinKit|DanmakuKit|DanmakuRenderKit|BangumiKit|MoviePilotKit>
```

- **BangumiKit 与 ErikaKit 用 swift-testing，别对这两个包加 `--disable-swift-testing`**——会把它们的 swift-testing 套件静默跳过（ErikaKit 那 30 个用例全在里面，它另有 4 个 XCTest 文件，两套并存）。纯 XCTest 包不需要这个开关，输出末尾「0 tests in 0 suites」只是 swift-testing runner 空跑，XCTest 用例照常执行。
- ErikaKit 里实例化 `ErikaPresenter` 的套件要 Metal 与真内核，无 GPU 的机器上会直接 hang 而不是报错，`--skip` 清单见 `.github/workflows/test.yml`。

CI（`.github/workflows/`）在 push / PR 上跑测试门禁——macOS scheme 与 iOS scheme 的 `OcPlayerTests`（同一份用例源码，两个 target）各跑一遍，加 10 个 SPM 包（9 个循环 + ErikaKit 单独一项，因为后者要按套件 `--skip` 掉依赖 GPU/真内核的用例）；iOS 机型用 `simctl` 动态取，不写死。语义化版本标签触发 Release 工作流。

## Erika 内核

内核取自上游 [AimesSoft/Erika](https://github.com/AimesSoft/Erika) 官方 release `v0.2.0`：libplacebo 风格杜比视界 RPU 映射 + **持久流预取**（worker 持有开放式 GET（`bytes=锚点-`），源站每个 worker 只 seek 一次、背压就是 TCP 本身，替代旧版每 4 MiB 付一次连接 + TLS + TTFB 的分块链；预取窗口按 worker 生产偏移对绝对边界自我节流，不随播放时长增长；回退预算可调 `http_back_buffer_bytes`（0 = 默认 16 MiB），回退落在已播缓存内不发网络请求）。这些改动此前先落在 fork [1824239290/Erika](https://github.com/1824239290/Erika) 上先行，已随 v0.2.0 全部合入上游，钉点已切回官方（公网慢源 A/B 口径不变：开播 13.2 秒、78.3 秒播放零卡顿）。

## 弹幕

### 渲染路线

弹幕统一走 **App 层 overlay**（`DanmakuRenderKit`）：App 在视频画面上方独立绘制，与内核解码/合成解耦，截图不带弹幕。内核内置弹幕渲染器（Erika DFM+）当前版本因滑窗重排（DFM+ 的轨道重算）会让在屏弹幕跳轨而被禁用，运行时强制 overlay（`PlaybackController.resolveOverlayDanmakuRoute()` 恒 true，设置页开关同步置灰）。注：早期的「弹幕定位导致内核把完整视频读进内存」是另一个问题，已随内核 0.1.9 修掉，与此处的禁用无关。等内核修好跳轨后把该判定改回读用户偏好即可切回。

### 网关与凭据

弹幕匹配走弹弹play 协议，经自建网关（Cloudflare Workers 部署，内置公共实例）转发：网关侧持有弹弹play 官方 `AppSecret` 并生成签名，客户端只持 API Key（`X-API-Key` 头），地址必须为 HTTPS origin；不要在日志或界面输出 Key 等凭据。想自建网关 / 换自己的 Key，在「设置 → 弹幕」里改。

首次匹配以本地文件或认证 Range 请求的前 16 MiB MD5 配合文件名、大小和时长识别；「跳过片头」的弹幕报点推导（观众发「跳伞/空降 xx:xx」报出的落点聚类 + 着陆确认弹幕交叉验证）结果永久缓存，弹幕过期 / 网关不可达时跳过按钮仍可用。

## 后续方向

M1 媒体库、M2 播放体验、M3 弹幕完整链路、M5 Bangumi 联动与 MoviePilot 找片均已接入；M4 打磨进行中——09-14 全项目 review 的 P1/P2/P3 已全部处置，剩余打磨项（凭据入 Keychain、转码降级、Trickplay 等）排在后续版本。历史变更见 [CHANGELOG](../CHANGELOG.md)。
