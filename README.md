# OcPlayer · 橘猫播放器

自用的 Jellyfin 播放器，SwiftUI 真原生双端（macOS 为主 + iOS/iPadOS）。

播放内核基于 Rust 写的 [Erika](https://github.com/AimesSoft/Erika)（C ABI 接入，内置 FFmpeg 解码 + libass 字幕渲染 + 弹幕渲染）；媒体库走 Jellyfin 官方 Swift SDK；弹幕规划走弹弹play 开放平台（M3，暂缓）。

## 特性

- **Jellyfin 完整串联**：登录（账号密码 + Quick Connect）、媒体库分页浏览、电影/剧集详情、季/集选择、播放单集
- **首页**：英雄轮播（多图自动切换，可在设置切换「最近添加 / 我的收藏」来源）、收藏轮播空态回落
- **播放**：pause / seek / 倍速 / 音轨与字幕切换 / 外挂字幕 / 续播 / 进度上报（Start → 心跳 → Stopped）/ 自动连播下一集
- **画质**：macOS 走 VideoToolbox 硬解 + IOSurface 零拷贝；本地文件与直连 HTTP 流均可播放
- **认证**：Jellyfin AccessToken 只作为 HTTP 头（API / 图片管线 / 内核 `open_with_headers`），不拼进 URL；会话凭据存于 App 本地 UserDefaults，不访问系统钥匙串
- **本地播放**：打开本地文件 / 直连链接，支持 iOS 文件选择器权限生命周期管理

## 构建

```bash
Scripts/bootstrap.sh             # 可选：生成本地弹弹play密钥配置，不会覆盖已有文件
Scripts/fetch-erika.sh v0.1.6   # 拉取 Erika 内核，生成 Erika.xcframework（不入库，约 753 MB）
Scripts/build-macos.sh           # 清理上次产物并构建 macOS Debug，只保留本次构建
Scripts/build-macos.sh release   # 清理上次产物并构建 macOS Release
swift Scripts/export-app-icon.swift <浅色源图> <深色源图> App/Shared/Assets.xcassets/AppIcon.appiconset
swift test --package-path Packages/ErikaKit     # 内核 + 渲染 + HTTP 全套（素材现造，不联网）
swift test --package-path Packages/JellyfinKit  # Jellyfin 登录、浏览、映射与请求参数（全离线 mock）
```

> 脚本固定使用 `.local-build/current`，每次构建前会完整删除该目录，避免累积多个本地产物。macOS 构建必须用 `-scheme`（不能用 `-target`，详见工程内注释）；macOS 架构钉死 arm64。

### 弹弹play 本地配置

项目没有 `Secrets.xcconfig` 也能正常构建；此时弹弹play 功能应保持未配置状态。需要接入弹幕时，先运行 `Scripts/bootstrap.sh`，然后只在本地的 `Secrets.xcconfig` 中填写：

```xcconfig
DANDANPLAY_APP_ID = <你的 AppId>
DANDANPLAY_APP_SECRET = <你的 AppSecret>
```

仓库只提交空值模板 `Secrets.xcconfig.example`，真实配置已被 `.gitignore` 排除。构建时两个值会写入 app 的 Info.plist，App 层通过 `AppConfiguration.dandanplayCredentials` 只读获取；未同时提供 AppId 和 AppSecret 时返回 `nil`。不要在日志、错误提示或界面中输出 AppSecret。

> 客户端内置凭据无法像服务端密钥一样保密，发布后的 app 中仍可提取 AppSecret。本地配置的作用是防止误提交和减少日常泄露，不是安全边界；弹弹play 后台应限制权限，并预留凭据轮换方案。

应用图标位于 `App/Shared/Assets.xcassets/AppIcon.appiconset`。iOS 使用浅色默认图标与深色外观图标；macOS 的传统 AppIcon 不支持外观槽位，因此使用深色版本并提供完整多尺寸资源。

## 项目结构

| 模块 | 位置 | 说明 |
| --- | --- | --- |
| App | `App/` | 双端 UI、观察式状态（Observation）与共享 AppIcon 资源 |
| CoreModel | `Packages/CoreModel/` | 纯数据模型，双端共享，无第三方依赖 |
| ErikaKit | `Packages/ErikaKit/` | 播放内核封装：引擎、事件流、画面承载、播放状态，含无头回归测试 |
| JellyfinKit | `Packages/JellyfinKit/` | Jellyfin 薄封装：登录、媒体库、PlaybackInfo、进度上报，全离线测试 |
| Scripts | `Scripts/` | 内核拉取、HTTP 测试桩、打包脚本 |

## 开源组件与许可证

| 组件 | 用途 | 许可证 |
| --- | --- | --- |
| [Erika](https://github.com/AimesSoft/Erika) | 播放内核（FFmpeg 解码 / libass 字幕 / 弹幕渲染） | Apache-2.0（本体）；内置 FFmpeg、libass、FreeType、HarfBuzz、dav1d、zlib、ArtCNN 等组件各带其许可证（LGPL / GPL / MIT / BSD / zlib 等），完整文本随 `Vendor/` 内 `licenses/` 目录分发 |
| [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) | Jellyfin 官方 SDK（登录 / 浏览 / PlaybackInfo） | MPL-2.0 |
| [Get](https://github.com/kean/Get) | HTTP 客户端（SDK 底层，经 SwiftPM 传递引入） | MIT |
| 弹弹play 开放平台 | 弹幕数据源（规划中，未接入） | 公开 API，需在设置页配置 AppId / AppSecret（本地 `Secrets.xcconfig`，不入库） |

其余 SwiftPM 传递依赖（swift-nio、swift-atomics、swift-collections、swift-system 等）为 Apple 系 Apache-2.0 库，随依赖图自动引入。

**分发义务**：发布产物需随附上述组件的许可证文本，打包脚本会把 Erika 的 `LICENSE`、`THIRD_PARTY_NOTICES.md` 与 `licenses/` 目录复制进 app 的 `Contents/Resources/THIRD_PARTY_LICENSES/`；SDK 的 LICENSE 文件随 SwiftPM 依赖分发，需保留各自的版权声明；FFmpeg 按 LGPL 条款构建时需满足 relink 等对应要求。本项目本体以 GPL-3.0 发布（见 `LICENSE`，因 Erika 捆绑组件含 GPL-3.0）。

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

M1 媒体库（Jellyfin 浏览 + 播放串联）→ M2 播放体验（轨道、字幕、续播、进度上报）→ M3 弹幕 → M4 打磨与双端适配。
