# OcPlayer · 橘猫播放器

自用的 Jellyfin 播放器，SwiftUI 真原生双端（macOS 为主 + iOS/iPadOS）。

播放内核基于 Rust 写的 [Erika](https://github.com/AimesSoft/Erika)（C ABI 接入，内置 FFmpeg 解码 + libass 字幕渲染）；媒体库走 Jellyfin 官方 Swift SDK；弹幕通过 OcPlay 网关接入弹弹play、由 App 层 overlay 渲染（`DanmakuRenderKit`，vendored 自 qyz777/DanmakuKit）；另集成 Bangumi（番剧追踪）与 MoviePilot（找片 / 下载 / 订阅）。

## 特性

- **Jellyfin 完整串联**：登录（账号密码 + Quick Connect / 密码兜底）、连接时显式选择 HTTP/HTTPS、媒体库分页浏览、电影/剧集详情、季/集选择、播放单集
- **首页**：继续观看、接下来看、最近添加
- **播放**：pause / seek / 倍速（长按右箭头临时 2x）/ 音轨与字幕切换 / 外挂字幕 / 续播 / 进度上报（Start → 心跳 → Stopped）/ 自动连播下一集 / macOS 键盘快捷键（空格、方向键、J/L、M 静音、F 全屏）
- **章节与跳过**：章节列表点击跳转；片头 / 片尾自动识别（Jellyfin MediaSegments 优先，章节名启发式兜底）+ 末 90 秒保底，悬浮「跳过」按钮
- **弹幕**：已有剧集映射直接复用；首次匹配以本地文件或认证 Range 请求的前 16 MiB MD5 配合文件名、大小和时长识别；支持手动搜索选集、匹配与正文缓存、开关、时间偏移、不透明度、显示区域和类型过滤
- **Bangumi（番剧追踪）**：OAuth 登录、收藏与在看进度（本地 GRDB 缓存只读）、每日放送日历、条目详情与章节标记、播放结束自动标记本集看过
- **MoviePilot（找片 + 下载 + 订阅）**：密码登录换 JWT、按标题搜站点资源（站点筛选）、下载任务列表、订阅管理（列表 / 添加 / 编辑 / 删除 / 刷新）
- **画质**：macOS 走 VideoToolbox 硬解 + IOSurface 零拷贝；本地文件与直连 HTTP 流均可播放
- **认证**：Jellyfin AccessToken 只作为 HTTP 头（API / 图片管线 / 内核 `open_with_headers`），不拼进 URL，也不进图片请求的 view identity；会话凭据存于 App 本地 UserDefaults，不访问系统钥匙串。Bangumi OAuth 的 `client_id` / `client_secret` 由本地 `Secrets.xcconfig` 注入 Info.plist；MoviePilot 密码仅用于本机静默重登，日志统一脱敏。弹幕网关 API Key 存 UserDefaults，AppSecret 只在网关侧保存
- **本地播放**：打开本地文件 / 直连链接，支持 iOS 文件选择器权限生命周期管理

## 构建

```bash
Scripts/bootstrap.sh             # 可选：生成本地 Secrets.xcconfig 模板，不会覆盖已有文件
Scripts/fetch-erika.sh           # 解析并拉取最新 Erika，生成 Erika.xcframework（不入库，约 753 MB）
Scripts/build-macos.sh           # 检查最新内核，清理上次产物并构建 macOS Debug
Scripts/build-macos.sh release   # 检查最新内核，清理上次产物并构建 macOS Release
swift Scripts/export-app-icon.swift <浅色源图> <深色源图> App/Shared/Assets.xcassets/AppIcon.appiconset
swift test --package-path Packages/DiagnosticsKit      # 统一日志、脱敏、节流、轮转与网络公共工具
swift test --package-path Packages/PlaybackKit         # 内核抽象层：引擎注册/选择/契约测试
swift test --package-path Packages/ErikaKit            # 内核 + 渲染 + HTTP 全套（素材现造，不联网）
swift test --package-path Packages/JellyfinKit         # Jellyfin 登录、浏览、映射与请求参数（全离线 mock）
swift test --package-path Packages/DanmakuKit          # 网关客户端、转换、缓存、哈希与设置（全离线 mock）
swift test --package-path Packages/DanmakuRenderKit    # 弹幕轨道追击 / 队列 / 选择 / 复用池（离屏，不碰 GPU/网络）
swift test --package-path Packages/BangumiKit          # Bangumi 收藏/章节 API 与 GRDB 本地库
swift test --package-path Packages/MoviePilotKit       # MoviePilot 登录/订阅/搜索/下载（全离线 mock）
```

> 脚本固定使用 `.local-build/current`，每次构建前会完整删除该目录，避免累积多个本地产物。macOS 构建必须用 `-scheme`（不能用 `-target`，详见工程内注释）；macOS 架构钉死 arm64。
>
> `fetch-erika.sh`、`build-macos.sh` 和 `package-macos.sh` 默认每次解析 GitHub 最新正式版；已有同版本完整产物会直接复用。需要可重复构建时，将 `ERIKA_VERSION` 设为 `fetch-erika.sh --resolve-version` 输出的具体 tag。

### CI

`.github/workflows/test.yml` 在 main push 与 PR 上跑全量测试门禁：拉取 Erika 后执行 `xcodebuild test`（AppTests 纯逻辑）+ 各 SPM 包 `swift test`（`ErikaKit` 跳过依赖 Metal 的渲染集成测试）。`.github/workflows/release.yml` 在语义化版本标签或手动触发时构建并发布 macOS 产物。

### 弹弹play 网关配置

弹幕通过 **OcPlay 网关**接入（见 `OcPlay-Gateway` 仓库，Cloudflare Workers 部署）：网关持有弹弹play 官方 `AppSecret` 并生成签名，客户端不持有、不读取 `AppSecret`，只持有一把由网关管理员签发的 **API Key**。

App 内置一把**公共 API Key**，开箱即用、无需配置。如需自定义：

- **网关地址**：默认 `https://dandanplay.3841625.xyz`，缺 scheme 会自动补 `https://`；在 设置 → 弹幕 中可改
- **API Key**：在 设置 → 弹幕 中填入自有 Key（网关管理端创建，明文只在创建时返回一次）；清空后回落内置公共 Key

客户端请求网关时以 `X-API-Key` 头发送 Key、以 `OcPlay/<版本>` User-Agent 标识自己；API Key 和网关地址均存 UserDefaults。网关地址必须是 HTTPS origin。不要在日志、错误提示或界面中输出 API Key 或任何弹弹play 凭据。

应用图标位于 `App/Shared/Assets.xcassets/AppIcon.appiconset`。iOS 使用浅色默认图标与深色外观图标；macOS 的传统 AppIcon 不支持外观槽位，因此使用深色版本并提供完整多尺寸资源。

## 项目结构

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| App | `App/` | 双端 UI、观察式状态（Observation）、`AppModel` 会话/浏览/播放中枢 + 三个环境注入的域模型（`BangumiCoordinator` / `MoviePilotCoordinator` / `DanmakuModel`）、播放上报 coordinator 与共享 AppIcon 资源 |
| PlaybackKit | `Packages/PlaybackKit/` | 内核抽象层：`PlaybackEngine` 协议、`PlaybackEngineRegistry`（可用内核选择 + 失效回退）、中立值类型、`PlayerState` 观察粒度隔离，附带契约测试 |
| CoreModel | `Packages/CoreModel/` | 纯数据模型，双端共享，无第三方依赖 |
| ErikaKit | `Packages/ErikaKit/` | 播放内核封装：引擎、事件流、画面承载、播放状态，含无头回归测试 |
| JellyfinKit | `Packages/JellyfinKit/` | Jellyfin 薄封装：登录、媒体库、PlaybackInfo、进度上报，全离线测试 |
| DanmakuKit | `Packages/DanmakuKit/` | 弹弹play 网关客户端：match/search/comments、弹弹play→渲染层 JSON 转换、本地缓存、本地与远程前 16MiB 文件哈希、网关设置，全离线测试 |
| DanmakuRenderKit | `Packages/DanmakuRenderKit/` | vendored 弹幕渲染层（qyz777/DanmakuKit，MIT，见 `PROVENANCE.md`）：轨道池、cell 复用、GIF、SwiftUI 适配 |
| BangumiKit | `Packages/BangumiKit/` | Bangumi：OAuth 凭证生命周期、收藏/章节/搜索/日历 API、GRDB 本地库（`subjects` / `episodes`），全离线测试 |
| MoviePilotKit | `Packages/MoviePilotKit/` | MoviePilot 客户端：密码登录换 JWT、401 静默重登（单飞重放）、订阅/搜索/下载 API 薄封装，全离线测试 |
| DiagnosticsKit | `Packages/DiagnosticsKit/` | 统一 JSONL / OSLog 日志、敏感字段脱敏、节流、导出与轮转；网络公共工具（`NetworkLog` / `NetworkErrorClassifier` / `Duration.timeInterval`） |
| Scripts | `Scripts/` | 内核拉取、本地构建/打包、测试用 HTTP 桩、图标导出 |

## 开源组件与许可证

| 组件 | 用途 | 许可证 |
| --- | --- | --- |
| [Erika](https://github.com/AimesSoft/Erika) | 播放内核（FFmpeg 解码 / libass 字幕） | MPL-2.0（本体）；当前预编译包使用 LGPL profile，FFmpeg、libass、FreeType、HarfBuzz、dav1d、zlib、SoundTouch、ArtCNN 等组件各带独立许可证，完整文本随 release 的 `licenses/` 目录分发 |
| [DanmakuKit](https://github.com/qyz777/DanmakuKit) | 弹幕渲染层（vendored 为 `DanmakuRenderKit`） | MIT |
| [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) | Jellyfin 官方 SDK（登录 / 浏览 / PlaybackInfo） | MPL-2.0 |
| [Get](https://github.com/kean/Get) | HTTP 客户端（SDK 底层，经 SwiftPM 传递引入） | MIT |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | Bangumi 本地库的 SQLite 层 | MIT |
| 弹弹play 开放平台 | 弹幕数据源（经 OcPlay 网关接入） | 公开 API，客户端只持网关签发的 API Key（设置页配置），AppSecret 仅存于网关 |

其余 SwiftPM 解析依赖（swift-nio-transport-services、swift-nio、swift-atomics、swift-collections、swift-system）为 Apache-2.0。设置 → 关于 → 开源许可证中可查看实际使用的项目、用途和许可证。

**分发义务**：发布产物需随附相关组件的许可证文本。打包脚本会把 Erika 的 `LICENSE`、`MANIFEST.txt`、`THIRD_PARTY_NOTICES.md`、原生依赖 `licenses/`、Jellyfin SDK 和 SwiftPM 解析依赖许可证，以及本地 vendored 包（`DanmakuRenderKit`）的 `LICENSE` / `PROVENANCE.md` 聚合到 app 的 `Contents/Resources/THIRD_PARTY_LICENSES/`；缺少任一文本或漏登记本地 vendored 包会终止打包。FFmpeg、FriBidi、SoundTouch 等 LGPL 组件仍需满足 notices、源码与可重链要求。本项目本体选择 GPL-3.0 发布（见 `LICENSE`）。

## 本地存储上限

- 图片缓存由 `URLCache` 限制为 512 MiB，可在设置页手动清空。
- 自动下载或导入的字幕副本最多保留 100 个 / 512 MiB，超限时优先清理最旧文件。
- 播放截图只在 `Pictures/OcPlayer` 内超过 500 个 / 5 GiB 时清理最旧 PNG，不按日期主动删除。
- 诊断日志单文件 2 MiB、保留 3 份归档并最多保留 30 天；启动及每 24 小时执行维护。

## 发布与签名

推送语义化版本标签（例如 `v0.1.0`），或在 GitHub Actions 的 **Release** 工作流中手动输入标签。工作流自动拉取 Erika、构建 macOS arm64 Release，发布：

- `OcPlayer-<版本>-macOS-arm64.zip`
- `OcPlayer-<版本>-macOS-arm64.dmg`
- `SHA256SUMS.txt`

本地可用 `Scripts/package-macos.sh v0.1.1` 生成同样的 `dist/` 产物。

**需要的证书**：

- 当前流程使用 ad-hoc 签名（`Sign to Run Locally`），产物未经 Apple 签名，下载版本可能显示 Gatekeeper 提示。
- 对外分发建议配置 Apple 开发者账号：macOS 用 **Developer ID Application** 证书签名 + **notarization**（公证）；iOS 分发需要开发证书 / 描述文件（Debug 构建可仅本地运行，无需证书）。
- Jellyfin / Bangumi / MoviePilot 会话凭据与弹幕网关设置在 App 本地 UserDefaults；卸载 App 或清除其数据会移除已保存的登录会话。

## 路线

M1 媒体库、M2 播放体验、M3 弹幕完整链路均已接入；M4 打磨进行中（macOS 体验、设置、动效与可访问性）；M5 Bangumi 联动主链路已接入（OAuth 登录、收藏增量同步、进度页、详情页章节网格、播放结束自动标记），MoviePilot 找片 / 订阅作为额外能力一并落地。剩余范围见 `PLAN.md`，代码 review 待办见 `REVIEW_TODO.md`。
