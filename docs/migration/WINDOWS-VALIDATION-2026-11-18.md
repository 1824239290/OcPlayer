# Windows 合仓追加验收（2026-11-18）

Windows x64 本机追加验证通过。此次发现并处理了 Git 深目录检出的长路径限制，以及主窗口关闭后主题回调访问标题栏导致的崩溃。修复后的浏览回归连续两次正常退出，包含修复的自包含 MSI 也通过了独立解包启动检查。

源码基线为 `720e4add068050f5677070a656a3e8b28eb9dd51`。其 Core 和 Windows 源码树与已通过完整 CI 的 `c4f53462115f52df47023e629e8766e3ea841ee6` 相同，CI 记录见 [Actions 44161047381](https://github.com/1824239290/OcPlayer/actions/runs/44161047381)。本次另外修改 `apps/windows/src/OcPlayer.Windows/MainWindow.xaml.cs`；这是本机追加修复，尚未提交或推送，不能将此前 CI 描述为已验证这份新修复。

修复文件的 Git blob 为 `5cb6050bf34060b106373afe5b352970d6c9114b`，SHA256 为 `64c0b29303dce6226e52833426e816af4ba43d8bf0e73e7cfa97ae228e91000a`。本机证据位于 `artifacts/verification/windows-audit-20261118`，机器可读汇总为 `summary.json`，源码差异为 `window-close-fix.patch`。

验证环境：Windows `10.0.26300` x64、.NET SDK `10.0.404`、Rust `1.99.1`、Visual Studio 2022 Build Tools。liberika 仍使用固定 v0.3.7 / `a4f829999fe8df0c35561fe1bdf0f5ad0df0c3a5`。

| 检查 | 结果 | 本机证据（相对上述证据目录） |
| --- | --- | --- |
| 历史、导入树、绑定唯一性及迁移守卫 | 通过 | `layout.json`、`fresh-layout.json` |
| 根入口与路径回归 | 47 项执行，46 通过、1 项真实 macOS 签名用例按平台跳过 | `root-tests.log` |
| Rust workspace | 217 项通过，0 失败、0 忽略 | `core/rust-tests.log` |
| Windows C# SDK | mock、缺失导出、实库均通过；实库 31 个检查、3 组合同 | `core/runtime-results.json`、`core/sdk-mock.log`、`core/sdk-missing.log` |
| Python C ABI / HTTP / 领域合同 | 218 项执行，216 通过，0 失败、0 错误，2 项独立 Apple URLSession probe 用例跳过 | `core/runtime-results.json` |
| 原生 Core / Erika 与 WinUI Release | 通过；C# / XAML 0 警告、0 错误 | `native-release-build.log` |
| Debug UI 构建及修复后的 Release 自包含发布 | 通过；托管编译无警告或错误 | `debug-ui-after-fix-build.log`、`fixed-msi-build.log` |
| 中文深目录全新检出及 Release / 集成项目编译 | 通过；编译 0 警告、0 错误 | `fresh-longpaths-clone.log`、`fresh-release-build.log`、`fresh-integration-build.log` |
| 存储、设置、备份恢复、迁移 | 124 条断言通过 | `fresh-storage/results.json` |
| 服务器、鉴权、OAuth、浏览、字幕 fixture | 351 条断言通过 | `fresh-server/results.json` |
| 完整本地 / HTTP 播放、暂停、跳转、字幕、弹幕、截图、续播、销毁 | 397 条断言通过 | `fresh-full/results.json` |
| 真实 WinUI 原生播放器 / MoviePilot | 分别 29 / 21 条断言通过 | `native-ui/results.json`、`moviepilot-ui/results.json` |
| 修复后的媒体库浏览 | 两次独立运行，各 22 条断言通过，进程退出码均为 0 | `ui-after-fix/browser-ui.json`、`ui-after-fix-repeat/browser-ui.json` |
| 修复后的播放器覆盖层 / 页面动画 | 分别 86 / 19 条断言通过，进程退出码均为 0 | `ui-after-fix/player-ui.json`、`ui-after-fix/transitions-ui.json` |
| 修复版 x64 自包含 MSI | 构建、元数据、原生 DLL 哈希、独立解包启动均通过 | `fixed-msi/release.json`、`fixed-msi-verification.json`、`fixed-msi-runtime.json` |

原生构建使用本仓库的 `core` 和已准备的固定内核源码，复用本检出的 Cargo / 原生依赖缓存。全新检出中的原生 DLL 来自这次重新构建，并携带同一源码的 receipt；没有使用原分仓库的 DLL。全新检出的 Core SDK、集成项目均重新编译。窗口关闭修复作用于 WinUI 主窗口，Core、SDK 和上述集成测试输入与该基线相同。上游 Erika 保留 3 条非致命 Rust 警告。

播放输入是已核对 SHA256 的 70 秒合成 MPEG4 / FLAC / SubRip 样本，文件名含中文和空格。实际解码与音频输出计数大于零，渲染和音频错误计数为零；暂停后截取的 65×49 RGBA 帧包含有效视频像素。`native-ui/app-overlay-paused.png` 用于检查 XAML HUD 和弹幕；SwapChainPanel 视频由原生截图 `fresh-full/captured-frame-65x49.png` 另行验证。

**此次处理的问题**

Git for Windows 默认路径限制使深目录克隆在一个保留的历史 Swift 文件处报 `Filename too long`，其相对路径长 181 个字符。README 的 Windows 克隆命令改用 `git clone -c core.longpaths=true ...`，开发文档说明已有检出的仓库级配置。新目录以这项配置完整检出，迁移守卫、编译和三组集成测试通过；首次失败日志保留在 `fresh-clone.log`。

浏览 UI 首次运行完成 22 条断言后，关闭窗口触发晚到的 `ActualThemeChanged`，在 `MainWindow.SetCaptionTheme` 访问已不可用的标题栏，进程以 `0xC000027B` 退出。修复在 `Closed` 开始时设置关闭状态并解除主题订阅，主题回调也检查关闭状态和可用标题栏。外层验证同时检查结果 JSON 与进程退出码，首次 JSON 的 `passed=true` 未被误计为整体通过。原错误日志保留在 `browser-ui-data/Logs/diagnostics.jsonl`，修复后的两次浏览及播放器窗口关闭均正常退出。

**修复版安装包**

`fixed-msi/OcPlayer-1.0.0-x64.msi` 的 SHA256 为 `DDBB53998E45B3281F4771EE0A256CC9E02239C0CF42AC82675367336A8F7475`，内含 Windows 程序集的 SHA256 为 `54C933A2C0B19B4E97F417CE9935F1B7C0BD83E8148730E0A557F24524937910`。版本为 `1.0.0`，随包 CRT 为本机 `14.44.35211.0`，UpgradeCode 沿用既有值。

通过 MSI 管理解包获得实际载荷，在独立数据目录、无效 `DOTNET_ROOT` / `DOTNET_ROOT_X64`、清空 Core 库覆盖及精简 PATH 的条件下启动 apphost。WinUI、Core、Erika 正常初始化；`coreclr.dll`、`Microsoft.UI.Xaml.dll` 和 Visual C++ 运行库从载荷目录加载，`msvcp140.dll` 也随包存在。载荷中的 Windows 程序集与打包输入相同，两份原生 DLL 的哈希与 receipt 相同。

本机已有正式 MSI，因此本次检查采用独立解包启动，前后已安装产品注册列表一致。此次未重跑安装、升级、卸载流程；测试包未安装、签名或发行。ARM64、真实外部服务器账号、长时间影片与完整 HDR / Dolby Vision 输出组合也未在本轮实测，平台跳过项均未计为通过。

本次代码和文档修改保留在合仓工作区，两个远端主分支尚未切换。此前完整 CI 证明与这次本机修复证据分别保留。
