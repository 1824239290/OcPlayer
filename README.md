# OcPlayer-Windows

OcPlayer 的 Windows 移植版本。项目目标是在保留 OcPlayer 媒体库、Jellyfin / Emby、弹幕和本地播放能力的基础上，提供符合 Windows 设计语言的桌面体验。

## 当前状态

项目已初始化，远端仓库位于 NAS Gitea：

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

## 开发前置条件

Windows 11（最低 Windows 10 1809）、.NET SDK 10.0.4xx（LTS）和 Windows App SDK 2.6.5；目标框架固定为 `net10.0-windows10.0.26100.0`。Visual Studio 2026（.NET 桌面开发和 Windows App SDK 工作负载）为可选项，用于调试和 MSIX 打包；命令行 `dotnet build` 足以完成还原与编译。完整版本基线和命令见 [`docs/development.md`](docs/development.md)。
