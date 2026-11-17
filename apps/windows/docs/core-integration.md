# Windows / Core 组合构建

2026-11-15，Windows 前端开始默认使用真实 Core。现在三端在 OcPlayer 单仓库维护：Windows 的
`OcPlayer.CoreAdapter` 直接编译引用 Core 的 C# SDK 源码，不再保存一份手工复制的绑定代码，
所有生成输出留在 `apps/windows` 组件内。下列组件命令从 `apps/windows` 运行，根入口见 [统一开发说明](../../../docs/DEVELOPMENT.md)。
Rust Core 负责业务、播放状态和 SQLite 进度；Windows 适配器把实际解码事件反馈到 Core，
Erika 负责 FFmpeg 解码、WASAPI 音频、字幕 / 弹幕与 D3D11 渲染。

## 构建与运行

默认目录：

```text
OcPlayer/core/
OcPlayer/apps/windows/
```

内核版本固定在 `Config/Kernel.version.json`：官方 `AimesSoft/liberika` 的 **v0.3.7**，
提交 `a4f829999fe8df0c35561fe1bdf0f5ad0df0c3a5`。准备 Windows LGPL 原生依赖：

```powershell
.\Scripts\prepare-kernel.ps1 `
  -KernelCargoHome 'D:\path\to\cargo-cache' `
  -NativeArchiveCache 'D:\path\to\native-archive-cache'

.\Scripts\build-windows.ps1 `
  -KernelRoot '.\artifacts\liberika-v0.3.7' `
  -LibClangPath 'D:\path\to\llvm\bin' -Configuration Release
```

准备需要 Visual Studio C++ 工具、Git Bash 或 MSYS2、GNU make、nasm、CMake，以及可运行
`venv` 的 Python；meson/ninja 可由上游 xtask 自动安装。`-NativeArchiveCache` 可省略。
准备脚本拉取固定提交并应用本仓库的 `liberika-v0.3.7-windows.patch`，再使用上游 xtask
构建 FFmpeg 8.1.2（包含 dav1d）、libass 0.17.5 和字体依赖。Windows 构建脚本使用
`--locked`，生成独立的 `artifacts/core-target`、`artifacts/kernel-target`，将两枚 DLL
放入 `native/OcPlayerCore/x64`，然后编译前端。`-CoreRoot`、`-Configuration Release`、
`-KernelCargoHome` 和 `-Offline` 可按环境指定；`-SkipNative` 复用已生成 DLL。
`-SkipManaged` 只构建原生部分，便于在更新正在运行的界面之前验证新 DLL。
上游更名后 DLL 名和 C ABI 函数前缀仍是 `erika_capi` / `erika_*`。
Debug Rust 构建保持未优化，但关闭原生调试符号，避免本机 MSVC C7 调试记录对 ring 编译命令的拒绝；
C# Debug 符号正常生成。原生依赖本身的编译警告保留在构建日志中。

Windows 构建脚本检查固定提交与版本化补丁，在 receipt 中记录仓库、tag、提交、编译特性、
补丁和 DLL 的 SHA256。补丁保留 D3D11 的 SDR 截图、暂停时字幕导入/切换和同步删除字幕。
旧的网络回退缓冲、HDR/Dolby Vision 接口已由上游实现，不再应用 0.1.7 的旧补丁。
内置回退字体、ArtCNN R8F64 与 libass 一起编译；WinUI 使用原生 D3D11 渲染。
许可证页由实际源码版本和当前平台的依赖自动生成。
原 0.1.7 补齐记录保留在 [补齐收尾报告](parity-completion-2026-11-16.md)。

运行已生成的应用（脚本自动定位本机 .NET，包括安装在用户目录里的 SDK）：

```powershell
./Scripts/start-windows.ps1
```

开发启动脚本与直接运行 EXE 均默认使用 `%LOCALAPPDATA%/OcPlayer/Windows`，
首次通过新脚本启动会导入旧 `artifacts/app-data` 的持久数据并保留原目录。
可传 `-DataDirectory 'D:\path\to\data'` 指定独立目录。迁移、运行库与 MSI
验收见 [发行说明](release-windows.md)。

也可以运行 exe：

```powershell
$env:DOTNET_ROOT = 'C:\path\to\dotnet'
$env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
& .\src\OcPlayer.Windows\bin\x64\Debug\net10.0-windows10.0.26100.0\OcPlayer.Windows.exe
```

`--open=<完整文件路径或HTTP(S)链接>` 可在启动时打开片源；用 PowerShell 传入带空格的路径时，
将完整参数包在单引号中。`--demo-route=home` / `--demo-route=player` 启用原来的离线 Demo。
Core SDK 的 `OCP_CORE_LIBRARY_PATH` 可覆盖 Core DLL；MSBuild 的 `OcpNativeDirectory` 可覆盖
原生 DLL 输入目录。没有 DLL 的纯 UI 编译使用 `-p:OcpDemoOnly=true`。

## 已连接的路径

- 默认启动创建共享 Core，检查 ABI / ping；关闭应用时释放资源。
- 本地文件 / HTTP(S) 链接打开真实播放器，支持暂停、前后跳转、拖动时间轴、音量、静音、倍速和全屏。
- `SwapChainPanel` 绑定原生 DirectComposition swap chain，尺寸和 DPI 变化传给 Core 与原生渲染器。
- 实际媒体时长、解码时钟与轨道列表反馈到 UI / Core；播放器菜单可切换真实音轨、关闭字幕、加载外挂字幕和本地弹幕。
- 弹幕已接通自动匹配、手动搜索选集、持久化纠正与缓存、远程文件指纹、外观设置和时间偏移，使用 Erika 原生渲染。实现及验证见 [DANMAKU-INTEGRATION.md](DANMAKU-INTEGRATION.md)。
- 每五秒、暂停和停止时通过 Core 保存进度；重开片源或重启 Core 可恢复。失败的打开操作不会被记为已播放完成。
- 点击顶部“连接服务器”、打开媒体菜单或设置中的媒体服务器入口，登录 Jellyfin / Emby；令牌由 Windows PasswordVault 保存，重启自动恢复所选服务器。
- 连接表单支持 IP / 域名 / 端口和反向代理路径，省略协议时使用 HTTP。手动选择 Jellyfin / Emby，登录并验证媒体库后才切换会话；错误保留表单供重试，45 秒超时，可取消。
- 切换服务器前保留已有会话，保存凭据成功后再激活新服务器。可断开连接；从显式 Demo 登录成功会进入真实模式。海报请求携带认证，首页部分失败显示对应栏目；媒体库失败保留现有片库。
- 首页、媒体库搜索 / 排序 / 观看筛选、详情、分季分集和播放地址使用 Core 命令。网络加载具有取消与代次校验。
- 服务端播放 start / progress / stopped 顺序上报；应用退出给正在进行的上报最多五秒收尾，随后由 Core 取消未完成的请求。

默认本地数据位于 `%LOCALAPPDATA%/OcPlayer/Windows`。`OCP_DATA_DIRECTORY` 可指定独立测试目录。
最近媒体 JSON 只保留本地文件，不落盘签名 URL 或鉴权头；服务器令牌由系统凭据库保存。

## 验证

本机 Windows x64 构建已通过，C# / XAML 无警告、无错误，25 项集成断言全部通过。运行可重复的集成检查：

```powershell
dotnet run --project tests/OcPlayer.Integration/OcPlayer.Integration.csproj `
  -c Debug -p:Platform=x64 -- 'D:\path\to\video.mp4' 'D:\path\to\new-verification-directory'
```

输入应为带音轨、至少一分钟的本地视频。测试在独立数据目录里使用真实 Core / Erika DLL，
通过本地 TCP HTTP fixture 检查服务器登录、媒体库、分季、播放 URL 与顺序上报，
检查真实解码、暂停、跳转、倍速、音量、轨道、尺寸变化、句柄销毁、续播和缺失文件。
连接检查覆盖地址规范化、错误账号、登录取消、拒绝读取媒体库、Emby 反向代理路径、
首页部分失败和图片鉴权。使用独立测试凭据资源验证 PasswordVault 替换、重启恢复和断开；测试结束移除测试凭据，不修改应用账号。
`results.json` 保存断言数量与渲染 / 音频计数，失败时保留 `failure.txt`。

本次使用本机 Unicode 路径下的《凡人修仙传》文件。记录见
`artifacts/verification-complete-final/results.json`、`artifacts/integration-tests-final.log` 和
`artifacts/managed-build-final.log`。真实 WinUI 窗口已观察到视频与 HUD 同时显示，时长为 19:16。

服务器连接补齐后的 25 项结果见 `artifacts/server-connection-verification-pass/results.json`。
实机点击标题栏的账号区域已确认可以打开连接表单，地址、类型、用户名、密码和按钮均正常显示。

这次验证覆盖本机 x64 和本地 HTTP fixture。尚未验证真实 Jellyfin / Emby 账号、所有服务器版本、
ARM64、完整影片稳定性和所有 HDR / Dolby Vision 输出组合。Bangumi、MoviePilot 与观影统计的后续接入、
验证及剩余边界见 [VIEWING-INTEGRATIONS.md](VIEWING-INTEGRATIONS.md)。TMDB 设置、
配置备份 / 诊断导出等页面仍待逐项接入；离线 Demo 继续保留这些页面供 UI 对齐。
本段为早期接入验证记录；后续分页与 MSI、自包含运行库的现状见 [发行说明](release-windows.md)。发行签名需提供代码签名证书。
