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
./Scripts/prepare-kernel.ps1
./Scripts/build-windows.ps1 -KernelRoot './artifacts/liberika-v0.3.7' -LibClangPath 'D:\path\to\llvm\bin'
dotnet build OcPlayer.sln -c Debug -p:Platform=x64
```

Core 仓库默认位于同级 `../OcPlayer-Core`；可用 `-CoreRoot` 或 MSBuild 的 `OcpCoreRoot` 指定。
已有原生 DLL 时，脚本加 `-SkipNative` 可只构建前端。运行 exe 的命令见 [组合说明](core-integration.md)。

ARM64 构建把 `-p:Platform=x64` 换成 `-p:Platform=ARM64`，并准备对应 Rust 目标、C++ 工具链和 Erika ARM64 原生依赖；尚未完成 ARM64 实机验证。MSI 安装包由 `Scripts/package-windows.ps1` 生成，包含所需运行库，命令与验收见 [发行说明](release-windows.md)。

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

无服务器时首页显示新的 WinUI 3 连接页：左侧是应用介绍，右侧是已保存服务器和地址表单；窗口较窄时只显示居中的表单。连接流程先检测 Jellyfin / Emby，再显示账号输入，继续复用 Core 的账号验证、媒体库读取和服务器保存。Jellyfin 保留 Quick Connect，底部可直接进入本地播放器。设置中的“连接服务器”使用同一页面。

Debug 构建支持 `--verify-server-connection=<绝对输出目录>`。`tests/OcPlayer.Ui/ServerConnectionVerification.cs` 使用隔离的账号存储和本地 HTTP fixture，通过真实 Core 验证两步登录、错误重试、已保存账号连接、协议识别和本地播放入口，并输出浅色、深色、账号页和窄窗口截图及 `results.json`；完成后自动关闭。请通过 `Scripts/start-windows.ps1 -PrepareOnly` 返回的暂存 EXE 启动验证。

### 播放器菜单与原生截图

菜单树逐项对照 macOS `OcPlayer/App/Shared/Features/Player/PlayerHUDActions.swift`，完整映射见
[`UI-PARITY.md`](UI-PARITY.md#播放器菜单对照2026-11-16)。Windows 的菜单实现分布在
`PlayerView.Danmaku.cs`、`PlayerView.Tracks.cs`、`PlayerView.More.cs`；更多菜单包含倍速子菜单、
播放信息、截图与条件分享，全屏按用户选择只放在左上标题栏。

能力判断需要追踪共享 Core、Erika JSON 桥及 C ABI。字幕字号已由 `PlaybackSession.SetSubtitleScale`
调用 Erika `setSubtitleScale`，不需要另造字号后端；章节通过 `PlaybackChapters` 调用现有
`browse.chapters`，读取 Jellyfin 章节，转换 `StartPositionTicks` 并按当前位置高亮、跳转。
章节不是只剩“从头播放”，也不是依赖不存在的 Windows 专用章节 API。本地/直连媒体没有
服务器章节数据时使用空状态。字幕大小保存在数据目录的播放偏好中，范围与 macOS 一致。

播放信息从 native 状态/缓冲/视频参数事件、轨道列表和现有统计 JSON 读取，每秒刷新；
它不随着 HUD 自动隐藏。截图通过 `erika_presenter_capture_frame_rgba` 取得视频与字幕的 RGBA8，
不读取桌面或 XAML 画面。PNG 写入系统“图片/OcPlayer”，失败只显示提示，不暂停播放。
分享通过 `DataTransferManagerInterop.GetForWindow/ShowShareUIForWindow` 打开系统分享面板；
本地媒体使用 `StorageFile`，公共网络媒体使用 `WebLink`，不将需要鉴权的流地址作为公共链接分享。
本地文件优先使用 `GetFileFromPathAsync`；若 WinRT 存储代理拒绝访问，使用官方支持的流式
`StorageFile`，仅在分享目标索取内容时读取源文件。独立验证通过 DataPackage 取回 36,418
字节并与源逐字节比较，同时验证源不可读时请求返回失败，记录在
`artifacts/player-share-storage-probe/results.json`。分享操作使用代次隔离，换片、取消及晚到
回调会正确释放 HUD 保持状态；这些验证不向第三方发送文件。

`erika_presenter_capture_frame_rgba` 原先已在 Windows 导出，但默认 D3D11 renderer 使用了返回
空帧的默认实现，不能仅凭导出符号或 WGPU 实现认为截图可用。
[`Scripts/patches/player-screenshot-d3d11.patch`](../Scripts/patches/player-screenshot-d3d11.patch)
是在现有 Windows HDR 修复源码之上应用的补丁：新增独立 SDR RGBA8 render target、按源色彩
重建的 SDR uniforms、字幕合成，以及处理 `RowPitch` 的 staging readback；保留正常 HDR
播放的参数、交换链和输出模式，不合成弹幕或 HUD。该补丁也修复暂停时字幕解码与 overlay
刷新：暂停导入/选择外挂字幕不需要恢复播放，关闭和重选外挂字幕不会 seek 主视频。
`Scripts/build-windows.ps1` 会检查补丁是否已经应用，未应用时先校验再应用，并在 native
build receipt 中记录补丁和 DLL 的 SHA256。

原生验证使用与构建脚本一致的 MSVC x64 环境、`LIBCLANG_PATH`、`ERIKA_NATIVE_TARGET`、
`ERIKA_NATIVE_PROFILE=lgpl` 和 Debug 的 `CARGO_PROFILE_DEV_DEBUG=0`。在已应用补丁的
HDR 修复源码上运行（将 `$kernelRoot` 指向自己的源码路径）：

```powershell
cargo test --manifest-path "$kernelRoot/Cargo.toml" --target-dir artifacts/kernel-target --locked --offline --target x86_64-pc-windows-msvc --jobs 2 -p erika --no-default-features --features libass --lib renderer::d3d11::tests -- --nocapture
cargo build --manifest-path "$kernelRoot/Cargo.toml" --target-dir artifacts/kernel-target --locked --offline --target x86_64-pc-windows-msvc --jobs 2 -p erika_capi --no-default-features --features libass
```

2026-11-16：上述 **19 项 D3D11 测试全部通过**，`erika_capi` 构建成功。新增测试使用 WARP
实际执行截图，验证 65×49 输出、RGBA 通道顺序、字幕像素、驱动行间距和 HDR 播放状态保持；
同时覆盖无画面与非法尺寸，已有 HDR 色调映射测试仍通过。补丁的正向及反向应用检查均通过。
另有 2 项暂停字幕 native 回归通过。更新 DLL 后，完整集成 **216 项断言通过**，结果在
`artifacts/player-menus-native-02/results.json`。测试使用真实 3840×2160 HEVC/AAC 视频：暂停
导入字幕改变 94,518 像素，150% 字号改变 213,546 像素；字幕高度由 215 增至 322 像素，
上半画面保持逐字节不变，关闭及重新选择字幕分别恢复原始无字幕帧和 100% 字幕帧。
服务测试还覆盖章节排序/跳转边界、当前片源字幕投影、反向代理与鉴权、下载取消及大小限制、
跨源跳转拒绝和字号持久化。测试数据与用户数据隔离；未通过系统分享向外发送媒体。
最终 WinUI 回归 **75 项通过**，记录在 `artifacts/player-menus-results-final-3.json`，覆盖原窗口
播放与返回、HUD 显隐、菜单完整性与选择生效、章节跳转、独立信息层、分享代次清理和
Windows 色彩枚举。Debug x64 构建为 0 警告、0 错误。实机确认长标题菜单省略且在窗口内展开。

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

页面滚动视口覆盖整个窗口，标题栏浮在内容上方；顶部安全间距随标题栏实际高度更新，
放在可滚动内容内，底部留白也计入滚动范围，避免固定空带裁切页面。媒体库仍使用原生
GridView 的虚拟化与滚动，详情首屏保留标题栏下方的固定操作布局。顶部使用随主题切换的
渐隐遮罩，提高海报背景上的导航、搜索和窗口按钮的可读性。首页“接下来看”显示集数和
剩余时间，不显示进度条；“继续观看”仍显示进度条。

媒体库使用自适应等尺寸海报网格：按窗口宽度分配列数，海报保持 2:3，卡片间距为
24 DIP，标题与副标题固定为单行，超长内容省略并可通过悬停查看全文。
排序入口使用 WinUI 3 原生 `DropDownButton`、Fluent 图标及 `RadioMenuFlyoutItem`。
菜单对照 macOS `888ccdd` 的 `LibrarySort.swift`，分为排序字段、升降序、观看状态三组：
电影和合集支持全部六个排序字段，电视剧不提供时长，其它库保留名称、最近添加和随机；
随机隐藏升降序，切换字段恢复自然默认方向。每个库的选择保存在数据目录的
`library-sort.json`，服务器库通过 Core 在服务端排序及筛选，保留服务端名称次排序。

可单独输出预览构建，保留已运行的应用：

```powershell
dotnet build src/OcPlayer.Windows/OcPlayer.Windows.csproj -c Debug -p:Platform=x64 -p:OcpDemoOnly=true -o artifacts/header-actions-preview-build
./Scripts/start-windows.ps1 -HeaderActionsPreview -BuildDirectory artifacts/header-actions-preview-build
```

直接启动 exe 时加 `--preview-theme=light` 可默认显示浅色。之前的导航预览仍用 `--nav-preview`
或启动脚本的 `-NavigationPreview`。

## 验证边界

Debug 构建也支持 `--demo-verify-player=<绝对 JSON 输出路径>`，验证播放器复用主窗口、全屏恢复、关闭释放、原详情页与滚动位置保留、反复进入/退出，以及 HUD 显隐反向动画、真实闲置计时、暂停/菜单保持、音量静音恢复、标题与时间轴初值。测试使用离线演示数据，源码为 `tests/OcPlayer.Ui/PlayerOverlayVerification.cs`，完成后自动关闭；输出目录需预先存在。`--demo-route=player` 同样使用主窗口覆盖层，可用于 HUD 截图。

Debug 构建支持 `--demo-verify-transitions=<绝对 JSON 输出路径>`，在独立 WinUI 窗口中验证实际透明度插值、路由退场/入场、详情分阶段前景动画、快速导航取消、同路由服务器刷新以及关闭系统动画后的状态恢复。验证完成后自动关闭窗口，结果中的 `passed`、`assertions` 和 `samples` 可用于检查每个阶段；输出目录需要预先存在。测试源码位于 `tests/OcPlayer.Ui/PageTransitionVerification.cs`，仅编入 Debug，不加载 Core 或连接服务器。滚轮事件是否穿过原生滚动控件仍需在详情页面实机检查。

命令行构建覆盖还原、编译和 XAML 生成。真正的播放验证需要带 GPU 和硬件解码器的 Windows 桌面，
包括 HWND/DirectComposition 绑定和媒体键行为。Rust 核心的 `cargo test` 应在本地文件系统的 target
目录运行，不要指向 NAS 挂载卷（不支持 Cargo 增量锁文件）。
