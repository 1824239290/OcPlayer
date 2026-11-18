# OcPlayer

OcPlayer 的共享 Rust Core、Windows 客户端和 macOS/iOS 客户端现在在同一个仓库维护。liberika 播放内核仍是外部依赖，Apple 与 Windows 分别保留已验证的版本钉点。

迁移候选位于 `codex/monorepo-migration`；验收完成前不切换 `main`，也不归档旧仓库。当前结果和待验收项见 [执行记录](docs/migration/EXECUTION.md)。

本机追加验收见 [macOS 报告](docs/migration/MACOS-VALIDATION-2026-11-18.md) 与 [Windows 报告](docs/migration/WINDOWS-VALIDATION-2026-11-18.md)。两端追加修复已合入最终候选，正在完成新提交的必需 CI，详见 [收尾记录](docs/migration/CONSOLIDATION-2026-11-18.md)。

| 组件 | 源码与工具链 | 组件文档 |
| --- | --- | --- |
| 共享 Core / SDK | `core/` · Rust、C ABI、Swift/C# 绑定 | [Core README](core/README.md) |
| Windows | `apps/windows/` · .NET 10、WinUI 3、MSVC | [Windows README](apps/windows/README.md) |
| macOS / iOS | `apps/apple/` · Xcode、SwiftPM | [Apple README](apps/apple/README.md) |

- [开发与构建](docs/DEVELOPMENT.md)
- [架构与平台边界](docs/ARCHITECTURE.md)
- [Apple Swift/Rust 职责清单](docs/migration/APPLE-SWIFT-OWNERSHIP.md)
- [迁移计划](docs/MONOREPO-MIGRATION-PLAN.md) · [执行记录](docs/migration/EXECUTION.md)
- [下载与发行记录](https://github.com/1824239290/OcPlayer/releases)

## 快速开始

只需克隆一次，无需再在旁边检出 Core 或 Windows 仓库。

```powershell
git clone -c core.longpaths=true --branch codex/monorepo-migration http://192.168.5.107:8418/jumusu/OcPlayer.git
cd OcPlayer
python scripts/verify-monorepo.py
.\scripts\prepare-kernel.ps1
.\scripts\build-windows.ps1 -LibClangPath 'C:\path\to\LLVM\bin'
.\scripts\start-windows.ps1
```

macOS 开发：

```bash
./apps/apple/Scripts/bootstrap.sh
./scripts/build-macos.sh debug
```

普通 Apple 构建与 Core-enabled 接入验收保持分离；合仓不会自动启用 Core 或删除原生业务兜底。详见开发文档。

## 仓库与版本

Gitea `jumusu/OcPlayer` 为开发主仓，[GitHub](https://github.com/1824239290/OcPlayer) 保留相同历史并提供 Actions 与发行产物。Apple 继续使用 `v*` 标签，Windows 使用 `windows/v*`，独立 Core SDK 使用 `core/v*`。标签对应同一仓库提交，不要求三个组件一起发版。

本项目按 GPL-3.0-only 发布，见 [LICENSE](LICENSE)。组件的第三方许可证与构建来源记录保留在各自目录中。
