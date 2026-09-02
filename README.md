# OcPlayer · 橘猫播放器

自用的 Jellyfin / Emby 播放器，SwiftUI 真原生双端（macOS 为主 + iOS/iPadOS），系统要求 macOS 26 / iOS 26 起。播放内核基于 Rust 写的 [Erika](https://github.com/AimesSoft/Erika)（C ABI 接入，内置 FFmpeg 解码 + libass 字幕渲染），弹幕接入弹弹play 并统一由 App 层 overlay 渲染，另集成 Bangumi（番剧追踪）与 MoviePilot（找片 / 下载 / 订阅）。

## 功能

- **媒体库**：Jellyfin / Emby 服务器自动识别（登录探活判定类型），Jellyfin 账号密码 + Quick Connect、Emby 账号密码；多服务器记忆与一键切换（登出不再遗忘档案，token 失效自动尝试其它已存服务器）；媒体库分页浏览、电影/剧集详情、季/集选择；首页继续观看、接下来看、最近添加
- **播放**：pause / seek / 倍速 / 音轨与字幕切换 / 外挂字幕 / 续播 / 进度上报 / 自动连播下一集 / macOS 键盘快捷键；章节列表跳转；片头片尾识别 + 悬浮「跳过」按钮；网络预读缓冲可调（2 / 8 / 16 / 32 MiB，公网高延迟服务器建议调大）；macOS 走 VideoToolbox 硬解 + IOSurface 零拷贝；HUD 为原生 Liquid Glass——右下角功能按钮融合成玻璃胶囊，点开的按钮液态形变为「行 + 子菜单」式玻璃面板（Infuse 风格）
- **弹幕**：已有剧集映射直接复用；首次匹配以本地文件或认证 Range 请求的前 16 MiB MD5 配合文件名、大小和时长识别；手动搜索选集、匹配缓存、时间偏移、不透明度、显示区域与类型过滤
- **Bangumi（番剧追踪）**：OAuth 登录、收藏与在看进度、每日放送日历、条目详情与章节标记、播放结束自动标记本集看过
- **MoviePilot（找片 + 下载 + 订阅）**：按标题搜站点资源、下载任务列表、订阅管理
- **本地播放**：打开本地文件 / 直连链接，支持 iOS 文件选择器权限生命周期管理

## 下载

预编译版本见 [Releases](../../releases)：

- macOS（arm64）：`OcPlayer-<版本>-macOS-arm64.dmg`（或 `.zip`），附 `SHA256SUMS.txt`
- iOS 暂无预编译产物，需自行构建（Debug 构建仅本地运行，无需分发证书）

> 当前产物为 ad-hoc 签名，未经 Apple 公证，首次打开可能出现 Gatekeeper 提示。

## 构建

```bash
Scripts/bootstrap.sh             # 可选：生成本地 Secrets.xcconfig 模板，不会覆盖已有文件
Scripts/fetch-erika.sh           # 解析并拉取最新 Erika，生成 Erika.xcframework（不入库，约 753 MB）
Scripts/build-macos.sh           # 检查最新内核，清理上次产物并构建 macOS Debug
Scripts/build-macos.sh release   # Release 构建
Scripts/package-macos.sh v0.1.5  # 本地打包，产出与 CI 相同的 dist/ 产物
```

各 SPM 包测试（全部离线，不碰真实网络）：`swift test --package-path Packages/<CoreModel|DiagnosticsKit|PlaybackKit|ErikaKit|JellyfinKit|DanmakuKit|DanmakuRenderKit|BangumiKit|MoviePilotKit>`。

> 内核当前取自 fork [1824239290/Erika](https://github.com/1824239290/Erika) 的 `v0.1.7+readahead.1`（新增 HTTP 预读 API，改动已提上游）。CI 与本地脚本默认都指向 fork；上游合并后用 `ERIKA_VERSION=latest`（可省）+ `ERIKA_REPO` 不设即可切回官方。`SKIP_ERIKA_FETCH=1` 可让 `package-macos.sh` 直接使用 Vendor 里现成的内核产物，跳过 fetch。

> `fetch-erika.sh` 等脚本默认解析 GitHub 最新正式版，已有同版本完整产物会复用；可重复构建时将 `ERIKA_VERSION` 钉到具体 tag。macOS 构建必须用 `-scheme`，架构钉死 arm64。CI（`.github/workflows/`）在 push/PR 上跑全量测试门禁，语义化版本标签触发 Release 工作流。

## 使用建议

- 支持 Jellyfin（10.x）与 Emby（4.x），登录时显式选择 HTTP/HTTPS；Emby 没有 Quick Connect，只显示账号密码表单
- 弹幕开箱即用：内置公共 OcPlay 网关（Cloudflare Workers 部署，持有弹弹play AppSecret）签发的 API Key；如需自建网关 / 自有 Key，在 设置 → 弹幕 中修改
- 内核弹幕渲染当前因内存问题被禁用，运行时固定走 App 层 overlay 渲染，详见下文「弹幕渲染路线」

## 项目结构

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| App | `App/` | 双端 UI、观察式状态（Observation）、`AppModel` 中枢 + 域模型（Bangumi / MoviePilot / 弹幕） |
| PlaybackKit | `Packages/PlaybackKit/` | 内核抽象层：`PlaybackEngine` 协议、注册与失效回退、契约测试 |
| CoreModel | `Packages/CoreModel/` | 纯数据模型，双端共享，无第三方依赖 |
| ErikaKit | `Packages/ErikaKit/` | 播放内核封装：引擎、事件流、画面承载、播放状态 |
| JellyfinKit | `Packages/JellyfinKit/` | Jellyfin / Emby 薄封装：登录探活识别服务器类型、媒体库、PlaybackInfo、进度上报；Emby 走 `/emby` 前缀与老式路由适配 |
| DanmakuKit | `Packages/DanmakuKit/` | 弹弹play 网关客户端：match/search/comments、JSON 转换、缓存、16MiB 哈希 |
| DanmakuRenderKit | `Packages/DanmakuRenderKit/` | vendored 弹幕渲染层（qyz777/DanmakuKit，MIT，见 `PROVENANCE.md`）：轨道池、cell 复用、SwiftUI 适配 |
| BangumiKit | `Packages/BangumiKit/` | Bangumi OAuth、收藏/章节/搜索/日历 API、GRDB 本地库 |
| MoviePilotKit | `Packages/MoviePilotKit/` | MoviePilot 登录换 JWT、401 静默重登、订阅/搜索/下载 API |
| DiagnosticsKit | `Packages/DiagnosticsKit/` | 统一日志、脱敏、节流、轮转；网络公共工具 |

## 弹幕渲染路线

弹幕统一走 **App 层 overlay**（`DanmakuRenderKit`）：App 在视频画面上方独立绘制，与内核解码/合成解耦，截图不带弹幕。内核内置弹幕渲染器（Erika DFM+）当前版本因弹幕定位导致内核将完整视频加载进内存而被禁用，运行时强制 overlay；等内核修复后恢复「用内核渲染弹幕」开关即可切回。

网关侧持有弹弹play 官方 `AppSecret` 并生成签名，客户端只持 API Key（`X-API-Key` 头），地址必须为 HTTPS origin；不要在日志或界面输出 Key 等凭据。

## 许可证

本项目**源代码**以 [GNU General Public License v3](LICENSE)（GPL-3.0）许可发布。

- 发布产物聚合第三方许可证文本到 `Contents/Resources/THIRD_PARTY_LICENSES/`，缺少任一文本会终止打包
- FFmpeg、libass、SoundTouch 等 LGPL 组件需满足 notices、源码与可重链要求

## 感谢

本项目依赖以下开源项目与服务（完整清单见应用 设置 → 关于 → 开源许可证）：

- [Erika](https://github.com/AimesSoft/Erika)（FFmpeg / libass）
- [DanmakuKit](https://github.com/qyz777/DanmakuKit)
- [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) / [Jellyfin](https://jellyfin.org/)
- [GRDB.swift](https://github.com/groue/GRDB.swift) / [Get](https://github.com/kean/Get)
- [弹弹play](https://www.dandanplay.com/)（经 OcPlay 网关接入）
- [Bangumi](https://bgm.tv/) / [MoviePilot](https://github.com/jxxghp/MoviePilot)

## 文档

- 更新日志：`CHANGELOG.md`

## 路线

M1 媒体库、M2 播放体验、M3 弹幕完整链路、M5 Bangumi 联动与 MoviePilot 找片均已接入；近期并入 Emby 适配（登录探活自动识别、老式路由全链路）、多服务器记忆与切换、自编译 fork 内核的网络预读缓冲。M4 打磨进行中；0.1.5 待 Emby 真机验证后发版。
