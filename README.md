# OcPlayer · 橘猫播放器

自用的 Jellyfin 播放器，SwiftUI 真原生双端（macOS 为主 + iOS/iPadOS）。

播放内核基于 Rust 写的 [Erika](https://github.com/AimesSoft/Erika)（C ABI 接入，内置 FFmpeg 解码 + libass 字幕渲染 + 弹幕渲染）；媒体库走 Jellyfin 官方 Swift SDK；弹幕通过 OcPlay 网关接入弹弹play，支持自动匹配、哈希兜底、手动选集和播放内调节。

## 特性

- **Jellyfin 完整串联**：登录（账号密码 + Quick Connect）、媒体库分页浏览、电影/剧集详情、季/集选择、播放单集
- **首页**：英雄轮播（多图自动切换，可在设置切换「最近添加 / 我的收藏」来源）、收藏轮播空态回落
- **播放**：pause / seek / 倍速 / 音轨与字幕切换 / 外挂字幕 / 续播 / 进度上报（Start → 心跳 → Stopped）/ 自动连播下一集
- **弹幕**：已有剧集映射直接复用；首次匹配以本地文件或认证 Range 请求的前 16 MiB MD5 配合文件名、大小和时长识别；支持手动搜索选集、匹配与正文缓存、开关、时间偏移、不透明度、显示区域和类型过滤
- **画质**：macOS 走 VideoToolbox 硬解 + IOSurface 零拷贝；本地文件与直连 HTTP 流均可播放
- **认证**：Jellyfin AccessToken 只作为 HTTP 头（API / 图片管线 / 内核 `open_with_headers`），不拼进 URL；会话凭据存于 App 本地 UserDefaults，不访问系统钥匙串。弹幕网关 API Key 存 UserDefaults，AppSecret 只在网关侧保存
- **本地播放**：打开本地文件 / 直连链接，支持 iOS 文件选择器权限生命周期管理

## 构建

```bash
Scripts/bootstrap.sh             # 可选：生成本地 Secrets.xcconfig 模板，不会覆盖已有文件
Scripts/fetch-erika.sh           # 解析并拉取最新 Erika，生成 Erika.xcframework（不入库，约 753 MB）
Scripts/build-macos.sh           # 检查最新内核，清理上次产物并构建 macOS Debug
Scripts/build-macos.sh release   # 检查最新内核，清理上次产物并构建 macOS Release
swift Scripts/export-app-icon.swift <浅色源图> <深色源图> App/Shared/Assets.xcassets/AppIcon.appiconset
swift test --package-path Packages/ErikaKit     # 内核 + 渲染 + HTTP 全套（素材现造，不联网）
swift test --package-path Packages/JellyfinKit  # Jellyfin 登录、浏览、映射与请求参数（全离线 mock）
swift test --package-path Packages/DanmakuKit  # 网关客户端、转换、缓存、哈希与设置（全离线 mock）
swift test --package-path Packages/DiagnosticsKit # 统一日志、脱敏、节流与轮转
```

> 脚本固定使用 `.local-build/current`，每次构建前会完整删除该目录，避免累积多个本地产物。macOS 构建必须用 `-scheme`（不能用 `-target`，详见工程内注释）；macOS 架构钉死 arm64。
>
> `fetch-erika.sh`、`build-macos.sh` 和 `package-macos.sh` 默认每次解析 GitHub 最新正式版；已有同版本完整产物会直接复用。需要可重复构建时，将 `ERIKA_VERSION` 设为 `fetch-erika.sh --resolve-version` 输出的具体 tag。

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
| App | `App/` | 双端 UI、观察式状态（Observation）与共享 AppIcon 资源 |
| CoreModel | `Packages/CoreModel/` | 纯数据模型，双端共享，无第三方依赖 |
| ErikaKit | `Packages/ErikaKit/` | 播放内核封装：引擎、事件流、画面承载、播放状态，含无头回归测试 |
| JellyfinKit | `Packages/JellyfinKit/` | Jellyfin 薄封装：登录、媒体库、PlaybackInfo、进度上报，全离线测试 |
| DanmakuKit | `Packages/DanmakuKit/` | 弹弹play 网关客户端：match/search/comments、弹弹play→Erika JSON 转换、本地缓存、本地与远程前 16MiB 文件哈希、网关设置，全离线测试 |
| DiagnosticsKit | `Packages/DiagnosticsKit/` | 统一 JSONL / OSLog 日志、敏感字段脱敏、节流、导出与轮转 |
| Scripts | `Scripts/` | 内核拉取、HTTP 测试桩、打包脚本 |

## 开源组件与许可证

| 组件 | 用途 | 许可证 |
| --- | --- | --- |
| [Erika](https://github.com/AimesSoft/Erika) | 播放内核（FFmpeg 解码 / libass 字幕 / 弹幕渲染） | MPL-2.0（本体）；当前预编译包使用 LGPL profile，FFmpeg、libass、FreeType、HarfBuzz、dav1d、zlib、SoundTouch、ArtCNN 等组件各带独立许可证，完整文本随 release 的 `licenses/` 目录分发 |
| [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) | Jellyfin 官方 SDK（登录 / 浏览 / PlaybackInfo） | MPL-2.0 |
| [Get](https://github.com/kean/Get) | HTTP 客户端（SDK 底层，经 SwiftPM 传递引入） | MIT |
| 弹弹play 开放平台 | 弹幕数据源（经 OcPlay 网关接入） | 公开 API，客户端只持网关签发的 API Key（设置页配置），AppSecret 仅存于网关 |

其余 SwiftPM 传递依赖（swift-nio、swift-atomics、swift-collections、swift-system 等）为 Apple 系 Apache-2.0 库，随依赖图自动引入。

**分发义务**：发布产物需随附相关组件的许可证文本。当前打包脚本会把 Erika 的 `LICENSE`、`THIRD_PARTY_NOTICES.md` 与 `licenses/` 目录复制进 app 的 `Contents/Resources/THIRD_PARTY_LICENSES/`；对外分发前还需聚合 Jellyfin SDK 与 SwiftPM 依赖的许可证。FFmpeg、FriBidi、SoundTouch 等 LGPL 组件需满足 notices、源码与可重链要求。本项目本体选择 GPL-3.0 发布（见 `LICENSE`）。

## 发布与签名

推送语义化版本标签（例如 `v0.1.0`），或在 GitHub Actions 的 **Release** 工作流中手动输入标签。工作流自动拉取 Erika、构建 macOS arm64 Release，发布：

- `OcPlayer-<版本>-macOS-arm64.zip`
- `OcPlayer-<版本>-macOS-arm64.dmg`
- `SHA256SUMS.txt`

本地可用 `Scripts/package-macos.sh v0.1.1` 生成同样的 `dist/` 产物。

**需要的证书**：

- 当前流程使用 ad-hoc 签名（`Sign to Run Locally`），产物未经 Apple 签名，下载版本可能显示 Gatekeeper 提示。
- 对外分发建议配置 Apple 开发者账号：macOS 用 **Developer ID Application** 证书签名 + **notarization**（公证）；iOS 分发需要开发证书 / 描述文件（Debug 构建可仅本地运行，无需证书）。
- Jellyfin token 存在 App 本地 UserDefaults；卸载 App 或清除其数据会移除已保存的登录会话。

## 路线

M1 媒体库、M2 播放体验和 M3 弹幕完整链路均已接入；当前进入 M4，继续处理维护性、搜索 / 收藏等产品能力和双端适配。未完成项见 `REVIEW_TODO.md`。
