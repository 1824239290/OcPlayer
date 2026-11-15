# Windows development

## 工具链版本

本项目在 Windows 上的统一构建基线是 **.NET 10 LTS + Windows App SDK 2.6**：

| 项目 | 版本 | 说明 |
| --- | --- | --- |
| .NET SDK | 10.0.4xx（LTS） | 目标框架 `net10.0-windows10.0.26100.0` |
| Windows SDK | 10.0.26100 | 由 `TargetFramework` 中的平台版本决定 |
| 最低支持系统 | Windows 10 1809（10.0.17763） | `TargetPlatformMinVersion` |
| Windows App SDK | 2.6.5 | NuGet 包 `Microsoft.WindowsAppSDK` |
| Win2D | 1.4.0 | 背景层的高斯模糊与饱和度效果；`Microsoft.Graphics.Win2D` |
| Visual Studio | 2026（可选） | 需要 .NET 桌面开发和 Windows App SDK 工作负载 |

上表是本文件的唯一版本依据：`.csproj` 的 `TargetFramework`、`TargetPlatformMinVersion` 和
`Microsoft.WindowsAppSDK` 版本改动时，必须同步更新这里；调研或试验性的版本组合写在提交信息里，
不要留在工程文件里。

## 命令行构建

纯命令行即可完成还原、编译和 unpackaged 运行，不强制安装 Visual Studio：

```powershell
./Scripts/build-windows.ps1 -KernelRoot 'D:\path\to\hdr-fixed-Erika' -LibClangPath 'D:\path\to\llvm\bin'
dotnet build OcPlayer.sln -c Debug -p:Platform=x64
```

Core 仓库默认位于同级 `../OcPlayer-Core`；可用 `-CoreRoot` 或 MSBuild 的 `OcpCoreRoot` 指定。
已有原生 DLL 时，脚本加 `-SkipNative` 可只构建前端。运行 exe 的命令见 [组合说明](core-integration.md)。

ARM64 构建把 `-p:Platform=x64` 换成 `-p:Platform=ARM64`，并准备对应 Rust 目标、C++ 工具链和 Erika ARM64 原生依赖；尚未完成 ARM64 实机验证。打包走 MSIX 时使用 Visual Studio 2026
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
`native/OcPlayerCore/<Platform>/`；构建脚本生成并复制 DLL，仓库不提交任何原生二进制。

当前默认创建 Core 实例，同时加载 `ocp_ffi.dll` 和 `erika_capi.dll`。共享业务 SDK 直接引用
Core 仓库的 `bindings/windows/OcPlayerCore` 源码，Windows 自身的适配层负责原生解码与 Core 协调。
UI Demo 使用 `--demo-route=home` 显式启动，保留 macOS 参考 fixture、静态画面和模拟时钟。
只检查 UI 编译时可以设置 `-p:OcpDemoOnly=true`。
UI 对齐范围见 [`UI-PARITY.md`](UI-PARITY.md)，本次真实播放验证见 [`core-integration.md`](core-integration.md)。

### 首页控件样式预览

`--header-actions-preview` 打开独立的 WinUI 原生控件对比窗口，提供六组打开媒体、刷新和
`AutoSuggestBox` 搜索组合。可切换深浅色，试用菜单、建议列表和搜索提交；操作只更新预览
状态，不连接服务器或打开实际文件。圆角组只设置 `CornerRadius`，所有组沿用系统控件模板。

首页已采用 E 组：`SplitButton` 左侧直接打开系统文件选择器，右侧菜单保留本地文件、直连
链接和媒体服务器入口；刷新使用默认 `Button`，搜索使用默认 `AutoSuggestBox`。回车或
搜索图标提交全库搜索，媒体库页输入或清空文字仍更新当前列表。

媒体库、详情和设置子页的左上角返回按钮使用 WinUI 的 `NavigationBackButtonNormalStyle`，
沿用系统的返回箭头动画、主题颜色和交互状态；点击仍通过共用的导航逻辑返回上级页面。
返回按钮去掉样式默认的外边距和圆角，悬停区域贴齐窗口左侧并占满标题栏高度；
宽度按右侧三个原生窗口按钮的总宽度除以三计算，并随 DPI、窗口状态和标题栏指标更新。
页面标题使用 `TextLineBounds="Tight"` 去除字形上下的额外行框留白，与原生返回箭头垂直居中对齐。

主窗口使用原生 `TitleBarHeightOption.Tall`，标题栏内容高度跟随系统返回的 `Height`，使
搜索框和窗口按钮共享垂直中心。左右安全区使用 `LeftInset` / `RightInset`，按 XAML 的
缩放比例转换，并在窗口大小、最大化状态和 DPI 改变后更新。

可单独输出预览构建，保留已运行的应用：

```powershell
dotnet build src/OcPlayer.Windows/OcPlayer.Windows.csproj -c Debug -p:Platform=x64 -p:OcpDemoOnly=true -o artifacts/header-actions-preview-build
./Scripts/start-windows.ps1 -HeaderActionsPreview -BuildDirectory artifacts/header-actions-preview-build
```

直接启动 exe 时加 `--preview-theme=light` 可默认显示浅色。之前的导航预览仍用 `--nav-preview`
或启动脚本的 `-NavigationPreview`。

## 验证边界

命令行构建覆盖还原、编译和 XAML 生成。真正的播放验证需要带 GPU 和硬件解码器的 Windows 桌面，
包括 HWND/DirectComposition 绑定和媒体键行为。Rust 核心的 `cargo test` 应在本地文件系统的 target
目录运行，不要指向 NAS 挂载卷（不支持 Cargo 增量锁文件）。
