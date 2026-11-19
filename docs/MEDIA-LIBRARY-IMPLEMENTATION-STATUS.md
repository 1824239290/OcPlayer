# 文件媒体库实施进度

日期：2026-11-20。分支：`codex/media-library-single-source`。实施依据：[V3 方案](/Users/jumusu/Documents/project/OcPlayer/docs/MEDIA-LIBRARY-IMPLEMENTATION-V3.md)。原分析报告和 V2/V3 完整保留。

M1 基础代码已提交，本批继续接通 M2 的 macOS 本地目录媒体库。现在可以通过系统目录选择器建库、浏览电影与电视剧、切换来源并使用原播放器；**完整方案仍未完成**，iOS 静态 Core 分发、Windows 应用入口、在线刮削、SMB/WebDAV 尚未接通。

## M1 基础（2026-11-19）

- 新增 `ocp-library` crate，独立 `Library.sqlite` 及版本化迁移。清理服务器缓存不影响其索引、观看事实与匹配快照；数据库损坏时保留原文件并报错。
- 文件源、分类库、条目和资产采用持久 UUID。一个来源可添加互不重叠的电影／电视剧子目录；所有目录查询、详情、播放资源和进度都有来源范围。
- 本地目录后台扫描、持久目录检查点、暂停／取消／恢复、扫描代次和错误状态。目录失败、权限失效、取消不标记文件删除；旧扫描不能覆盖新代次。
- 电影数字片名保护；明确的 S/E、2x03、季目录分集解析；电视剧按剧→季→集→视频资产组织；S0 保留，同一结构内的同集版本共用分集。不同目录的同名剧不按标题直接合并。
- `tmdb.access.validate` 实际请求鉴权配置端点并检查响应结构。建库需要 Core 签发的短期验证与目录凭证；Key、端点或配置代次改变时撤销旧凭证，迟到验证不能重新放行。
- 本地播放地址准备、资产归属／真实路径检查、永久进度写入，旧时间戳不覆盖新记录。自然完成／已看由调用者明确传入，不按 stop 或剩余时长自行推断。
- Swift/C# 文件库 SDK、公开命令清单和 [Core 调用合同](/Users/jumusu/Documents/project/OcPlayer/core/docs/file-library-contract.md)。新接口不依赖原服务器业务的迁移开关。

## M2 应用接入（2026-11-20）

- 登录页与设置的服务器管理页增加统一「媒体来源」入口。文件源和 Jellyfin/Emby 档案保留各自类型，一次只展示一个来源；切换时清浏览投影、失效旧请求并收尾原播放。文件源的 active selection 可跨启动恢复，凭据缺失不阻止已有库打开。
- 添加流程为全局 TMDB 凭据真实验证 → 系统目录选择 → 分类名称／相对目录／电影或电视剧 → 建库及后台扫描。有效验证属于当前草稿，过期或配置变化不能继续创建。现有来源可再添加互不重叠的 Movies／TV 分类。
- `FileLibraryCoordinator` 只包装永久 Core catalog；文件数据不进入 `MediaServer` 或可淘汰的服务器缓存。Apple 书签存于 `LibraryBookmarks.json`，运行时保持授权范围，Core 销毁及扫描 worker 收尾后再释放。失效书签允许重新选择原目录；错目录在保存书签前被拒绝。损坏的书签文件不阻止读取索引，用户重新授权时先保留损坏文件副本。
- 授权与 Rust 使用同样的 `realpath` 规则，处理 macOS `/var` 与 `/private/var` 等别名。不会只凭逻辑路径字符串把原目录误判为其它来源。
- 文件库首页提供分类、继续观看、扫描计数及暂停／继续／取消；分类支持分页搜索；电视剧按整剧 → 季 → 集展开，特别篇保持第 0 季。详情列出原文件及可用状态，支持继续播放／从头播放。
- 文件播放使用原 `PlaybackController`／Erika，携带独立 source/item/asset 身份和 Core 返回的全部请求头。定期、退出、切换、后台与终止时把进度写回原文件来源。打开失败或尚未装载的源不会覆盖进度；完成判据需见到播放、内核停止、已知时长及接近末尾且无失败。现有引擎缺显式 EOF 事件，这仍是有边界的退化判据。
- 新增 `library.query.resume`，只返回当前来源有可用资产且尚未完成／未标已看的电影或单集。Swift/C# SDK 同步提供强类型调用。
- macOS Xcode build phase 自动构建并签名嵌入 `libocp_ffi.dylib`，不打开旧 `OCP_CORE_ENABLED` 迁移开关。iOS 共享页面可编译，但普通 iOS 构建尚未链接静态 Core；能力不可用时禁止添加，不宣称设备端建库已可用。
- TMDB 设置增加移除凭据，并说明已有索引和进度会保留。文件源下不展示服务器补全计数或服务器批量补全操作；当前版本明示在线刮削未开放，海报仍为类型占位。

## 后续尚需实现

| 范围 | 尚需接通 |
|---|---|
| iOS / Windows 添加流程 | iOS 静态 Core 接入、Windows 目录授权／来源选择／分类／浏览／播放；macOS 库编辑与删除等管理操作 |
| 单一来源切换与框架 | macOS 已接通来源边界；文件库暂用独立导航，尚需接入主框架的观影／完整设置分区与统一视觉；其余宿主需沿用同样的来源与收尾规则 |
| 在线刮削 | 持久匹配／元数据任务、电影／电视剧 TMDB 请求、分季数据、人工匹配界面、NFO 解析、图片与离线海报 |
| 播放完善 | 文件字幕、集间连播、明确 EOF 事件、同片电影版本分组、真实视频解码与系统权限真机验收 |
| WebDAV | PROPFIND／路径与 XML、凭据、真实 Range／重定向合同、直连播放／字幕／图片 |
| SMB | libsmb2 三端依赖与 IO、共享目录、本机 HTTP Range 桥接、句柄及播放租约 |
| 发行／平台验收 | macOS 自动嵌入已接通；iOS 静态 Core 分发、Windows 宿主、系统权限与真实视频／NAS 验证 |

能力接口明确返回 `tmdbScraping: false`、`remoteProviders: false`，来源仅放行 `localFolder`，聚合为 false。应用接入阶段应依据真实能力判断可用范围；首版最终仍只做来源切换，不做多来源聚合。

## 已执行的验证

- `cargo test -p ocp-library -p ocp-core -p ocp-tmdb`：82 个用例通过，其中包含临时目录及本机 HTTP 鉴权／创建／扫描／查询／播放准备闭环。
- `cargo build -p ocp-ffi`：macOS 动态库／静态库构建成功。
- 使用本次构建的 `libocp_ffi.dylib` 运行 Swift `OcpFileLibraryTests`：3 个用例通过；实际验证能力检测、目录凭证、无有效 TMDB 凭证不能创建以及 64 位字段。
- 同一动态库运行 `tests/public_command_contract.py`：6 个合同用例通过，本批命令清单增加到 391 个公开命令。
- Clippy 完成，仍有两个新 Store 方法的参数数量提示，以及原 settings backup／测试模块位置提示；没有自动重写无关代码。
- 本批 Rust `ocp-library` / `ocp-core`：65 个用例通过，其中新增继续观看的单集、完成、文件移除与来源边界用例。
- macOS AppTests：18 个用例通过（`FileLibraryIntegrationTests` 7、`AppPlaybackHistoryTests` 7、`ReleaseSessionRegressionTests` 4）。使用真实 Rust 动态库、本机 HTTP TMDB fixture 和隔离临时目录，覆盖验证、同来源电影／TV 分类、S0、扫描、书签跨实例恢复、重新授权／错目录拒绝、清 Key 后读取／播放准备、永久续播、切换服务器与不可用来源不自动换其它档案。文件播放还跨过 PlayerScreen 使用的控制器打开入口，以替身解码器确认续播参数、真实文件路径和切换后的末次进度归属；引擎注册用例串行执行，避免测试偏好串扰。
- macOS Debug 应用构建和 iOS 模拟器共享代码构建通过；macOS 产物实际包含签名后的 Core dylib。布局检查与 `git diff --check` 通过。
- macOS 隔离实例的原生界面检查通过：登录页打开来源选择器、添加入口打开向导、电影／电视剧切换同步分类名称；没有 TMDB 凭据时验证、目录选择、添加扫描按钮均保持禁用。此检查没有填写真实凭据或选择用户目录。
- 本机没有 .NET 10 SDK，C# SDK 尚未编译或运行 Windows 验证。测试使用合成文件，不代表真实视频解码、用户媒体目录／NAS 或真实 TMDB 账户已验收；iOS 源码构建成功也不代表静态 Core 已分发。
