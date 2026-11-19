# 文件媒体库实施进度

日期：2026-11-20。分支：`codex/media-library-single-source`。实施依据：[V3 方案](/Users/jumusu/Documents/project/OcPlayer/docs/MEDIA-LIBRARY-IMPLEMENTATION-V3.md)。原分析报告和 V2/V3 完整保留。

本地文件夹、WebDAV、SMB 与 TMDB 刮削切片已提交，本批接通普通 iOS App 的静态 Core 构建与链接。macOS 与 iOS 共用添加、分类、永久索引、刮削、凭据恢复和来源切换流程；iOS 模拟器已实际验证三类文件源及 SMB／WebDAV 的原播放器起播和 seek。**完整方案仍未完成**，Windows 应用入口、iOS 真机目录权限、真实 NAS 和交付管理完善仍待推进。

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
- TMDB 设置增加移除凭据，并说明已有索引和进度会保留。文件源下不展示服务器补全计数或服务器批量补全操作。M2 初始提交使用类型占位海报，在线刮削在下述 M3 中接入。

## M3 在线刮削与手动匹配（2026-11-20）

- `Library.sqlite` 升级到 schema 2，保留 schema 1 的索引、匹配和观看进度，新增永久刮削队列、逐作品／季的状态与尝试次数、错误类型／下次重试时间，以及季集元数据投影。任务不保存 Key 或 Token。
- 验证有效 TMDB 凭据后，Core 仅在内存持有在线会话。创建分类和重扫会排入刮削队列，等待目录扫描结束后执行；最多两个分类队列同时运行，每队列串行请求。网络不持播放状态锁或 SQLite 写事务。
- 电影按电影端点识别，电视剧先匹配整剧，再下载本地已有季的元数据。已有分集共用季数据，保留 S0；不会把 TMDB 中没有本地视频的集插入可播放目录。后续发现同季新文件时可刷新对应季。
- 继续使用现有 matcher 的 0.85 自动阈值，增加近似并列候选检查；无年份／同名歧义留给人工选择，不直接选第一条。手动绑定写入锁，刷新沿用已选 ID，重扫不覆盖。解除绑定保留文件和进度，同时退休其旧在线任务。
- 文件库专用 TMDB 请求检查候选列表、实体 ID、明确的季号及分集 ID／集号，避免将错误响应写成永久元数据；现有服务器补全保留原有解析语义。
- 清除／修改凭据同步撤销验证并暂停在线工作，迟到回包不能写入。401/403 暂停所有在线队列并禁止继续使用旧凭证新建；网络／5xx／限流按持久时间表重试，队列自动尝试最多三次，随后支持手动重试。底层 HTTP 的 429 退避继续生效。
- 写入校验分类 revision、扫描代次、原始解析输入、资产状态及手动匹配 revision。修复扫描／刮削并发写 SQLite 时读事务升级写锁可能导致漏文件的问题：多语句写事务先取得写锁再读取输入。
- macOS 首页显示独立扫描与刮削计数、暂停／继续／取消／重试；详情可搜索当前电影／整剧类型的 TMDB 候选并手动绑定／解除。标题、年份、简介、季集名称和海报从永久快照读取，删除 Key 后仍可浏览和播放。
- 海报复用 `RemoteImage`／现有图片缓存及 TMDB 图片镜像，使用当前视图的显示倍率做下采样，缓存归属当前文件来源。在线任务变化在文件库导航层观察，进入分类／详情后也会刷新结果；观看进度写入不会重置分类分页。图片仍属可淘汰缓存，稳定离线海报预算尚未实现。
- Swift/C# SDK 和公开命令清单同步新增刮削、候选、手动绑定／解除接口。Apple 依据实际能力开放功能，文件库设置提供刮削语言；用户主动暂停的任务不会因重新打开来源而自动继续。

## M4 WebDAV 接入（2026-11-20）

- 新增 `ocp-webdav`：匿名／Basic／Bearer 连接、`PROPFIND Depth: 1`、DAV 命名空间及成功 propstat 解析，检查 collection、自身目录、64 位文件长度、mtime、ETag。限制响应与条目数量，中文、字面百分号、井号、空格等按路径段保留与编码。
- 拒绝父目录穿越、编码后的路径分隔符、重复路径、外来源 href 和不完整目录响应。扫描复用永久检查点及分类解析；网络／鉴权失败保留旧资产并等待重试，重启后可从失败目录继续。恢复后保留错误计数，显示部分失败，下一次完整无错误扫描才对账删除。
- `Library.sqlite` 升级到 schema 3，原来源、分类、文件、匹配、队列和进度保留，扩展 WebDAV 来源约束并新增 ETag。迁移前后验证 FK 归属，远程根保存规范目录 URL，不走本地 `canonicalize`。ETag 纳入刮削输入版本。
- 首次创建 WebDAV 分类仍需当前草稿的有效 TMDB 验证凭证，并验证／打开实际扫描目录。已有来源单独恢复 WebDAV 连接，清除 TMDB 不阻止索引读取或远程播放。电影、电视剧共用既有刮削队列、匹配界面和海报缓存，S0 与仅本地已有集的规则保持一致。
- macOS 添加页支持本地文件夹／WebDAV 类型选择、鉴权方式、连接验证和逐级远程目录选择；来源页可更新 WebDAV 凭据，同一来源继续添加不重叠的分类。用户名／密码或 Token 存入项目已有的加固凭据文件仓库 `LibraryCredentials.json`（0600、排除备份），Core 只持运行时副本。采用现有仓库方式与 ad-hoc 签名策略一致，未另引入 Keychain 授权弹窗。
- 起播实际请求 `bytes=0-0`，要求 206、正确 Content-Range／长度和一个字节响应。Core 给 Erika 返回仅绑定 127.0.0.1 的随机租约 URL，不把 DAV 凭据交给播放器。桥接支持 HEAD、单段闭区间／开放区间／尾部 Range、416，按最多 4 MiB 上游窗口流式读取及背压，不缓存整部影片；每句柄最多 32 个租约，每租约最多 8 个并发读者。
- 上游最多五次同 origin、同分类根内重定向，拒绝跨 origin、HTTPS 降级、越根或带查询签名的 Location。请求头不由本机请求透传，DAV 凭据不用于 TMDB 或图片 CDN。跨域签名 CDN 跳转暂不支持，需填写可直接读取视频的最终 WebDAV 地址。
- `PlaybackResourceLifetime` 在播放请求、重试／后台重开和 Erika 原生 presenter 间共享。资源直到 `erika_presenter_destroy` 完成后才释放，避免 UI 退出、换片或取消在飞 open 提前关闭本机地址；销毁 Core 时取消并收尾所有扫描／读取线程。
- Swift/C# SDK、公开命令清单与 Core 合同同步新增远程访问、浏览、凭据恢复及播放租约释放。文件来源仍只有一次一个 activeSource，无聚合、无伪造服务器、无 Jellyfin／Emby 播放上报。

## 后续尚需实现

| 范围 | 尚需接通 |
|---|---|
| iOS / Windows 添加流程 | iOS 普通 App 静态链接与模拟器闭环已接通；仍需 iOS 真机目录授权／File Provider 验收、Windows 目录授权／来源选择／分类／浏览／播放，以及库编辑与删除等管理操作 |
| 单一来源切换与框架 | macOS 已接通来源边界；文件库暂用独立导航，尚需接入主框架的观影／完整设置分区与统一视觉；其余宿主需沿用同样的来源与收尾规则 |
| 识别与元数据完善 | NFO 解析、更丰富的文件名／绝对集号规则、同片电影版本分组、题材筛选、稳定离线海报保留预算 |
| 播放完善 | 文件字幕、集间连播、明确 EOF 事件、同片电影版本分组、长视频／系统权限与真机验收 |
| WebDAV 完善 | 真实 NAS／长视频 seek 与断网恢复、签名 CDN 资源解析、外置字幕／本地图片、地址迁移和完整管理 |
| SMB 完善 | 真实 NAS 的 SMB3 加密／权限／断网重开、长路径、DFS／Kerberos、自动发现共享及完整管理 |
| 发行／平台验收 | macOS 自动嵌入与 iOS 自动静态链接已接通；iOS 设备版 Release 构建通过，仍需真机运行／目录权限、Windows 宿主与真实视频／NAS 验证 |

能力接口明确返回 `schemaVersion: 4`、`tmdbScraping: true`、`remoteProviders: true`，来源放行 `localFolder`、`webdav` 与 `smb`，聚合为 false。应用接入阶段依据真实能力判断可用范围；首版最终仍只做来源切换，不做多来源聚合。

## 已执行的验证

- `cargo test -p ocp-library -p ocp-core -p ocp-tmdb --locked`：93 个用例通过，其中包含临时目录、本机 HTTP 鉴权／创建／扫描／刮削／查询／播放准备闭环，以及 v1 元数据／进度迁移、手动锁与迟到回包、S0、并发写入、401 与 5xx 重试。
- `cargo build -p ocp-ffi`：macOS 动态库／静态库构建成功。
- 使用本次构建的 `libocp_ffi.dylib` 运行 Swift `OcpFileLibraryTests`：3 个用例通过；实际验证能力检测、目录凭证、无有效 TMDB 凭证不能创建以及 64 位字段。
- 同一动态库运行公开命令、TMDB wire 与 matcher 合同：15 个用例通过（6／5／4），公开清单为 400 个命令。已有服务器 TMDB 数值／响应兼容和评分策略未被文件库严格校验改变。
- Clippy 完成，文件库仍有原两个 Store 方法的参数数量提示，其他提示属于已有模块；没有自动重写无关代码。`cargo fmt --check` 通过。
- macOS AppTests：19 个用例通过（`FileLibraryIntegrationTests` 8、`AppPlaybackHistoryTests` 7、`ReleaseSessionRegressionTests` 4）。使用真实 Rust 动态库、本机 HTTP TMDB fixture 和隔离临时目录，覆盖验证、同来源电影／TV 分类、S0、自动刮削、缺年份时手动选择、清 Key 后永久详情／播放、书签跨实例恢复、重新授权／错目录拒绝、永久续播、切换服务器与不可用来源不自动换其它档案。文件播放还跨过 PlayerScreen 使用的控制器打开入口，以替身解码器确认续播参数、真实文件路径和切换后的末次进度归属；引擎注册用例串行执行，避免测试偏好串扰。
- macOS Debug 应用构建和 iOS 模拟器共享代码构建通过；macOS 产物实际包含签名后的 Core dylib。布局检查与 `git diff --check` 通过。
- M2 的 macOS 隔离实例原生界面检查通过：登录页打开来源选择器、添加入口打开向导、电影／电视剧切换同步分类名称；没有 TMDB 凭据时验证、目录选择、添加扫描按钮均保持禁用。M3 通过构建和上述宿主集成用例验证，尚未用真实账户检查海报加载及手动匹配的原生操作流程。
- 本机没有 .NET 10 SDK，C# SDK 尚未编译或运行 Windows 验证。测试使用合成文件，不代表真实视频解码、用户媒体目录／NAS 或真实 TMDB 账户已验收；iOS 源码构建成功也不代表静态 Core 已分发。

## M4 验证记录

本批使用本机 DAV／TMDB HTTP fixture 和隔离临时数据库，验证中文特殊路径、多个 propstat、64 位大小、外来源／越界拒绝、206／Content-Range、同来源重定向、跨来源鉴权陷阱、4 MiB 窗口和尾部读取、资源释放、已有匹配与观看进度跨重启、电影／电视剧／S0 分类和失败目录跨重启续扫。Apple 用例生成三秒 ffmpeg 视频并使用真实 liberika presenter 打开及 seek，不再仅使用替身解码器验证远程准备。

- Rust：99 个用例通过（Core 47 单元＋3 基础集成＋6 刮削集成＋2 WebDAV 集成；Library 2 解析＋17 catalog；TMDB 18；WebDAV 1 Range＋3 XML／路径）。旧数据库用例同时验证真实 schema 1 与 schema 2 升级。
- macOS AppTests：20 个通过（FileLibraryIntegrationTests 9、AppPlaybackHistoryTests 7、ReleaseSessionRegressionTests 4），含真实视频 Range 起播和 seek、凭据文件权限及恢复、文件请求身份、原服务器进度回归。
- Erika 原生资源生命周期用例：1 个通过，确认失败 open／close 后仍保留租约，直到 native presenter 销毁才释放。
- iOS 模拟器共享代码构建通过；普通 iOS 仍缺静态 Core 分发，不能宣称设备端 WebDAV 可用。
- Swift 文件库 SDK 3 个用例、公开命令／TMDB wire／matcher 合同 15 个用例通过，公开命令清单 404 个。`cargo fmt --check`、Clippy 和仓库校验通过；Clippy 保留 Store API 参数数量及已有模块的提示。macOS 嵌入动态库签名校验通过。
- 性能诊断：细分计时及进程采样确认长等待在测试 Python 读取仓库脚本时发生。现将共享 fixture 同步嵌入测试代码、通过 `python -c` 在后台执行，使测试无需读取 Documents 项目目录；原 `.py` 完整保留，`sync-webdav-test-fixture.py --check` 检查两者一致。最终新增宿主闭环约 0.39 秒，服务启动约 84 毫秒、Core 打开约 5 毫秒、TMDB 验证约 25 毫秒、播放准备约 6 毫秒、liberika 打开与 seek 约 89 毫秒。测试服务不属于应用播放链路。
- 未使用真实 NAS／TMDB 账户或 Windows 宿主验收；真实服务的跨域签名播放地址目前明确拒绝。

## SMB 接入（2026-11-20）

- 新增 `ocp-smb`，完整保留并锁定 libsmb2 6.2 上游源码、许可证及归档 SHA-256，通过 `cc` 构建私有静态依赖。构建副本补上目录／数据包大小限制、损坏目录项检查与 MinGW 兼容；原始上游代码不修改。适配层使用异步 API，不调用同步网络等待，也不创建脱离 Core 生命周期的 C worker。
- SMB 来源为 `smb://主机[:端口]/共享名/`，支持共享下的根目录、用户名／密码、可选域、访客、要求签名及要求 SMB3 加密。默认密码模式要求签名；服务不满足所需加密时连接失败。来源 URL 不包含凭据，首版需手动填写共享名，不做自动发现或系统挂载。
- 新增访问验证、逐级浏览和原来源凭据恢复接口；首次添加仍需当前草稿的有效 TMDB 回执，并实际打开所选分类目录。来源内的电影／电视剧目录不可重叠，路径保留中文、空格、字面 `%`、`#` 和 `&`，拒绝目录穿越、NTFS 流和尾部点／空格别名。
- `Library.sqlite` 升级到 schema 4，只扩展 SMB 来源约束，保留本地／WebDAV 原身份、分类、资产、元数据、队列和观看进度，并验证外键。SMB 扫描复用永久检查点、解析器与刮削队列；失败目录保留旧资产，跨重启明确继续，曾失败的扫描以部分失败结束，完整无错误重扫才进行删除对账。
- 新增 `ocp-resource`，SMB 与 WebDAV 共用本机播放租约和 Range 桥接。每个 SMB HTTP 请求持有独立连接／文件句柄，按偏移读取，单次原生读取最多 256 KiB，桥接窗口最多 4 MiB；起播、重开读者及每个窗口前后核对长度和文件身份／时间版本。变化或断连中止当前读取，用户重新打开生成新快照，未实现透明自动重连。
- 播放器关闭本机 HTTP 连接、seek 丢弃旧读取或租约释放时，取消对应远程等待并关闭句柄。沿用 Erika 原生 presenter 销毁后才释放租约的规则。文件播放和续播仍归原来源，无 Jellyfin／Emby 会话或上报，无多个来源聚合。
- macOS 添加页提供 SMB 类型、共享地址、域／访客／签名／加密设置和分类目录浏览；来源页支持更新连接与继续添加分类。凭据使用已有 `LibraryCredentials.json` 仓库，创建前重新读盘确认数据及 0600 权限；写入失败会提示重试。清除 TMDB 后仍能读取旧索引，并在文件源可访问时播放。
- Swift/C# SDK、公开清单和调用合同同步更新。底层 libsmb2／适配层已编译 macOS arm64、iOS arm64、Windows x64 GNU 静态库；iOS 尚未分发静态 Core，Windows Rust／.NET 宿主链接与应用流程尚未验收，这一步不代表三端功能全部可用。

## SMB 验证记录

- Rust 全套相关用例 108 个通过：Core 48 单元＋3 基础＋6 刮削＋2 SMB＋2 WebDAV；Library 2 解析＋18 catalog；TMDB 18；SMB 1 路径＋4 协议；共用 Range 1；WebDAV XML／路径 3。实际 schema 1／2／3 数据库升级后保留身份、匹配和进度，FK 检查通过。
- 本机固定 `impacket==0.13.0` 协议服务覆盖签名／域、访客、错误密码、权限拒绝、共享／目录缺失、中文特殊路径、5 GiB 稀疏文件、四个并发随机读取、文件变化、取消、SMB2 服务拒绝所需 SMB3 加密，以及目录失败后跨重启续扫。此服务不能替代真实 NAS 或 SMB3 加密互操作验收。
- 连接创建／销毁增加独立生命周期锁，保护 libsmb2 未加锁的全局连接链表；网络读取不持此锁。新增八线程、每线程三轮目录／文件读取和连接收尾回归，避免扫描与播放分别在不同线程建立连接时破坏链表。
- macOS AppTests 21 个通过、无跳过（文件媒体库 10、历史 7、会话回归 4）。新增 SMB 用例生成三秒视频，经过真实 liberika presenter 起播和 seek，并验证凭据保存／重启恢复、租约、独立文件身份及原服务器回归。
- `verify-smb-native.py` 使用项目同一构建逻辑编译三种目标的 C 静态依赖；iOS 模拟器共享页面构建通过。Swift 文件库 SDK 和公开命令／TMDB wire／matcher 合同沿用实际 FFI 库校验；公开清单更新到 407 个命令。
- 原分析／V3 方案、libsmb2 原始源码和测试 `.py` 完整保留。SMB AppTest 同步嵌入 Python fixture，`sync-smb-test-fixture.py --check` 验证一致，避免运行时读取仓库脚本。未进行真实用户 NAS、TMDB 账户、iOS 真机或 Windows 应用验收。

## iOS 静态 Core 接入（2026-11-20）

- 源码 Swift 包新增仅在 iOS 使用的 `NativeFFI` 系统模块，直接导入原 C ABI 头并引用全部 12 个函数。macOS 沿用内嵌动态库；外部 SDK 使用的完整 XCFramework 打包脚本继续保留。
- 普通 iOS Xcode target 增加 `build-ios-static.sh` 构建阶段，在链接前按平台／架构构建 Rust 和 SMB C 依赖，生成静态 `libocp_ffi.a`，放入当前构建产物目录。支持 iOS arm64、模拟器 arm64／x86_64 与 Debug／Release；多架构模拟器库使用 lipo 合并。无需向 iOS App 复制 Core 动态库，也不打开原服务器业务的迁移开关。
- 既有文件媒体库页面依据实际 Core 能力开放本地文件夹、SMB、WebDAV 添加和电影／电视剧分类。TMDB 创建前置、全局共用凭据、已有索引离线可读、单一 active source、文件进度独立和禁止服务器上报的规则沿用原实现。
- 补齐 iOS 局域网权限说明和 Release CI 的 Rust 目标安装。iOS 打包脚本随原播放器／SwiftPM notices 保留 Core 和锁定 libsmb2 的许可证与来源说明。
- 普通 iOS AppTests 改为使用静态链接产物，并拒绝注入的旧 Core 动态库；检查同时支持 Xcode 的 App Debug image 和普通 Release executable。保留已安装 Rust targets 的正常构建方式，Homebrew Rust 可通过显式 `OCP_CORE_BUILD_STD=1` 使用 rust-src 构建标准库，不修改全局工具链。
- 新增可在 iOS 宿主内运行的 TMDB／WebDAV HTTP fixture，以及 29 KiB 的三秒合成 MP4。SMB 继续使用完整保留的共享 Python 协议 fixture，由 Mac 宿主启动后向模拟器只传入回环地址；不要求 iOS 启动 Python 或 ffmpeg。

## iOS 验证记录

- iOS 27.1／iPhone Duo 模拟器：**20 个用例通过，0 失败，0 跳过**（文件库基础 6、跨平台闭环 2、SMB 宿主 fixture 1、观看历史 7、原会话回归 4）。本次使用普通 App 静态 Core，没有注入 Core dylib。实际验证电影／电视剧／S0、仅本地已有集入库、永久元数据／续播、清除凭据后的读取与新建拦截、SMB／WebDAV 凭据跨实例恢复，以及真实 Erika presenter 起播和 seek。
- SMB 用例经 libsmb2 与真实 SMB2 协议服务读取中文／特殊字符文件，并完成刮削、重开连接和播放。DAV 用例还验证 Core Range 返回的实际文件字节。这是协议 fixture 验证，不等于真实 NAS 或 SMB3 加密互操作验收。
- macOS 新增跨平台用例：2 个通过、无跳过；Swift 文件库 SDK：3 个通过。继续确认 macOS 动态库接入和已有公开 Swift API 可用。
- iOS arm64 设备版 Release 构建通过；模拟器 arm64／x86_64 通用 Debug 构建通过。三种架构的 App code image 均检查到全部 12 个 Core ABI 函数，未依赖独立 `libocp_ffi.dylib`。设备版目前仅完成构建／链接，未进行真机运行。
- `test-ios-file-library.py` 提供可复现的 20 用例运行，读取 xcresult 后要求零跳过。独立运行 SMB 宿主用例而未提供 fixture 时会明确跳过，不能作为 SMB 覆盖成功。日志与 xcresult 保存在 `artifacts/verification/ios-static/` 和 `artifacts/verification/file-library-ios/`。
- Xcode 工程、shell／Python 脚本语法、仓库布局与 diff 检查通过。本批不改变 Rust 公共命令合同，清单仍为 407 个命令。原报告、V3 方案、原始图片／代码与 libsmb2 全部原文件保留。
