# OcPlayer-Windows

OcPlayer 的 Windows 移植版本。项目目标是在保留 OcPlayer 媒体库、Jellyfin / Emby、弹幕和本地播放能力的基础上，提供符合 Windows 设计语言的桌面体验。

## 当前状态

Windows 前端已接入同级 `OcPlayer-Core` 仓库的共享 SDK 和 Rust DLL。默认启动真实模式，
本地文件 / HTTP(S) 链接通过 Erika 的 Windows 原生后端播放，进度由 Core 保存。
Jellyfin / Emby 的登录、首页、媒体库搜索、详情、分季分集、播放地址和播放上报通过 Core 调用。
离线 UI Demo 保留为显式启动模式。构建与验证见 [`docs/core-integration.md`](docs/core-integration.md)。

已有本机构建时，运行 `./Scripts/start-windows.ps1`，点击首页标题栏的“连接服务器”，
或进入“设置 → 媒体服务器”。填写地址、类型、用户名和密码后即可加载真实片库。
登录会自动保存并在下次启动恢复；从 Demo 连接成功也会切换到真实模式。

远端仓库位于 NAS Gitea：

- `http://192.168.5.107:8418/jumusu/OcPlayer-Windows`
- 默认分支：`main`

## 技术路线

- **UI**：WinUI 3 + Windows App SDK
- **语言与运行时**：C# + .NET 10 LTS
- **架构**：MVVM，使用 CommunityToolkit.Mvvm；应用启动、依赖注入和配置使用 `Microsoft.Extensions.Hosting`
- **共享核心**：逐步把 macOS、iOS、Windows 共用的媒体播放、媒体模型、同步规则和跨平台业务迁移到 Rust；通过稳定的 C ABI 接入 Swift 和 C#，两端 UI 与系统能力分别使用原生实现
- **服务端 API**：Jellyfin / Emby 使用独立的 typed client 层，避免 UI 直接依赖 HTTP 细节
- **本地数据**：SQLite + `Microsoft.Data.Sqlite`，保存服务器配置、播放历史、设置和缓存索引
- **日志与诊断**：`Microsoft.Extensions.Logging`，提供可导出的诊断包
- **测试**：xUnit + FluentAssertions；核心领域逻辑和跨平台协议层优先覆盖
- **打包**：MSIX 为主，保留 unpackaged 构建用于开发和故障排查

详细设计见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

WinUI 3 前端的页面布局、Core 接入边界及实施顺序见
[`docs/WINUI3-FRONTEND-PLAN.md`](docs/WINUI3-FRONTEND-PLAN.md)。该方案以共享 Core 已完成为前提，
对照当前 macOS 源码规划 Windows 前端。

UI 以 macOS 原版为准，当前对齐范围和未实现差异见
[`docs/UI-PARITY.md`](docs/UI-PARITY.md)。当前应用可运行离线前端 Demo，首页对照用户的 macOS 截图，
显式 Demo 模式的播放器使用静态画面与模拟时钟；默认模式使用真实解码及 `SwapChainPanel` 视频表面。

## 开发前置条件

Windows 11（最低 Windows 10 1809）、.NET SDK 10.0.4xx（LTS）和 Windows App SDK 2.6.5；目标框架固定为 `net10.0-windows10.0.26100.0`。Visual Studio 2026（.NET 桌面开发和 Windows App SDK 工作负载）为可选项，用于调试和 MSIX 打包；命令行 `dotnet build` 足以完成还原与编译。完整版本基线和命令见 [`docs/development.md`](docs/development.md)。
