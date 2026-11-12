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
- **播放内核**：优先复用 OcPlayer 现有的 Rust `liberika`（FFmpeg + libass），通过稳定的 C ABI / PInvoke 边界接入；在 Windows 端验证成本过高的能力再评估 libmpv 作为替代方案
- **服务端 API**：Jellyfin / Emby 使用独立的 typed client 层，避免 UI 直接依赖 HTTP 细节
- **本地数据**：SQLite + `Microsoft.Data.Sqlite`，保存服务器配置、播放历史、设置和缓存索引
- **日志与诊断**：`Microsoft.Extensions.Logging`，提供可导出的诊断包
- **测试**：xUnit + FluentAssertions；核心领域逻辑和跨平台协议层优先覆盖
- **打包**：MSIX 为主，保留 unpackaged 构建用于开发和故障排查

详细设计见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 开发前置条件

Windows 11、Visual Studio 2026（.NET 桌面开发和 Windows App SDK 工作负载）以及对应的 Windows SDK。具体版本以项目首次生成时的解决方案文件为准。
