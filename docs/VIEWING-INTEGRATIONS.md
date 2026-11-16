# Windows 观影与集成

实现参考 macOS `888ccdd` 的 `MyHomeView`、`MyViewingStatistics`、
`ServerViewingHistory`、`AppPlaybackHistory`、Bangumi 和 MoviePilot 页面。

## 使用

- 设置 → Bangumi：点击「使用浏览器登录 Bangumi」，自动共用「设置 → 弹幕」中的网关地址和
  API Key（需有 `bgm:oauth` 权限），默认配置无需另行填写。也保留个人 Access Token 登录。
  网关须配置回调 `ocplayer://oauth/callback`；应用密钥只在网关，Windows 不持有 `client_secret`。
  使用 `Scripts/start-release.cmd`（Release x64）或 `Scripts/start-windows.ps1` 启动。
  脚本按构建内容复制完整输出到 `%LOCALAPPDATA%\OcPlayer\Windows\Runtime\<平台>\<配置>\<SHA256>`，
  再运行该目录中的 EXE 并预先注册回调。文件继承普通用户运行目录权限，避免开发目录的低完整性
  标记影响浏览器和注册表访问；不会修改原目录或 Windows 安全设置。构建变化使用新目录，
  不覆盖正在运行的程序，数据仍默认保存在工作区 `artifacts/app-data`。
  CMD 入口仅对本次 PowerShell 进程指定脚本执行策略，不更改系统或用户策略。
- 设置 → MoviePilot：填写服务器根地址（支持反向代理子路径）、账号与密码，验证后保存令牌。
  密码不落盘；两个集成的令牌由 Windows PasswordVault 保管。
- 首页搜索框左侧选择媒体库、Bangumi 或 MoviePilot；默认只搜索媒体库。
- 观影页可进入 Bangumi 片单、完整日历、条目/章节，以及 MoviePilot 订阅、资源与下载管理。
  停用集成后对应观影模块、搜索来源和详情入口隐藏，配置仍保留。
  观影空间采用居中的 920 DIP 内容区，头像与账号信息紧凑显示；标题栏右侧的更多菜单提供
  Bangumi 章节管理、Bangumi 个人主页、MoviePilot 资源管理和数据来源设置，旁边的图标刷新当前页面。
  每日统计、待看/在看片单、类型分布和七日趋势与活跃度、月度柱图组成两列半透明卡片；
  最近观看和续播使用统一列表，订阅与下载并排显示。窄窗口自动改为单列，深浅主题使用独立卡片底色。
  日期和月份选择在刷新时保留，轮询及失败刷新保留已有列表内容。
- Bangumi 章节管理使用整行进度卡：小海报、中日文标题、右上收藏菜单、进度和下一集快捷操作，
  下方直接显示章节。长篇以第一集未看章节为中心显示最多 50 集；单击切换看过/未看，
  右键修改状态或批量「看到此集」，未播章节不能操作。动画和三次元按每类 30 条分页读取。
- Bangumi 个人主页依次展示动画、游戏、书籍、音乐和三次元，状态按钮显示各自数量，
  默认优先在看，其次看过，再选择非空状态。海报栏每次读取最多 12 条，点击分类标题进入对应片单。
  片单保留参考截图的大海报网格和五状态分段选择，在标准窗口显示四列，窄窗口自动减少列数，
  每页 20 条；筛选切换后旧响应不会覆盖当前结果。搜索使用服务端结果，标题栏提供分类过滤。
- Bangumi 条目详情使用顶部海报概览、收藏/评分菜单、MoviePilot 下载入口、章节和等高作品信息网格。
  章节分本篇、SP 和其他；作品信息支持数组及键值内容。评分可撤销，刷新保留服务端最新收藏状态。
  介绍全文在独立可选中文本弹窗内展示，不改变详情页滚动位置。标签和全站收藏人数在下方显示。
  标题栏图标按钮及下拉菜单使用 WinUI 控件。
- 竖版海报位优先使用 `poster` / `poster_path`，Bangumi 接口使用 `images.large` 等封面字段，
  不使用背景图或通用 `image` 替代。观影空间的服务器分集续播和观看记录读取所属剧集 Primary 海报，
  避免将分集剧照裁成竖图。测试截图使用竖版 Primary 海报资源。

这些页面同时参考本机 macOS 源码 `D:/OcPlayer/OcPlayer/App/Shared/Features/Bangumi/` 下的
`BangumiHomeView.swift`、`BangumiProfileView.swift`、`BangumiCollectionListView.swift`、
`BangumiSubjectDetailView.swift`、`BangumiEpisodeCell.swift`，以及 BangumiKit 的 `progressWindow`。
片单网格与详情区块顺序按本次截图保留，和当前 Swift 源码中的片单行列表、简介优先顺序有所区别。

## 其他入口

- 资源下载前明确选择归属媒体。下载请求原样传递媒体与种子 JSON，保留 TMDB、豆瓣等来源编号。
  搜索结果的 `meta_info` 仅是资源识别信息，不当成 `media_in`。
- 影片详情第二页可以按当前标题搜索 Bangumi 或 MoviePilot。
  Bangumi 栏将关联作品与标题放在同一行，右侧图标刷新章节，更多菜单提供自动匹配及重新关联。
  本篇和其他章节直接分组显示为双行按钮，已看章节突出底色和边框，未播章节禁用；点击已播章节
  可选择未看、想看、看过、抛弃，本篇还支持批量「看到此集」。章节较多时横向滚动。

## 观影语义

- `browse.played` 分页读取服务器已看电影/分集。首次导入最近 30 个日历日，之后保持固定起点；
  每个条目保留最新完成快照。未标日期、远期日期不进入日期统计。
- 完整扫描才原子替换归档，失败、取消或被新扫描取代时保留上次结果。
  源身份包含服务器类型、服务器 ID（旧配置回退至地址身份）和用户 ID。
- App 按实际播放的墙钟时间累计，不以拖动后的播放位置算时长；暂停、停滞、跳转、休眠间隔不计入。
  解码器低频回报进度时不会因高频绘制而少算；跨本地午夜拆分到两天。
- 同一来源、条目、日期的 App 实播优先于片长估算；多个播放片段累计。
  片单和下载不是观看记录，不能增加已看数量。已看数量以服务器完成状态为准。
- 归档在数据目录 `ViewingHistory` 下，只有显示元数据与时长，不保存播放 URL、鉴权图片 URL 或令牌。
  Core 继续独立拥有续播位置；新增归档不替代 Core 的播放进度。
- 观影页提供每日统计、可点击的 15 周活跃度、月度时长柱图、类型分布、最近观看和续播。
  放送筛选在看、仍放送且库内可用的条目；公开 `bangumi-data` 提供本地时区时间，缓存六小时。
  不可用时保留旧数据，无时刻时回退 Bangumi 的星期，不伪造具体时间。

所有 Bangumi/MoviePilot/Jellyfin 业务请求通过共享 Core。Windows 仅承担凭据、页面生命周期、
显示投影和与 macOS 对应的观影归档。公开放送数据下载不附带任何账号凭据。

## 验证

```powershell
dotnet build src/OcPlayer.Windows/OcPlayer.Windows.csproj -p:Platform=x64 -p:OutputPath=D:/OcPlayer-Windows/artifacts/viewing-build/
dotnet build tests/OcPlayer.Integration/OcPlayer.Integration.csproj -p:Platform=x64 -p:OutputPath=D:/OcPlayer-Windows/artifacts/viewing-tests/
./artifacts/viewing-tests/OcPlayer.Integration.exe --server-only artifacts/viewing-verification-final
```

`ViewingVerification.cs` 使用真实 Core DLL 与本地 HTTP/SSE fixture，测试登录、分页、原始下载载荷、
凭据持久化、停用、失败登录保留原会话、历史去重/回滚、跨天、暂停/跳转与低频解码进度。
凭据使用唯一测试资源并在结束后清理。

Debug 参数 `--verify-viewing=<绝对输出目录>` 打开独立测试窗口，使用隔离凭据和固定服务响应，
验证十个页面及停用隐藏行为，并输出页面截图和 `results.json`。运行时需设置 `DOTNET_ROOT` /
`DOTNET_ROOT_X64`，并为 `OCP_DATA_DIRECTORY` 指定独立测试目录。
该验证也覆盖详情页 Bangumi 章节分组、未播禁用、批量观看状态回写、刷新图标和窄窗口横向滚动，
输出 `detail-bangumi-dark.png`、`detail-bangumi-light.png` 和 `detail-bangumi-compact.png`。
观影空间 fixture 还提供多日/跨月观看记录与本地 HTTP 海报，验证片单入口、续播条目、订阅原始载荷、
下载入口、四个更多菜单路由、热力图日期选择、月份切换、刷新保留选择以及失败刷新后恢复。
输出 `dashboard-dark-full.png`、`dashboard-dark-lower.png`、`dashboard-light-full.png` 和
`dashboard-compact-full.png`，这些截图使用隔离数据，不是用户账号的数据。
`BangumiPagesVerification.cs` 覆盖四个 Bangumi 页面：章节切换/撤销与下一集、未播禁用、
改变收藏后移出在看、主页分类与状态切换、片单分页与快速筛选、搜索分类、详情评分撤销/刷新、
作品信息等高及数组解析、MoviePilot 路由和简介弹窗滚动位置。四页分别输出 `bangumi-*-dark-full.png`、
`bangumi-*-light-top.png` 和 `bangumi-*-compact.png`，同样使用本地 HTTP 海报和隔离数据。

2026-11-16 四页改版验证：Debug UI 检查 30 项通过，见
`artifacts/bangumi-pages-20261116-220459/results.json`；包含既有观影空间及影片详情内嵌 Bangumi 回归。
服务器浏览检查 45 项通过，见 `artifacts/bangumi-poster-verification/results.json`，
验证了分集卡片使用所属剧集 Primary 海报、电影保持自身海报。

本轮不等同于真实 Bangumi/MoviePilot 部署联调；未验证公网令牌过期、各站点资源差异或 ARM64。
Bangumi 自动匹配/播放进度自动回写、完整高级订阅筛选与走势图仍未达到全部 macOS 功能对等。

## Bangumi OAuth（Windows）

- 与 macOS 使用同一组网关接口：`GET /v1/bangumi/oauth/authorize?state=…`、
  `POST /v1/bangumi/oauth/token`（`code`）、`POST /v1/bangumi/oauth/refresh`（`refresh_token`）。
  路径从网关根开始，鉴权是 `X-API-Key`，User-Agent 以 `OcPlay/` 开头；不附带 Bangumi Bearer。
- 点击浏览器登录时，为当前 Windows 用户注册 `ocplayer` URL 协议。系统浏览器授权后启动一个
  只处理回调的短进程，经当前用户专用、按随机 state 隔离的命名管道转交给原窗口，然后退出。
  回调进程不会初始化 Core 或打开第二个媒体窗口。开发环境注册命令保留 .NET 运行时绝对路径。
- state 只存于本次登录内存；严格检查 scheme/host/path、唯一参数、授权地址和回调 state。
  取消、离开页面、十分钟超时、重复回调、旧窗口回调均不能发布凭据。
- 换取令牌后成功读取 `next.<根域>/p1/me` 才原子替换原账号。
  `p1` 条目、搜索、章节、片单及章节写入使用 Next；`v0` 账号、条目收藏读写和放送日历使用 API。
  官方与镜像保持相同规则。取消、拒绝授权、网络失败或资料读取失败均保留原连接。
  新登录、停用及退出会使在途旧响应失效。
- 提前 60 秒刷新将到期的令牌；并发请求共享一次刷新，401 后最多刷新重试一次。
  上游未轮换 `refresh_token` 时保留旧值，未返回有效期时与 macOS 一样按一周处理。
  临时网关故障保留凭据；明确拒绝刷新时清除令牌并停用会话，保留网关配置供重新授权。
- 访问令牌、刷新令牌及网关 API Key 一起存入 Windows PasswordVault，不写入日志、观看记录或普通配置文件。
- `BangumiOAuthVerification.cs` 通过真实 Core 和本地网关 fixture 验证授权、刷新及竞态；
  `ViewingPageVerification.cs` 还实际启动独立回调进程，验证管道转交和进程退出。
  OAuth 单元/集成 fixture 不访问用户的真实 Bangumi 账号或网关。
  `--oauth-browser-only` 验证系统浏览器实际请求本地 HTML，再通过当前已注册的 `ocplayer` 协议
  启动构建中的回调处理程序，验证命名管道、令牌交换与账号校验。运行前通过启动脚本注册当前构建，
  并设置 `OCP_OAUTH_APP_ASSEMBLY` 为运行目录中的 DLL。

本次 OAuth 验证：x64 Debug 应用构建通过（零警告、零错误），111 项集成断言通过；
UI 验证通过独立回调进程、十个页面及停用隐藏共 12 项检查。
本地结果分别见 `artifacts/oauth-verification-2/results.json` 与
`artifacts/oauth-ui-verification/results.json`。

2026-11-16 浏览器启动修复验证：x64 Release 构建零警告、零错误；直接运行
`Scripts/start-release.cmd` 后，应用完整性为 Medium（8192），运行目录中 170 个文件与构建内容一致。
Windows PowerShell 5.1 和 PowerShell 7 准备同一构建会复用同一运行目录。
系统浏览器实际加载本地 HTML、系统注册协议激活回调、真实 Core 交换 fixture 令牌等共 38 项断言通过，
见 `artifacts/bangumi-final-protocol-verification/results.json` 与
`artifacts/bangumi-staged-protocol-verification/launcher-results.json`。
实际网关授权地址已在浏览器加载 `bangumi.lat/login`；账号登录和用户授权由用户完成，
此检查不代表真实账号已连接。

账号校验后续修复：旧请求 `https://api.bangumi.lat/p1/me` 实际返回 HTTP 200，
但 JSON 为 `{"request":"/p1/me","code":404,"error":"Not Found"}`，导致账号校验失败。
OAuth 资料请求现使用 `https://next.bangumi.lat/p1/me`，并识别 HTTP 200 中的 API 错误码。
回归测试将 API 与 Next 分为独立的 HTTP fixture，API 的 p1 路径返回同样的错误；
覆盖官方域名、镜像、非默认端口、Bearer 传递、资料保存、错误保留旧账号及手动令牌登录，
共 69 项 OAuth 断言通过，见 `artifacts/bangumi-profile-verification/results.json`。
