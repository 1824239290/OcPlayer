# Windows development

## 工具链版本

本项目在 Windows 上的统一构建基线是 **.NET 10 LTS + Windows App SDK 2.6**：

| 项目 | 版本 | 说明 |
| --- | --- | --- |
| .NET SDK | 10.0.4xx（LTS） | 目标框架 `net10.0-windows10.0.26100.0` |
| Windows SDK | 10.0.26100 | 由 `TargetFramework` 中的平台版本决定 |
| 最低支持系统 | Windows 10 1809（10.0.17763） | `TargetPlatformMinVersion` |
| Windows App SDK | 2.6.5 | NuGet 包 `Microsoft.WindowsAppSDK` |
| Visual Studio | 2026（可选） | 需要 .NET 桌面开发和 Windows App SDK 工作负载 |

上表是本文件的唯一版本依据：`.csproj` 的 `TargetFramework`、`TargetPlatformMinVersion` 和
`Microsoft.WindowsAppSDK` 版本改动时，必须同步更新这里；调研或试验性的版本组合写在提交信息里，
不要留在工程文件里。

## 命令行构建

纯命令行即可完成还原、编译和 unpackaged 运行，不强制安装 Visual Studio：

```powershell
dotnet restore OcPlayer.sln
dotnet build OcPlayer.sln -c Debug -p:Platform=x64
dotnet run --project src/OcPlayer.Windows/OcPlayer.Windows.csproj -p:Platform=x64
```

ARM64 构建把 `-p:Platform=x64` 换成 `-p:Platform=ARM64`。打包走 MSIX 时使用 Visual Studio 2026
的打包目标或 `msbuild /t:Publish`，这条路径不在本文件的命令行范围内。

### 未打包（unpackaged）运行的前置条件

`src/OcPlayer.Windows/OcPlayer.Windows.csproj` 默认设置 `WindowsPackageType=None`，因此应用进程的
启动依赖两样东西：

1. **Windows App Runtime 2.6**：需要 `Microsoft.WindowsAppRuntime.2` 框架包（2.6.5 及以上）。
   没装时启动会报 `REGDB_E_CLASSNOTREG (0x80040154)`。可用官方 redist，或直接安装 NuGet 缓存
   `~/.nuget/packages/microsoft.windowsappsdk.runtime/2.6.5/tools/MSIX/win10-x64/` 下的
   `Runtime`、`Main`、`Singleton`、`DDLM` 四个 `.msix`。
2. **可发现的 .NET 运行时**：apphost 会依次查找 `DOTNET_ROOT`、注册表和 `C:\Program Files\dotnet`。
   SDK 装在用户目录（如 `%LOCALAPPDATA%\Microsoft\dotnet`）时，必须设置环境变量
   `DOTNET_ROOT` 和 `DOTNET_ROOT_X64` 指向该目录，否则启动报 “You must install .NET”。

## 原生核心

WinUI 应用通过 `OcPlayer.CoreAdapter` 的 P/Invoke 调用 `ocp_ffi.dll`，契约见
[`ffi-contract.md`](ffi-contract.md)。开发时需要把匹配的 DLL 放到应用输出目录旁边
（`src/OcPlayer.Windows/bin/<Platform>/<Configuration>/net10.0-windows10.0.26100.0/`）或
`native/OcPlayerCore/`；仓库不提交任何原生二进制。

当前默认启动离线前端 Demo，不创建 Core 实例，因此不依赖 `ocp_ffi.dll`。首页使用 macOS
参考截图的图像 fixture，播放器使用静态画面与模拟时钟。真实 Core 接入与视频渲染仍需单独实现，
不会因为放入 DLL 就自动启用。UI 对齐范围与具体差异见 [`UI-PARITY.md`](UI-PARITY.md)。

## 验证边界

命令行构建覆盖还原、编译和 XAML 生成。真正的播放验证需要带 GPU 和硬件解码器的 Windows 桌面，
包括 HWND/DirectComposition 绑定和媒体键行为。Rust 核心的 `cargo test` 应在本地文件系统的 target
目录运行，不要指向 NAS 挂载卷（不支持 Cargo 增量锁文件）。
