# Windows 弹幕接入

2026-11-16。以 macOS OcPlayer 的 `DanmakuModel`、`DanmakuCoordinator`、
`DanmakuSelectionSheet` 和 `Packages/DanmakuKit` 为参考，Windows 接入共享 Rust Core
的匹配、缓存和格式转换，再交给 Erika 原生弹幕轨道渲染。

## 使用入口

- 打开本地视频、HTTP(S) 片源或 Jellyfin / Emby 剧集后，默认自动匹配弹幕。
- 播放器底部弹幕菜单显示匹配状态、作品、集数和有效弹幕数量；“选择弹幕…”按
  作品列表 → 剧集列表选择，支持作品名、集数和 `SP1` 等特殊集数搜索。
- 手动选择会记住该片源的匹配；“重新匹配”忽略已有选择，重新自动识别。
- 可以加载本地 XML / JSON 弹幕，调节时间偏移；用户偏移以 0.5 秒步进，范围 ±30 秒，
  叠加服务端提供的时间校正。切换片源会清空旧轨道和偏移。
- 设置中的“弹幕”和播放器“弹幕设置…”共用配置，支持自动加载、显示开关、字号、
  不透明度、显示区域、顶部 / 底部 / 滚动过滤、合并重复与允许重叠。

默认使用与 OcPlayer 一致的公共网关 `https://dandanplay.3841625.xyz` 及应用公共额度。
默认字号 22、不透明度 85%、显示区域顶部 75%，合并重复和允许重叠默认关闭。
自定义网关要求 HTTPS，可保留反向代理路径，必须填写自己的 API Key；不会把默认网关
的公共 Key 发给自定义主机。HTTP 仅允许回环地址，用于本地测试。

配置及自定义 Key 整体存入 Windows PasswordVault 的 `OcPlayer.Windows` /
`danmaku-settings` 凭据，不保存到普通 JSON。保存失败保留旧配置；存储不可用或配置
损坏时暂停自动请求并提示重新保存，保持播放器可用。

## 接入路径与补齐的缺陷

`DanmakuService` 提供媒体身份和调用参数。`danmaku.load` 复用 Core 的指纹匹配、
TMDB / 标题与集数回退、候选评分、重试、持久化映射和弹幕缓存；手动搜索通过
`danmaku.exchange` 访问同一网关。成功结果以 `kernelTrack` JSON 交给
`PlaybackSession.LoadDanmakuJson`，不在 WinUI 层重复绘制弹幕。

- 本地缓存身份包含完整路径、大小、修改时间，替换同名文件后不会沿用旧匹配。
  `01.mkv` 等短文件名可从上层目录补剧名和季号。
- 服务器片源携带文件名、大小、时长、剧名、季集号与 TMDB 信息；直接打开单集时，
  尝试补查剧集所属作品。缓存身份使用服务器 / 用户、条目、版本及文件元信息，
  不依赖会变化的签名 URL。无版本信息的直接 URL 不复用片源匹配。
- 远程指纹只读取文件头 16 MiB。先检查 Range 响应、长度与编码，再流式计算 MD5；
  拒绝超大的整文件响应、截断或错误区间。跨域重定向不转发原始鉴权头，HTTPS
  不降级。取指纹失败仍可走元数据匹配。
- 播放器协调器使用取消和代次校验，等待解码器就绪再加载；切换片源、关闭播放器、
  手动选集或本地导入后，过期请求不能修改当前轨道或状态。Core 的 revision
  同时保护持久化匹配，防止晚到的自动结果覆盖手动纠正。
- 无匹配和空弹幕有独立状态；空结果清除旧轨道。网关鉴权、额度、网络和超时错误
  可重试，提示不暴露请求凭据，也不改变视频播放状态。
- 共享 Core 的 `crates/ocp-danmaku/src/filename.rs` 修复了 `S01E01` 中集数与季号
  相同时被错误排除，以及把 `Series.S01E01`、`Dr. Stone` 的点号后缀当扩展名的问题。

缓存保存在 `OCP_DATA_DIRECTORY/Danmaku`，默认位于
`%LOCALAPPDATA%/OcPlayer/Windows/Danmaku`，由 Core 管理有效期和磁盘格式。
本功能关闭自动片头信息查询，避免弹幕请求触发不相关的外部服务。

## 构建与验证

必须带上共享 Core 的上述解析修复并重建 `ocp_ffi.dll`；只复制 Windows C# 源码、
使用旧 Core 二进制不能获得完整修复。当前工作区 `native/OcPlayerCore/x64/ocp_ffi.dll`
已更新。组合构建方式见 [core-integration.md](core-integration.md)。

```powershell
dotnet build OcPlayer.sln -c Debug -p:Platform=x64
dotnet run --project tests/OcPlayer.Integration/OcPlayer.Integration.csproj `
  -c Debug -p:Platform=x64 -- 'D:\path\to\video.mp4' 'D:\path\to\new-results'
```

仅验证弹幕及基础播放生命周期时，在视频路径和结果目录后加 `--danmaku-only`。
默认命令仍运行整个集成套件。
当前标准 x64 Debug 构建通过，0 警告、0 错误，日志为 `artifacts/danmaku-current-build.log`。

集成测试使用真实 Core / Erika DLL、本地 TCP 弹幕网关与带音轨的视频，覆盖匹配、
缓存离线复用与重启恢复、手动纠正、重新匹配、空结果、错误、取消竞态、TMDB 回退、
远程 Range 校验、配置恢复，以及真实渲染、开关、偏移和换源清理。
完整集成检查曾通过 168 项，结果保存在 `artifacts/danmaku-verification-final-3/results.json`。
合并当前匹配标记后，最新弹幕专项 59 项通过，结果和日志分别为
`artifacts/danmaku-verification-focused/results.json`、`artifacts/danmaku-focused-tests.log`。
此时工作区并行新增的原生截图测试在 `VerifyPlayerMenuNative` 报
`capture_frame_rgba has no current video frame for 3840x2160 capture`，因此最新全量运行未通过；
保留失败记录 `artifacts/danmaku-verification-final-4/failure.txt`，未跳过默认套件中的该测试。
Core 的 `ocp-danmaku` 单元测试 23 项通过，包括新增文件名回归用例。

Debug 构建提供 `--verify-danmaku-ui --open=<视频路径>`：使用独立测试凭据、
本地网关与真实播放器，关闭窗口时清理测试凭据。已实机观察到 90 条测试弹幕正常
绘制，手动切换第二集成功，字号调整立即生效。作品 / 剧集两层导航、返回和当前匹配标记
也已实机验证；`Scripts/start-windows.ps1 -Demo` 可正常启动标准输出目录的应用。

验证范围是 Windows x64、本地网关及模拟 Jellyfin / Emby 服务；尚未验证公共网关
实时可用性、真实服务器账号和 ARM64。公共网关额度、内容覆盖和可用性由服务端决定。
