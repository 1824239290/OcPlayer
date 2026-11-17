# 功能补齐收尾与验证报告

已接续上一段对话中断的功能补齐工作，完成统一构建、真实媒体集成测试和 WinUI 页面回归，并修复验证发现的字幕删除竞态。原审计的 **298 条编号记录及 6 条播放器交互差异**仍作为固定基线保存；实现入口分别记录在 [浏览/详情](parity-browsing-progress.md)、[播放器](parity-player-progress.md)、[设置/弹幕](parity-settings-progress.md)、[Bangumi/MoviePilot/观影空间](parity-integrations-progress.md) 进度表中。

“实现已落盘”和“动态测试通过”分别记录。测试断言数与审计条目数没有一一对应关系，以下结果不意味着每个真实服务、显示器和媒体格式都已完成实机验收。

## 本轮修复

- **外挂字幕删除**：native 原来仅将删除命令放入播放 worker 队列；前端紧接着读取轨道列表，可能取得仍含被删字幕的旧列表，使默认选轨重新选中它。现在删除会等待 worker 完成并发布轨道状态，错误也返回调用者。适配器随后同步 Core 的字幕选中状态。
- **回归覆盖**：验证选中字幕的即时删除、Core 选中状态清空、删除另一条字幕时保留当前选中轨，以及连续删除后保留原有轨道。断言直接检查删除调用后的 native 列表，没有使用延时重试掩盖旧列表。
- **应用层弹幕验收**：新增 Debug 专用原生窗口验证入口，使用真实 swap chain、解码器和 DispatcherTimer，覆盖本地 XML、暂停、前后 seek、字号/透明度/屏蔽、换片清理、下一片源改用内核渲染和本地 JSON。
- **设置与集成页面验收**：实际构造并渲染网络、播放、TMDB、维护、关于和许可页面；检查全部缓冲/字幕/保留时间/主题/画质选项。Bangumi 页面 fixture 按实际 `/users/.../collections/...` 请求返回账号状态，并核对收藏和评分控件的选中值。

字幕修复作为 [player-subtitle-removal.patch](../Scripts/patches/player-subtitle-removal.patch) 保存。构建脚本会在截图和缓冲补丁后检查/应用它；原生 receipt 记录三个补丁及两枚 DLL 的 SHA256。该补丁反向检查通过，并在隔离目录正向重放，与实际构建源码一致（比较时统一 Windows/Git 行尾）。

## 当前通过结果

| 验证 | 结果 | 证据 |
|---|---|---|
| 原生 Core + Erika 重建 | 成功 | [native build log](../reports/continuation-native-build-20261116b.log) |
| Debug 前端构建 | 0 警告、0 错误 | [Debug build log](../reports/continuation-debug-build-delivery-20261116.log) |
| Release 前端构建 | 0 警告、0 错误 | [Release build log](../reports/continuation-release-build-20261116.log) |
| Debug 集成测试工程构建 | 0 警告、0 错误 | [integration build log](../reports/continuation-integration-build-20261116b.log) |
| 完整真实媒体/本地协议集成 | **341 条断言通过** | [results.json](../reports/continuation-full-integration-20261116b/results.json) |
| 原生播放器、应用层弹幕与设置 UI | **29 条断言通过** | [results.json](../reports/continuation-ui-native-delivery-20261116/results.json) |
| 观影空间/Bangumi/MoviePilot UI | **14 条断言通过** | [results.json](../reports/continuation-ui-viewing-final-20261116/results.json) |
| 浏览与详情 UI | **18 条断言通过** | [results.json](../reports/continuation-ui-browser-final-20261116.json) |
| 主窗口播放器/HUD/菜单 UI | **86 条断言通过** | [results.json](../reports/continuation-ui-player-final-20261116.json) |
| 页面切换、详情返回与动画 | **19 条断言通过** | [results.json](../reports/continuation-ui-transitions-final-20261116.json) |

共 **341 条集成断言、166 条 UI 断言**。完整集成使用本地 90 秒视频，覆盖真实音视频解码、SDR 原生截图、外挂字幕缩放/关闭/重选/删除、内核弹幕、暂停/seek/倍速/音量、进度重启恢复、失败片源不记录完成，以及服务器播放报告的顺序。HTTP fixture 覆盖服务器分页/缓存/多账号、Bangumi/OAuth/章节状态、MoviePilot 筛选与状态、TMDB 补全/批量取消、备份恢复、日志、更新及字幕下载。

原生重建保留现有 Rust/链接警告，未抑制警告；日志中有 Erika 的 14 条 Rust 警告与 CAPI 链接库冲突警告。上表的“0 警告”仅指对应 .NET 构建。Debug 和 Release 前端此次均引用经过验证的 Debug native DLL，receipt 明确记录其 configuration；未发布安装包。

## 复现与运行

默认依赖目录为 `D:/OcPlayer-Core`；原生 DLL 位于 `native/OcPlayerCore/x64`。已有验证 DLL 时：

```powershell
dotnet build OcPlayer.sln -c Debug -p:Platform=x64 --no-restore
dotnet build tests/OcPlayer.Integration/OcPlayer.Integration.csproj -c Debug -p:Platform=x64 --no-restore
dotnet tests/OcPlayer.Integration/bin/x64/Debug/net10.0-windows10.0.26100.0/OcPlayer.Integration.dll '<本地视频完整路径>' reports/new-full-verification
./Scripts/start-windows.ps1
```

集成测试输出目录应新建，避免已有进度改变测试的初始条件。原生播放器 UI 验证仅编入 Debug：设置独立 `OCP_DATA_DIRECTORY`、使 `DOTNET_ROOT` / `DOTNET_ROOT_X64` 指向本机 .NET，再运行 exe 并传入 `--verify-native-player=<新输出目录>` 和 `--open=<本地视频路径>`。该入口使用独立凭据资源和本地 fixture，退出时清理测试凭据。

其余 Debug UI 入口：`--verify-viewing=<目录>`、`--demo-route=home --demo-verify-browser=<JSON文件>`、`--demo-route=home --demo-verify-player=<JSON文件>`、`--demo-verify-transitions=<JSON文件>`。各进程使用独立数据目录，测试结束后自行关闭。

## 验证边界

- 真实外部账号的配对、收藏、订阅、下载删除与播放同步仍需对应服务的实际账号验收；本轮没有向真实外部账号提交这些写入。
- SMTC 的创建、标题/暂停状态和关闭释放已通过真实 Windows API 验证；系统媒体面板发出的物理按键、Narrator、物理长按与自动重复仍属专项交互实测。
- 60 秒网络开片 watchdog、实际 HDR/Dolby Vision 画质、ArtCNN 各 GPU 后端及不同解码格式仍需相应网络/硬件/媒体环境。没有将 SDR 视频回归或配置档位测试等同于这些验收。
- R-080 的裸路径、文件/协议激活处理已实现；固定基线未证实原版有完整安装文件关联，故安装后“默认应用/双击文件”关联不计为已完成验收。

旧失败记录保留用于追溯；本报告链接的 `passed=true` 文件是当前结论。最终源码、原生 receipt 与测试结果清单见 [交付快照](../reports/parity-completion-20261116-manifest.json)。
