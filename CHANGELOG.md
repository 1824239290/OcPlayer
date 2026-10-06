# Changelog

项目变更记录。未发布内容集中在 `[Unreleased]`，提交前应同步更新用户可见行为和验证入口。

## [Unreleased]

### 改动

## [0.2.1] · 2026-10-06 · 设置页重构为 hub 首屏 + 子页、TMDb 元数据补全、内核换装官方 v0.2.1

### 改动

- **播放内核升级到上游 `v0.2.1`**（fork/上游 commit `70f12bf`）。上游 release 见「AimesSoft/Erika」v0.2.1，与本 App 相关的变化：
  - **资源回收**：关闭、切换媒体和 seek 时取消旧的网络读取；销毁播放器时等待后台 worker 退出、释放连接与线程；`stop()` 释放 HTTP 缓存与队列占用（保留从头重播能力）。
  - **预读窗口**：修复预取跨越条带边界后继续读取的问题，预读窗口按配置生效（`v0.1.9+dolby.streaming.fix` 里「预取窗口无界」那条线的延续）。
  - **解码**：恢复硬件解码不可用时的软件回退（WMV/WMA、8/10-bit AV1）；修正 P010 插值，保留完整信号精度。
  - **iOS 弹幕/字幕同步**：内核新增 `erika_presenter_render_tick_with_timing` C API——传入「到显示目标时间的延迟」（如 `CADisplayLink.targetTimestamp - CACurrentMediaTime()`），弹幕、字幕与渲染上下文按同一显示目标采样播放快照，渲染繁忙时同步更稳。**本版本仅升级 vendored 二进制与 `erika.h`，App 侧仍走 `render_tick`，尚未接入新 API**（旧内核缺该符号时上游要求可选解析、回退 `render_tick`，接入时同理做可用性探测）。
  - **C ABI 纯新增**：`erika.h` diff 仅有新枚举值 `LinuxExtendedLinearScRgb`、新函数 `render_tick_with_timing` 与 Linux 专用的 `copy_flutter_frame_rgba`；`ErikaOpenOptions` / `ErikaPresenterConfig` 布局未动，App 侧零适配。
  - 钉点：`Config/Erika.version` → v0.2.1，新增 `Scripts/erika-v0.2.1.sha256`（两包哈希与 release 自带 `SHA256SUMS` 一致）。
  - 验证：`Packages/ErikaKit` 全量 30 测试（离屏渲染 / C ABI 冒烟 / 真文件打开 / HTTP 直连 / 播放生命周期 / 内存快照 / 预读行为，CI 因无 GPU skip 的套件本地全跑）全绿；macOS App 测试全绿；iOS 模拟器 **349** 测试全绿；其余 SPM 包全绿。
- **弹幕字号改为百分比调整（±10% 步进）**。HUD 弹幕菜单的「字号」原为 4 档单选（小 / 标准 / 大 / 特大），现改为与字幕「字体大小」一致的**减小 / 重置 / 加大**，根行直接显示百分比（22pt = 100%）；步进取基准的 10%（2.2pt，连加时百分比始终落在整数档），范围放宽到 **50%–200%**（11–44pt，边界正好落在整档位上）。存储键与格式不变（原始像素 Double），旧档位值无需迁移。
- **设置页重构为「hub 首屏 + 子页」**。原先单页 11 组约 65 行（iPhone 要滚 5~6 屏），TMDb / MoviePilot 配置得越全越长；现在一级页收成 4 组 11 行导航行，每行带**当前值预览**（Jellyfin 服务器名 / Bangumi 账号 / MoviePilot 登录态、播放内核、弹幕加载方式、首页栏目数、TMDb 启用态、版本号），不进子页就能看到现在什么状态；说明文字全部随功能进各自子页。
  - **子页**：播放（含内核）/ 首页栏目 / 弹幕 / 网络 / Jellyfin / Bangumi / MoviePilot / TMDb 元数据补全 / 维护 / 关于。`@AppStorage` 状态随功能迁移到子页（互相不再牵连失效）；更新检查随行进关于页、MoviePilot profile 刷新随行进子页。
  - **hub 子页路由走 `Route.settingsSubpage`（path 驱动）**而不是 `navigationDestination(isPresented:)`：子页还会再推叶子页（Jellyfin 页推「管理服务器」、关于页推「开源许可证」），isPresented 页面不在 path 上，祖先要 `coveredByPresented` **逐层登记**才不会透过半透页面漏底；path 驱动的页面由 `appRouteView` 统一挂 `coveredPageHidden / routeExitFade / pageEntrance`，整条链自动处理。叶子页（不再下推别的页面）保留原 isPresented 模式。
  - **破坏性操作全部补确认**（原先全部点了立即执行）：退出 Jellyfin / Bangumi / MoviePilot、清空图片缓存、清空媒体元数据缓存、清除 TMDb 补全数据、清空日志。
  - **iPhone 调优**：首页栏目上下移按钮热区 44×44（原先挤在 2pt 间距里误触率高）；TMDb Key 输入改纵排（行内 SecureField + 按钮会被键盘顶住）；`.roundedBorder` 仅 macOS 生效（iOS grouped 行内原生样式是无框）；值预览统一 `.lineLimit(1)` 中间截断。首页栏目排序沿用按钮方案（grouped Form 的 onMove 在 macOS 无入口，双端一致的刻意选择，未改）。
  - 验证：macOS（`Scripts/build-macos.sh`）与 iOS（`OcPlayer-iOS` scheme）编译通过，`OcPlayerTests` 全绿；iPhone 模拟器装 Debug 构建、真实会话下 `OCPLAYER_START_SECTION=settings` 截图确认 hub 一屏放下、值预览正确、氛围图透明行底保留。
- **TMDb 元数据补全（`Packages/MetadataKit/TMDb`）**。用户自填 API Key 后，详情页可用第三方元数据补充**简介、评分、类型、演员与海报/背景图**；未配置 key 时整个功能禁用、不发任何请求、不影响现有行为。
  - **匹配优先级**：服务端 `ProviderIds["Tmdb"]` 直连（置信度 1.0，不搜索）→ 标题+年份搜索兜底。搜索按六档打分，只有 **≥0.85**（标题精确 + 年份相符）才自动落库——**错误的匹配比没有匹配更糟**：用户看到的是别人的剧情简介和海报，而且显示得像真的一样。低置信度的候选只留给手动匹配面板（Phase 3）。
  - **实测查清一个陷阱**（本机 Jellyfin 12.1.0，`Fields=ProviderIds` 才返回）：剧级 `Tmdb=153217` 是**剧集 id**；季级**只有 Tvdb、没有 Tmdb**；集级 `Tmdb=3384539` 是**单集 id**。所以**集与季绝不能拿自己的 `tmdbID` 去查 `/tv/{id}`**——那是单集 id，会拉到另一部剧或 404。二者一律从**父剧**的对应推导为 `tv/{剧id}/season/{季号}`，判断收在 `TMDbEntityKey` 的唯一入口里，并有用例钉住（断言「绝不能拿单集 id 当剧集 id 用」）。父剧对应不存在时（用户直接从「继续观看」点进某一集）会先建起来。
  - **语言逐字段回退**：TMDb 不做回退——`language=zh-CN` 时没有中文翻译的字段返回**空串**（不是 nil）。所以判定用「非空」而非 `??`（用 `??` 会把空串当有效值，英文永远补不上），且**只补缺、不整包替换**（否则中文标题会被英文顶掉）。字段齐全时不多打那一次请求。
  - **季一次拿全**：`/tv/{id}/season/{n}` 一次返回整季全部集，不是每集一个请求——这是控制配额的关键。
  - **v3/v4 密钥都收**：`eyJ…`（v4 Read Access Token）走 `Authorization: Bearer`，32 位 hex（v3 API Key）走 `api_key` 查询参数。用户从 TMDb 设置页复制哪个都行，不该要求他先分清 v3/v4。v4 路径下 URL 里不含 `api_key`（有用例断言）。
  - **主动限流**：actor 令牌桶（并发 ≤4 + 最小间隔 120ms）。官方口径是「约 50 req/s 且必须尊重 429」，而批量补全一整个库很容易瞬间打出几百个请求——主动限流而不是等被拒再退避。429 尊重 `Retry-After`。
  - **两张表分开**（`tmdb_entity` / `tmdb_link`），因为生命周期不同：实体数据是**全局的**（同一部电影对谁都一样，故不带 `tenant_id`，两个服务器档案共用一份、省一次请求；只有**语言**让它分叉，故语言进主键）；对应关系是**每台服务器各自的**（条目 id 是服务端生成的）。分开的另一个好处：解绑/重匹配只动 link，不必丢掉已拉下来的实体数据。迁移是 v2 **纯加表**，v1 的老缓存全部有效（有用例断言）。
  - **叠加层不改写 `MediaItem`**（`TMDbOverlay`）：服务端数据是「当前事实」，TMDb 是可选增强。若混进同一个结构，「关掉 TMDb」就得把改过的字段改回去——而那时已不知道原值是什么。独立结构让「关掉」=「不再叠加」，天然可逆。
  - **文本与图片策略分开**：文本可以整份换语言；图片是否顶替已有图另有开关（**两者默认都是「TMDb 优先」**，见下面那条改默认值的说明）。分开的理由是「谁的图更好」没有客观答案——用户用刮削器精修过的海报被 TMDb 顶掉是**单向损失**，必须留一个关掉的出口。TMDb 图免鉴权，故取到 TMDb URL 时**不带**服务端认证头（给 CDN 发 Jellyfin 凭证既无意义、也多送一处）。
  - **失败不删旧数据**（404 例外）：旧数据比没有强，这正是缓存优先的价值。404 那个 id 在 TMDb 不存在，留着只会每次白查一遍。
  - **缓存期硬夹在 6 个月内**（默认 90 天）：TMDb 条款禁止缓存超过 6 个月，那是 ToS 约束不是工程取舍，所以不留给调用方自行放宽。
  - **合规**：设置页与 `OpenSourceLicensesView`「社区数据与服务」分组各有一份署名（`本产品使用 TMDb API，但未获得 TMDb 认可或认证。`），后者附条款链接。
  - **季与分集的补全**（用户实测反馈「分集可以用每集的标题和描述」「切季后描述没更新」）：分集/季虽然没有自己的详情页，但 TMDb 数据在**剧集页**上有三处展示面——分集卡片标题、分集简介（悬停提示）、以及**选中某季时的页面简介**。现在都会用上：
    - **分集标题优先 TMDb**。服务端对没有元数据的分集常给「第 9 集」这种占位名（实测库里就有），而 TMDb 有真标题（如「离别之时」）。占位名**无论文本开关如何都会被顶掉**——那不是用户的元数据，是服务端没数据的表现。
    - **切季更新简介**：选中某季时优先显示该季简介，**取不到回落剧集简介**（不少季在 TMDb 上没有简介，直接替换会让整段文字凭空消失）。
    - 季数据靠「父剧的对应 + 季号」定位（季没有自己的 TMDb id），入口收在 `seasonOverlay(seriesLink:seasonNumber:)` / `refreshSeason(...)`；未过期不重复回源（切季是高频操作）。
  - **图片策略默认改为「TMDb 优先」**（用户口径：「填了 key 就是想要完整补全，能用 TMDb 就用」）：海报 / 背景 / **分集剧照**三处都优先用 TMDb 的图，服务端已有的会被顶掉。仍保留一个开关——「谁的图更好」没有客观答案，用户用刮削器精修过的海报被顶掉是单向损失，必须留一个关掉的出口。
    - **分集剧照**接上了 TMDb 的 `still_path`（此前取到但没用）：服务端缺剧照时能补，默认策略下即便服务端有也以 TMDb 为准。
    - 踩到一个「同一个概念两个默认值」的坑：`TMDbImagePolicy.init` 的默认与 `TMDbPreferences.replaceExistingImages` 的默认一度不一致（前者 false、后者 true），于是「生产路径 TMDb 优先、测试里默认只补缺」，用例直接失败。已对齐并在注释里写明。
    - 验证：`Packages/MetadataKit` 98 用例全绿；**实机**确认 TMDb 图缓存 21 → 35（新增 13 张 w500，正好是 13 集剧照）。
  - **两个踩过的坑**（都写进注释与文档）：
    1. 季数据**不能**在 `.task(id: selectedSeasonID)` 里取——那个 task 在页面初现时就跑一次，而那一刻 `seasons` 还是空的（诊断日志：与 `/Seasons` 请求同一秒、`selectedSeason` 为 nil），之后 id 变化**并没有再触发它**。改为由 `load()` 末尾确定性地触发（那时 seasons 与父剧对应都已就位），视图 task 只负责用户切季。
    2. 占位集名判定**不要用 `\d`**——实测 ICU 的 `\d` 会匹配中文数字（「九」被判为 true），于是「第九集」这种真实标题会被误判成占位名、被 TMDb 顶掉。改用 `[0-9]`，且中日文形态只锚**结尾**（服务端还有「我的朋友很少 - S01E00 - 第 0 集」这种文件名派生形态）。
  - **提交前 review 又抓出 7 处问题**（用户要求先 review 再提交）：
    1. **设置页「已补全条目」恒显示 0**：`refreshTMDbLinkCount()` 定义了却**没有任何地方调它**——看着像功能没生效。已在区块出现时取一次（实机确认显示 4，与库里 4 条对应一致）。
    2. **坏 key / 连不上完全静默**：用户填了 key、翻了几页、什么都没发生，只会以为功能坏了。现在补全服务记录最近一次失败，设置页把它翻成可读原因（「API Key 无效或已被 TMDb 拒绝」/「连不上 TMDb（检查网络或代理）」…）。`notFound` 刻意不提示——那是服务端 `ProviderIds` 脏数据，用户无法处理。
    3. **权威来源没被用上**：`TMDbLinkSource.isAuthoritative` 定义了却没人读。现在「当初靠标题搜索猜的对应」在服务端后来补上 `ProviderIds["Tmdb"]` 时会改用权威 id——否则会永远抱着一个猜出来的 id（实测库里确实有「先入库无 id、后补元数据」的条目）。权威对应本身仍不会被自动匹配顶掉。
    4. **`year(fromTitle:)` 定义了却没用**：现在接到搜索兜底——服务端没给 `year` 字段但标题里带年份（「某片 (2019)」）时会带上年份过滤，避免同名作品混在一起打分。
    5–7. **三处死代码**：`refreshEpisodeOrSeason`（已被 `refreshSeason` 取代，App 层不可达）、`refreshSeason(tvID:seasonNumber:)`、`TMDbImageSize.poster/.still`、`TMDbOverlay.hasText` —— 全部删除。它们都有同一个毛病：**看起来接好了、其实没人调**。
    - 顺带发现并修掉**我自己造成的重复定义**（`seasonOverlay`/`refreshSeason`/`refresh` 在 `TMDbEnricher` 里各存两份）——python 脚本改文件时重复应用了。已做一次全量同名声明自查确认无残留。
    - 验证：`Packages/MetadataKit` **118 用例**（+7）；`OcPlayerTests` 340 全绿；其余包全绿；macOS + iOS 构建通过；实机确认设置页计数与两个开关默认值正确。

### 库级批量补全与手动匹配

  - **库级批量补全**（设置页「补全整个媒体库」）：逐条匹配并拉取，剧集**连同各季一起补**（季数据决定分集标题/剧照/切季简介，只拉剧集本身的话那些展示面在没访问过的剧集上仍是空的）。带进度条与四类分类计数（新补 / 跳过 / 匹配不上 / 失败）——混成一个「成功 N 条」的话，用户不知道剩下那些该怎么办：「匹配不上」要他去手动匹配，「失败」要去看网络。可随时取消。
    - **天然可续**：已有对应且未过期的条目直接跳过，所以「取消 / 退出 App 之后再点一次」不会重复打请求，也不会丢进度——**进度状态就是数据库本身**，不需要额外的断点记录。
    - **单条失败不中断**：整库补全里有一条网络抖动就整体中断，会让用户以为「补全失败了」而重跑一遍全部。
  - **手动匹配面板**（详情页头部 TMDb 图标旁的循环箭头）：自动匹配刻意只在置信度 ≥ 0.85 时落库（错误的匹配比没有更糟），代价是总有条目匹配不上——冷门番、译名差异大、服务端没有 `ProviderIds` 又搜不到。面板打开即用条目标题搜一次，选中即绑定（`source: .manual`，**不会被自动匹配覆盖**）并立刻拉数据；也能**解除匹配**（匹配错了必须能取消，否则一个错误的自动匹配会永远顶在那儿，还会阻止重新自动匹配）。
  - **顺手修掉一个「列表接口不返回 ProviderIds」的坑**（Phase 3 实测发现）：`/Items` 列表接口**默认不返回** `ProviderIds`（实测本机 Jellyfin 12.1.0：不带 fields 时 0/5 个条目有，而 `/Items/{id}` 默认就有）。而 `MediaServer.items` 走的正是列表接口——不修的话库级补全会**全部退化成标题搜索**（匹配率与请求数都明显变差）。已在 Jellyfin 与 Emby 两侧的 `itemsPage` 显式加 `ProviderIds`。**实测**：批量补全后 42 条对应**全部是 `providerID` 来源**。
  - 顺带清掉两处「同一个读取有两个入口、其中一个没人用」的死代码（`TMDbCoordinator.link(for:tenant:store:)` 要求调用方自己递 `MetadataStore`；`TMDbCoordinator.link(itemID:tenant:)` 与 `TMDbEnricher.link(for:tenant:)` 才是统一入口），以及面板里一个设了从不读的 `didBind`。
  - **实机验证**：批量补全 42 条对应 / 91 个实体（含 **50 个季**）/ 0 匹配不上 / 0 失败，约 20 秒跑完；抽查「凡人修仙传」第一季 **206 集**全带中文标题（该剧从未打开过）；面板显示当前匹配与来源、候选海报、勾选态正确；手动绑定（`providerID` → `manual`）与解除（对应删除、**实体保留**）均实测通过，测试后已恢复为 `providerID`。
  - 测试：`MetadataKit` **118 用例**（+13：批量流程、可续性、失败隔离、非视频类型跳过、空列表、取消保留已做、剧集连季、手动绑定/不被自动匹配覆盖/解除/搜索、未配置 key 空操作）；`OcPlayerTests` **349 用例**（+7：批量状态、外部链接跟随已建立的对应）。

  - **两条「知道但不修」的取舍**（都写了实测依据与将来的修法，避免被反复重新讨论）：
    1. **分集剧照是两段式的**：首次渲染用服务端的图，TMDb 数据到位后替换（实测探针：第一次渲染 `overlayEps=-1`、第二次 `13`）。保留的理由：另一种做法（等 TMDb 就绪再渲染选集）会让**选集整条晚出现**，而闪换只是一帧；且离线时服务端图仍是有效兜底。要消掉它得让季数据先于分集卡片就绪（预取或让卡片在 overlay 未就绪时显示占位），代价都比收益大。
    2. **脏 `ProviderIds` 会每次重试、且永不补全**：若服务端给的 Tmdb id 在 TMDb 不存在（404），该条目每次打开详情页会白打一次请求，而且因为权威对应不会被自动匹配顶掉，它也永远不会退回标题搜索。**不加退避是因为实测本机库没有这种条目**：**全量** 41 个带 Tmdb id 的电影/剧全部有效（0 个 404，也没有类型不符）。修它需要 v3 迁移 + 失败重试策略，收益是「避免一个没有发生的请求」。将来若真出现，正确做法是在 `tmdb_link` 上记失败时间、N 天内跳过，并在权威 id 失效时退回标题搜索（见 `TMDbEnricher` 里那段注释）。
  - **一个被否掉的判断**：我一度认为「季/集没有展示面」并据此删掉了 App 层的季分支——那是只查了「有没有分集详情页」就下的结论。用户指出分集卡片标题、季切换、描述区都是现成展示面。教训：判断「有没有展示面」要看**渲染路径**，不是看有没有独立页面。
  - **修一个自己引入的缺陷**（首次实机运行靠日志发现）：演员头像原先一律由「服务端条目 id」拼 URL，而 TMDb 补的演员 id 在服务端根本不存在——实测服务端返回 **400**（日志实证 `/Items/tmdb-1254052/Images/Primary` → 400），于是每个演员一张破图 + 一次白打的请求（一页最多 20 个）。现在叠加层能由 `Person.id` 反查 TMDb 头像路径（`profilePath(forPersonID:)`），取图优先走 TMDb CDN（免鉴权）。演员 id 也加了 `tmdb-` 前缀作为**两套编号的隔离带**——服务端与 TMDb 的演员 id 可能撞号，撞了就会「拿服务端 id 问服务端、拿到另一个人的头像」这种静默错图。实机复验：400 消失，11 张 TMDb 头像已入缓存。
  - 验证：`Packages/MetadataKit` **105 用例**（新增 55：匹配优先级·脏 ProviderIds·**集/季陷阱**·置信度六档·原名回退搜索·候选排序·标题归一化（含「不剥数字差异」——不能把「阿松 2」归一成「阿松」）·叠加文本/图片策略·实体键往返与垃圾输入·落库往返·**跨租户共享与隔离**·v2 迁移保留 v1 数据·幂等重开·过期淘汰边界·清除时保留他人引用·端到端匹配→拉取→落库·并发合并·未配置全禁用）+ **17 用例**（客户端层：解码·语言逐字段回退·v3/v4·401 vs 429·限流并发与最小间隔·图片档位映射）；`OcPlayerTests` **339 用例**（新增 `TMDbCoordinatorTests` 15 项：留空即禁用·设置持久化与空白剥离·掩码回显·默认值·天数夹取·换语言重置计数·清除连带孤儿实体·AppModel 用注入域而非 `.standard`）。macOS Debug 与 iOS 构建通过；设置页**实机目视验证**过未配置与已配置两态（掩码、语言选择器、两个开关默认值、清除按钮、署名文案均正确）。

- **媒体元数据落 SQLite（`Packages/MetadataKit`），冷启动与离线不再空白**。此前首页/详情/库页的元数据**只活在内存里**，进程一退就全丢，唯一的幸存者是 3 bit 的骨架条数掩码；而 JSON API 连 HTTP 层缓存都没有（会话是裸 `URLSessionConfiguration.default`，`URLCache` 只服务图片）。于是断网冷启就是一张空白错误页，正常冷启则每次都要等一轮网络。现在新增 `Media.sqlite`（GRDB，与 Bangumi 库同目录同款 `DatabasePool`），把**首页三条 rail / 库列表 / 条目详情 / 季与集 / 翻过的库页 / 媒体技术信息**落盘，冷启动先读磁盘（首屏立刻有内容）、网络结果回来原位覆盖。
  - **装饰器只写不读**（本设计最重要的一条约束）：`CachedMediaServer` 对 `MediaServer` 的 30 条要求逐一转发，**返回值与错误与内层完全一致**，只多做一件事——把响应写盘。朴素做法「网络失败时返回缓存」会让调用方分不清手上是新数据还是旧数据，「离线」在 UI 层就没法表达；而吞错误还会把既有调好的错误路径弄浑（首页 `RailResult` 的逐条成败、详情页 SWR 的静默失败）。职责因此切成三块：写穿（装饰器）、离线读（`MetadataHydrator`）、UI 决策（页面）。选装饰器而非在各调用点加缓存，是因为协议将来新增方法会**编译不过**，而散点写法一定是漏一条就静默不缓存。
  - **离线提示分两档，不谎报**：新组件 `StaleContentBanner` 在首页与详情页各摆**一行小字**（不挡内容、不加按钮）。文案按失败原因分岔——`noNetwork` / `serverUnreachable` 才说「离线 · 数据更新于 X 前」，5xx / 401 只说「内容可能不是最新 · 刷新失败」，免得把人引去查网络而问题在服务端；时间用相对表述（几分钟前 / 昨天 / N 天前）。**有内容才提示**：没有任何内容时走的是既有整页错误态，不再叠一条自相矛盾的提示。
  - **进度永不作写权威**：缓存里的播放进度只读，服务端响应一律覆盖（`markPlayed` / `markUnplayed` 直接写回服务端返回的权威值）；进度与元数据**两个独立时间戳**（进度 15 分钟 / 元数据 7 天），因为「进度是 5 分钟前的、简介是 3 天前的」必须在 UI 上可区分。淘汰两条上限**互相独立**（3 万条 / 200 MB，都挂在每日存储维护上）：体积超限时按「当前条数的 10%」删最旧的一批——这里踩过一次，原写法是「删到条数上限的 90%」，而实测每条约 1 KB、3 万条折合才 ≈30 MB，**条数上限永远先于 200 MB 触发**，于是体积那一道在条数未超限时恒为空操作、上限形同虚设；现在与条数解耦，并有用例把体积上限压到 1 字节验证它真会删。设置页「维护」新增一行可见体积与「清空媒体元数据缓存」的出口（与图片缓存**分两行**：清图片只是重下图，清元数据会让下次冷启回到等网络的状态，合成一项用户不知道自己在放弃什么）。
  - **路径收口 + 修一个既有缺口**：新增 `OcPlayerStorage`（DiagnosticsKit）作为 `Application Support/OcPlayer/*` 的**唯一事实源**。此前这条路径在 6 处各自手拼，而维护清单只看 `AppStorageDirectories` —— `Bangumi.sqlite` 就是这么漏掉的：自引入起从未被清理、被统计、被设上限，体积在 App 内完全查不到。现在两者都登记进维护（只上报体积，不进删除路径），数据库体积上报含 `-wal` / `-shm`（WAL 会随写入增长，不算它长期少报一大截）。
  - **健壮性**：库损坏 / 迁移失败**删库重建**（缓存可重建，重建代价只是下次多拉一遍；半坏的库会让每条读路径各自出错），重建仍失败才抛错（那说明是磁盘满/权限，不能让调用方以为缓存正常）。payload 用**宽容解码**（缺字段取默认值），于是以后给 `MediaItem` 加字段**不需要迁移**；`payload_version` 只在语义不兼容时作废整条缓存。
  - 验证：`Packages/MetadataKit` **50 用例**全绿（建库/损坏自愈、round-trip、旧 payload 宽容解码、未知版本当未命中、**租户隔离**、页键与 `LibraryPageKey` 同构、淘汰最旧优先、装饰器 30 条转发不漏·返回值逐字段一致·错误原样抛·失败不留半份缓存、离线读「没缓存」与「缓存为空」的区分）；`OcPlayerTests` **314 用例**全绿（新增 `StaleContentNoticeTests` 12 项、`MetadataCacheIntegrationTests` 9 项、`MetadataCoordinatorTests` 11 项，后两者用临时目录真库端到端钉住「读缓存不发请求」「断网进详情仍有内容且标离线」「换服务器不读上一台缓存」「服务端出错不谎称离线」）；macOS Debug 与 iOS 构建通过。
- **图片缓存不再按服务器地址分家：同一台服务器换入口（局域网 ↔ Tailscale ↔ 反代）不再重下所有海报**。此前 `URLCache` 拿**完整 URL** 当键，而图片 URL 里含服务器地址：
  ```
  http://192.168.5.107:8096/Items/{id}/Images/Thumb?maxWidth=720&tag=…   ← 局域网
  http://100.127.128.96:8096/Items/{id}/Images/Thumb?maxWidth=720&tag=…  ← Tailscale
  ```
  同一张图存成两份，**换地址后全部海报重新下载一遍**——而「一台服务器多条地址、自动择优、换了无缝续用」正是这个 App 明确支持的能力（见 `ServerEndpointDirectory`）。实测用户库 110 MB 图片缓存里相当一部分是这种重复（缓存里同时躺着两个 host 的同一 item）。现在新增 `CanonicalImageURLCache`：键里把 scheme+host 换成占位符 `ocplayer.invalid`、只保留路径与查询，属主身份改由**认证头的跨进程稳定哈希**（`FNV1a`，非 `hashValue`——后者每进程随机播种会让缓存每次启动全失效）承担，于是「同一台服务器 + 同一账号的不同地址」共用一份缓存，而「不同服务器 / 不同账号」仍然隔离。
  - 只规范化路径含 `/Images/` 的媒体服务器图片；`image.tmdb.org` / `lain.bgm.tv` 等图床只有一条地址，不动（避免不同图床路径相同的理论撞键）。
  - 键一变旧键就永远命不中，故加**一次性清理**（UserDefaults 标记，只做一次）：把死数据删掉、磁盘还给用户。新键本来就要重下，这次清理**不额外增加任何下载**。实测生效：旧 110 MB → 6.5 MB，19 条新键全部形如 `http://ocplayer.invalid/Items/…`，含具体 IP 的键 **0 条**。
  - **但仅靠 `URLCache` 不足以离线出图**（用户实测报「重启后图片全是占位符」）：实测它**跨实例读不回来**——索引库里条目明明在（`storage_policy = 0`、服务器发的是 `Cache-Control: public, max-age=31536000, immutable`），同一个实例内能命中，**换个实例（= 重启 App）就一律 miss**，且直接调 `cachedResponse(for:)` 是读得到的、只有走 `URLSession` 才暴露。这个行为无法回归、也无从解释。而「断网重启后海报还在」是用户可见功能，不该建在看不清的机制上，故新增 `ImageBlobStore`：**图片字节自存**（文件名 = 稳定键的 FNV1a 哈希），读/写/淘汰全部自己控制，网络失败时由 `ImagePipeline` 回落到它。
  - **另一个真实缺陷**：认证头里含 App 版本（`Version="0.2.0 (506)"`，构建号 = git 提交数），整头哈希当缓存键就等于**每次发版把用户全部图片缓存作废**（实测 Build 505 与 506 的哈希确实不同）。现在 `authIdentity` 只取 `DeviceId` + `Token`：换地址、升级版本都不再影响缓存，换账号 / token 轮换才失效（正确）。
  - 验证：`Packages/AppDesignKit` **46 用例**全绿（`ImageCacheKeyTests` 17 项：跨地址共键·不同条目/尺寸/tag 不共键·不同账号隔离·图床不改键·**版本变化不换键**·token/设备变化换键·哈希跨进程稳定·真 `URLCache` 存取命中·清空后失效·旧键清理只跑一次；`ImageBlobStoreTests` 7 项：存取 round-trip·**新实例仍读得到**（模拟重启）·文件名稳定·空数据不写·清空·超限按最旧淘汰·体积统计）。
  - 端到端实测（真机 + 真服务器）：联网预热后把服务器指向不可路由地址（等价离线）重启 App —— **首页图片全部正常显示**（媒体库封面、继续观看剧照、接下来看海报），仅预热时没访问过的那个库封面为占位符（符合预期）。
  - **磁盘优先**（用户追问「为什么离线加载缓存图片要这么久」后修）：兜底原先写在 `catch` 里（网络失败再读磁盘），于是断网时**每张图都要先等网络超时**——实测每次 `-1005 连接中断` 约 7 秒，首页十几张图就是十几秒起步。现在改成**网络之前先查磁盘**，命中即返回，并在后台按需回源刷新。顺带把图片会话超时从系统默认 60 秒收到 15 秒（图片是可替代资源，宁可早点显示占位符）。
    - 后台刷新三道闸门防「几百张海报同时回源」：**新鲜度阈值 7 天**（用 `creationDate` = 下载时间，不是 mtime——后者读取时会被刷成「刚刚」，那样永远不刷）、**同键去重**、**并发上限 4**。超限就跳过这次（下次还有机会），不在用户翻页时突然打出上百个请求。
    - 因为 URL 通常带 `tag`（服务端换图 → URL 变 → 键变），阈值可以取得较长；它只为兜住**没有 tag 的 URL**，压住「永远不更新」。
    - 同时修一个**我自己引入的 bug**：`imageFromBlobStore` 用 `try?` 把「解码被取消」和「字节真解不出」收敛成同一个 `nil`，于是**取消（快速滚动时的常态）会被当成坏数据、把完好的缓存删掉**，缓存越用越少（实机日志里就出现了「磁盘图片解码失败，已丢弃」）。现在取消原样上抛、只有真 `nil` 才丢弃。
    - 验证：`Packages/AppDesignKit` **51 用例**全绿（新增 `ImagePipelineDiskFirstTests` 5 项）。其中「缓存命中不等网络」用**永不返回的 URLProtocol** 当网络——只要加载能返回就证明它没等网络。**回归有效性已实测**：把代码临时回退回「网络优先」，该用例报 **15.05 秒**失败；修好后 < 1 秒通过。真机复验：离线启动日志无任何网络等待、无「解码失败」，截图确认媒体库封面与继续观看剧照全部正常显示。
  - 排查记录（两条 Foundation 实测，都已写进代码注释）：`removeCachedResponse(for:)` 单条删除在本机 Foundation 上对磁盘缓存**不可靠**（同一个 `URLRequest` 存完再删仍然命中），故不再拿它当断言；`removeAllCachedResponses()` 是**异步**的（清空后立刻查仍命中、约 1 秒后才失效），用例改成轮询等待而非死等，避免慢机器偶发失败。用户可见的「清空图片缓存」走的是后者，实测有效。

  - 排查记录：期间测试宿主连续崩溃（用例 0.000 秒失败 + xcodebuild 反复重启宿主，单轮从 11 秒涨到 162 秒），崩溃报告是 `doesNotRecognizeSelector` 打在 `Dictionary.subscript.modify`——**我自己给测试替身加的调用计数器被三条并发 rail 同时改写**（`loadHome` 用 `async let`），把 Dictionary 结构写坏了。加锁后消失（已在新计数器上写明这段）。同批修掉另一处测试隔离问题：`xcodebuild` 默认并行多进程跑用例，而新用例与 `HomeRailLoadingTests` 共用 `.standard` 里的骨架条数键会互相污染，故给 `AppModel` 加了 `preferences:` 注入点（与 `ServerStore(defaults:)` 同款）。

- **详情页头部补上「去原站看看」的两个品牌图标：Bangumi 与 TMDB**。此前详情页看不到这部作品在外部站点是哪一条：Bangumi 只能在页内区块里点进 App 自己的条目页，TMDB 则连入口都没有（条目上的 `ProviderIds` 早就带着 Tmdb id，只是没地方用）。现在头部元信息行右侧给两个图标（窄屏放在类型行右侧，避免挤压已经排满的评分 / 分级 / 年份 / 季数 / 时长那一行），点开即用系统默认浏览器打开 `bgm.tv/subject/{id}` 与 `themoviedb.org/movie|tv/{id}`。
  - **只显示拼得出确定地址的那些**。电影 → `/movie/{id}`、剧集 → `/tv/{id}`（条目自身的 ProviderIds 就是该粒度的 id）；**季与分集一律不给链接**——它们要的是 `/tv/{id}/season/{n}` 里的**剧集级** id，而分集条目 ProviderIds 里的是集级 id（`TheIntroDB` 那边踩过同一个坑，见 `AppModel.seriesTmdbID`），硬拼会指到别的作品。宁可少一个图标，也不摆一个点进去是别人家片子的地址（`ExternalMetadataLinksTests` 钉住这条）。ProviderIds 是插件写的字符串，空串 / 非数字 / 0 / 前后空白都按「没有」处理（trim 后可用则照用）。
  - **Bangumi 图标与页内区块同一条门槛**：设置里停用 Bangumi 或未登录时整块不出现，不会出现「区块说没登录、头部却挂着 Bangumi 图标」；条目未关联时也不出现（没有可去的地方）。页内第一次自动匹配 / 手动关联成功时，图标**当场**出现——关联的唯一写入口 `BangumiMatcher.setLinkedSubjectID` 发一条 `OcPlayer.bangumiLinkDidChange` 广播，将来新增写点自动带上。
  - **品牌图标按各自规则渲染**：两个都用**官方彩色图**，与同为品牌标识的 TMDB 并排风格统一。TMDB 用官网 logos-attribution 页提供的官方 SVG（`blue_square_1` 方形变体，2.2 KB）；Bangumi 用**官方 glyph + 官方渐变色**——仓库原有那份是同一个 TV 标记的单色线稿（与官方 favicon 逐像素比对确认同形状），新增一份 `bangumi-logo-color`（保留矢量与透明通道，填官方 App 图标采样到的渐变：顶部 `#F70098` 洋红 → 底部 `#FF69A3` 品牌粉）。**顶栏药丸与 iOS Tab 不动**：那里图标要与标签文字一起随选中态变亮变暗、并与同为单色模板图的 MoviePilot 并排，仍用原 `bangumi-logo`；两份资产共用同一 glyph，不存在形状漂移。
  - **没走官方横版字标的理由**：Bangumi 官方彩色资源（`logo_riff.png` / `logo.png` / `logo_rc1.png` / `ico_ios.png`）除了 16×16 favicon 外全是宽高比 2.9–4.0 的横版字标，而详情页此行图标只有 12–15pt 高 —— 实测缩到该尺寸后「番组计划」副标题完全糊掉、字标不可辨认；`ico_ios.png` 虽 256×256 且彩色，但是 RGB 无 alpha（iOS 图标白底烘死），不能作行内图标。官方方形彩色标记只有 16×16，放大即糊。故取「官方 glyph + 官方渐变」的矢量组合，任意尺寸清晰。
  - 尺寸宽高都钉死（Bangumi 15×15 正方形标记 / TMDB 28×12 宽扁字标）——交给 `.frame(height:)` 推宽度会让排布依赖父级提案，钉死后图标不随可压缩的兄弟视图变形。
  - **解析任务挂在条件之外**：`.task` 若挂在「有链接才画」的 `if` 里会自锁——首帧 `links` 为空（Bangumi 关联还没解出来）→ 图标行不存在 → 任务从未运行 → 永远解不出来。故包一层恒在的 `Group`。
  - **顺带收敛一处重复**：详情页的「选中的季 → 剧集 → 条目自身」Bangumi 关联解析链原来内联在页内区块的 `load()` 里，头部图标是第二个读点，收敛成 `BangumiMatcher.linkedSubjectID(for:selectedSeason:)`（行为逐字不变，第 1 季 / 单季才回落到剧集，其它季不回落以免串季）；`DetailView` 里「当前选中的季」也抽成一个属性，给头部图标与 Bangumi 区块共用。**播放结束的自动标记那条链没动**：它取分集条目自己的 `seasonID`、也没有「第 1 季才回落」这一档，语义不同。
  - 验证：`OcPlayerTests` 新增 `DetailExternalLinksTests` 5 个用例（电影/剧集的地址、季与分集不给链接、脏 ProviderIds 六态、Bangumi 地址三态、组合顺序与图标渲染属性）；macOS Debug 构建通过。

- **一台服务器可以有多条地址（局域网 / Tailscale / 反代域名），App 自动挑最快可达的那条**。此前 `ServerProfile` 只存得下**一个** `baseURL`，于是「在家走局域网、出门走 Tailscale」这件事只能靠**同一个服务器登两遍**——而档案 id 是 `serverID:userID`，两次登录指向同一个 id，第二次会把第一次的地址**覆盖**掉：出门前存好的局域网地址、回家后存好的 Tailscale 地址，永远只剩最后那个，且换地址必须重新输账号密码。现在档案拆成「一组地址 + 当前生效地址 + 可选固定项」，服务器身份（`/System/Info/Public` 的 `Id`）是合并判据。
  - **落盘**：`ServerProfile` 新增 `addresses`（备选地址，落盘就是地址字符串数组）/ `pinnedURL`（用户固定项）/ `serverID`（显式服务器 Id，老档案从 id 前缀恢复，且拒绝把 host 兜底值当服务器 Id 用）。三个字段都是 `decodeIfPresent`，0.2.0 及更早的档案解出来是「只有一条地址、自动择优」的正常状态，无需迁移。已在档案里的老 `baseURL` 永远是候选之一。
  - **合并**：`ServerStore.save` 同 id 不再整体替换，改走 `ServerProfile.merged` —— 新登录地址成为当前、旧 `baseURL` 与旧备选退成候选（归一化去重，尾斜杠 / 大小写 / 默认端口视为同一入口），固定项沿用用户的选择。于是「用 Tailscale 地址再登一次」只是给这台服务器**补了一个入口**，不会再冒出一个服务器条目。
  - **择优**：新增 `ServerEndpointDirectory`（每档案一个，由 `ServerStore` 托管并在会话重建之间复用）+ `ServerProbe`（`/System/Info/Public` 探活，匿名可用、响应里带服务器 `Id`）+ `ServerAddress`（地址模型与分类：`100.64.0.0/10` 与 `*.ts.net` 认 Tailscale、私网 IPv4 与 `.local`/单标签主机名认局域网）。规则是**按实测延迟择优而不是按类别**（Tailscale 直连有时比绕一圈的局域网更快），并且三条约束：①**粘性**——当前地址可达时只有新地址明显更快（< 当前 × 0.7 − 20ms）才切，避免两个入口延迟接近时来回抖；②**软过期后台重探**——缓存 300s 到期后台重探、不阻塞请求，只有首启 / 网络变化 / 从没探过时才等一次探活（2s 超时）；③**失败开放**——一个地址都探不通时保持原地址不动，绝不把「探活本身失败」变成「连不上服务器」（并把下一次重探推后 5s，免得服务器整个下线时每个请求都先等一轮）。
  - **换址**：`JellyfinServer.send` 与 `EmbySession.data` 在传输层失败时重新探活，换到别的地址就在新地址上**立刻重试一次**（不打退避）；失败触发的重决议有 3s 冷却，一串并发失败不会打成探活风暴。HTTP 状态码（4xx/5xx）不算「地址不通」——服务器已经答了话，换地址只会把同一个错误再撞一遍。换址判断刻意排在**重试闸门之前**：`.serverUnreachable` 里「名字解析不了」（`-1003/-1006`）那一类是不可重试的，而主机名候选（`nas.local` / MagicDNS 名 / 反代域名）换网络后报的恰恰是它 —— 排在后面会被 `break` 一起吃掉，等于「出门自动换址」在最典型的一类地址上静默失效。
  - **探活的严格性**：`/System/Info/Public` 解不出媒体服务器那四个字段就判**不可达**（此前 `try?` 吞掉解码失败、`Id` 校验又因拿不到 `Id` 而跳过，于是反代 SPA fallback / NAS 管理页这种「200 + HTML」的地址会被判可达：它通常比真服务器更快，会被选为当前地址，而探活永远成功、粘性不切走，API 却全部解不出来，卡住只能用户手动处理）。服务器没报 `Id` 时仍算可达 —— 那只是失去「是不是同一台」的校验能力，不该把可用地址判死。
  - **服务器 Id 的形状校验**：老档案没有显式 `serverID` 时从档案 id 前缀恢复，但前缀必须是「≥16 位十六进制」才认。老版本在服务器没报 `Id` 时会拿 host（`nas`）甚至整个地址串（`http`）拼档案 id,把它们当服务器 Id 用会让每条地址的探活校验都对不上：添加地址误报「另一台服务器」、启动换址静默失效（`firstReachable` 全 nil 后回落到 baseURL，连报错都没有）。
  - **触发点**：登录 / 启动恢复 / 切换服务器挂上决议器并立即预热一次；新增 `ServerEndpointMonitor`（`NWPathMonitor`，500ms 去抖）在 Wi-Fi ↔ 蜂窝、插拔网线、Tailscale 起停时作废地址结论；iOS 回前台同样作废。决议选中的地址由 `AppModel.serverEndpointChanged` **在主线程**写回档案（`ServerStore` 的写路径必须留主线程：后台线程写 `UserDefaults` 会与主线程读构成 ABBA 互等，MoviePilotStore 上实测过），并驱动 `serverEndpointURL` 让图片 / 播放流地址跟着换。两处容易漏的细节各有回归测试：①`invalidate()` 会**作废在飞的决议**（只置标志的话，在飞任务回来仍会把旧结论标回「新鲜」，网络变化被丢掉、最长再等 300s）；②`NWPathMonitor` 启动时那一次投递是「当前路径」而不是「路径变了」，跳过它免得刚预热好的结论当场被作废、首屏白等一轮探活。
  - **UI**：「管理服务器」每台服务器可展开管理地址——列出全部入口（分类图标 + 延迟 / 使用中 / 已固定 / 不可达）、添加地址（带服务器 Id 校验：能连上但报的是**另一台**服务器时明确拒绝并入，并提示改用「连接其它服务器」；此刻连不上也可以「仍然添加」，典型场景是在没有 Tailscale 的网络里先把家里那条存好。Emby 档案的候选会自动补 `/emby` 前缀 —— 手工入口是登录流程之外唯一会产生候选的地方，漏了前缀会在被选中后全链路 404）、删除地址（二次确认，最后一条不给删）、固定 / 恢复自动择优（固定后不再自动切换，文案写明代价）、「重新检测」。设置页地址行显示当前生效地址并说明共几个入口；登录页的已保存服务器行标出地址条数。首页氛围轮播的装载触发键并入当前生效地址：换址后池子里的图片 URL 已作废，必须按新地址重拉一次。
  - **验证**：`swift test --package-path Packages/JellyfinKit` 190 用例全绿（新增 4 个测试文件：地址分类 / 归一化 / 落盘格式、决议器的择优·粘性·固定·冷却·失效·在飞作废·空候选、真实探活的路径·Id 校验·非媒体服务器拒绝、两实现在 IP 与主机名两类失败下的换址重试；另在 `ServerStoreTests` 补 14 个用例覆盖合并、地址增删、固定、老档案解码与服务器 Id 形状校验）。`OcPlayerTests`（macOS 与 iOS 模拟器）269 用例全绿，含新增 `ServerEndpointWiringTests`：换址结论落档案 + 发布到界面、不换址时不写档案（以「探活确实发生过」为前置，不用固定 sleep）、固定项优先、旧会话迟到回调被忽略、Emby 候选补 `/emby` 前缀。macOS / iOS 构建通过。另做了一轮对抗性审查（并发 / 锁、合并去重、老数据兼容、请求放大、Emby 前缀、UI 状态一致性、测试假通过），上列换址闸门顺序、探活严格性、Id 形状校验、在飞作废、Emby 前缀、氛围图重拉六项即该轮发现并修掉的问题。


- **jellyfin-sdk-swift 3.0.0 → 3.3.0，Jellyfin 12 兼容**。Jellyfin 12.0 起版本号脱离 10.x 系（10.11 直接跳 12.0），带三项客户端可见的破坏性变更，逐项核对全不沾：①旧式鉴权默认禁用（`X-Emby-Token` 头 / `api_key` 查询参数）——我们全链路只用现代 `Authorization: MediaBrowser …` 头，token 不进 URL；②移除 `/emby/*`、`/mediabrowser/*` 路径别名与 `GET /QuickConnect/Initiate`（只留 POST）——`/emby` 前缀只拼给 Emby 档案，Quick Connect 走 SDK 的 POST；③GetItems 带 `includeItemTypes` 时递归过滤语义变化——我们的查询（`Movie,Series` / `Episode` + `recursive=true`）正是此形态，是本次升级的实际动机。3.3.0 按 Jellyfin 12.1 的 OpenAPI 重新生成，`from: "3.0.0"` 收紧为 `from: "3.3.0"`；封装层（JellyfinKit）零改动编译通过，133 个包测试全绿（请求形状断言不变，说明 SDK 层消费的路由与参数未漂移）。遗留提醒：跳过片头读的 `/MediaSegments` 依赖服务器端 intro-skipper 插件，10.11 时代的插件在 12.0 上不加载，需等插件发 12.0 适配版（服务器侧，非播放器问题）。验证：`swift test --package-path Packages/JellyfinKit` 133 用例全绿；macOS Debug 构建通过（App 层不直接 import SDK，仅消费 JellyfinKit 封装）。真实 12 服务器上的媒体库/剧集列表回归待有环境时补。

### 修复

- **修「播放完返回详情页背景丢失」——被盖住的库页透过透明详情页漏出**（用户截图现场：详情页内容间散落着媒体库网格的卡片）。探针 + 实机复现证实氛围声明与整窗背景层全程完好（c9f728c 的栈根修复无回归），真正漏的是**被盖住的路由页**：macOS 26 的 NavigationStack push 时**不给被盖页发 `onDisappear`**（探针证实整个进出播放流程零生命周期事件），`pageEntrance` 的「被覆盖即复位」从未生效——被盖页一直 opacity 1，只是系统平时不合成它；播放器开合翻转窗口工具栏可见性、乃至**改一次窗口尺寸**（与播放无关，实测可复现），都会触发整窗重合成让它重新参与合成。修法与栈根同一哲学：`CoveredPageHider`（AppShell）在 onAppear（落地即栈顶）记下自己的栈深度，`opacity = (depth == app.path.count)`，**path 驱动、与生命周期解耦**；仅 macOS 生效（紧凑布局的导航栈宿主不合成被盖页、`app.path` 恒空，保持直通）。验证：实机「播放开合」与「改窗口尺寸」两场景修复前后对照截图；`OcPlayerTests`（macOS）263 用例全绿。

- **修呈现式页面（`navigationDestination(isPresented:)`）同族两洞**。①**宿主漏出**：这类页面不在 `path` 上，`CoveredPageHider` 的深度比较看不见这层覆盖，宿主在呈现落地后依旧「是栈顶」——而呈现族全是透显设计（资源搜索页声明整窗氛围、下载管理 / 管理服务器 / 开源许可证走系统 List·Form 半透底），宿主内容会透过它们漏出（触发条件同上：整窗重合成）。修法：新增 `coveredByPresented(_:)` 绑定驱动宿主显隐，四个宿主登记——设置页（服务器 / 许可证两开关）、MoviePilot 首页（下载管理 / 资源搜索）、详情页（资源搜索，落地开关 `isResourcePresented` 从 `MoviePilotResourceSection` 上提由 `DetailView` 持有）、资源搜索页（下载管理）；只动 opacity 不摘视图，宿主的氛围声明保持活着供被盖期间整窗层继续渲染。②**声明被覆盖丢失**：详情页（声明 D）呈现资源搜索页（声明 R）后返回，`WindowAmbienceSetter.onDisappear` 把单值声明清成 nil，而 D 已被覆盖、详情页不会再补发——返回详情页背景照样丢。修法：声明改**栈**（`windowAmbienceStack`，条目带 setter 实例 id）：出现压入、存续期间原位更新、离屏按 id 摘除、栈顶即生效值（nil 条目表示「声明无氛围」照样占层，onDisappear 晚于新页 onAppear 的乱序天然安全）；`resetBrowseState` 相应改为清整个栈。验证：macOS Debug 构建通过；`OcPlayerTests`（macOS）263 用例全绿；实机验证设置 → 管理服务器、媒体库 → 详情两条链在改窗口尺寸重合成后无漏出、详情页氛围完好、连续返回首页后轮播氛围正确恢复。

- **设置页补上「退出 Bangumi」**。此前 Bangumi 的退出登录**只有一个出口**——Bangumi 分区「我的」页顶栏那颗门图标；设置页里只有账号行与「登录入口在顶栏的 Bangumi 分区」一句提示，想退出得先切到那个分区、再进个人页，与 Jellyfin / MoviePilot 的出口位置（都摆在「设置 → 服务」各自区块里）也不一致。现在设置页 Bangumi 区块在已登录时给出「退出 Bangumi」按钮（`role: .destructive`，同一个 `rectangle.portrait.and.arrow.right` 图标，调 `BangumiCoordinator.signOut()`），未登录时仍显示原来的登录指引——两块互斥，不会同时出现。顺带修同区块一处会互相打架的显示：账号行原先直接读 `bangumi.profile?.nickname`，而**已登录但资料还没拉回来**（profile 为 nil）时会显示「未登录」，旁边却摆着「退出 Bangumi」——抽成 `bangumiAccountText`，以 `isAuthenticated`（登录的唯一门控信号）为准，profile 缺失时退化显示「已登录」而不是「未登录」。验证：macOS Debug 构建通过；`OcPlayerTests`（macOS scheme）全绿；实机注入登录态逐项复核——账号行显示昵称 + 「退出 Bangumi」在位（注入 profile 缺失时显示「已登录」，不再自相矛盾）、点击后按钮消失且 `isAuthenticated` 归 false、`credentials.json` 里的 `bangumi.auth` 被清掉。

- **修「Bangumi 未登录时顶栏与氛围背景显示错误」（截图现场：整窗氛围图在，唯独顶栏是一条死灰横条，玻璃完全没吃到图）**。与上一条 MoviePilot 同源同坑，只是**同一坑里漏掉的那批根级状态视图**：`PageFillingState` 当时只落到了 MoviePilot 与首页，Bangumi 未登录态的门面 `BangumiLoginView` 仍是抱紧内容的 `VStack` + `.frame(maxWidth:.infinity,maxHeight:.infinity)`——理想尺寸与窗口无关，整条尺寸链（根视图 → 导航栈 → 外壳 → `.background`）跟着塌，顶栏底下没了内容，系统改画不透明的窗口底色。**同一份构建上的 A/B 是判决性的**（1384×869，深度色，取样：顶栏条带 y=8pt 亮度 sd 与「顶栏 vs 下方内容带」亮度差 |t−c|）：Bangumi 未登录页 sd **3.28** / |t−c| **42.6**（一条 52pt 死灰平条），而同窗口已修好的 MoviePilot 门控页 sd **29.11** / |t−c| **17.5**（玻璃透过氛围图）、首页 sd 30.57 / 9.2、设置页 sd 34.72 / 17.8 全过——即这不是「登录态不同」或氛围图没出来，而是这一页没包载体。另写最小复现 App（只保留「窗口 `.background` 氛围层 + 导航栈 + 工具栏」这一形状）逐项二分，把「载体」钉死：**`frame` 系全救不回来**——`.frame(maxWidth:.infinity,maxHeight:.infinity)`、`minWidth/maxWidth/minHeight/maxHeight` 组合、`GeometryReader`、`ZStack{Color.clear; content}`、整链级 `containerRelativeFrame([.horizontal,.vertical])` 六种写法顶栏一律不透明（|t−c|≈79.8），**只有 ScrollView 载体过**（|t−c|≈1.6），与 `PageFillingState` 的选择逐字吻合；且**push 页同病**（栈根已换成铺满的 ScrollView 之后，push 进来的裸状态页依旧不透明，|t−c|≈79.6），载体要落在「谁的状态视图谁包」上。落地范围（全部改走 `PageFillingState`）：`BangumiLoginView` 整页门面；`BangumiHomeView` 的建库失败态（原 `frame(maxWidth:maxHeight:)` 已证无效，去掉）与进度页失败 / 空态两个根级分支、搜索态失败 / 无结果两个分支（后两个原来同样是 `frame` 版）；`BangumiCalendarView`（push 页）的加载失败 / 无数据两态；`BangumiCollectionListView`（push 页）的加载中（两处）与失败态。`BangumiLinkPicker`（sheet，自带固定 minHeight）与 `BangumiSubjectDetailView` / `BangumiProfileView`（根已是 ScrollView）本就安全，未动。验证：macOS Debug 构建通过；`OcPlayerTests`（macOS scheme）**263 用例全绿**；实机逐页取样（每次先用窗口标题断言确实落在该页，1384×869，五次连续切换）——首页 sd 32.47 / |t−c| 14.9、Bangumi 未登录 sd **11.54** / |t−c| **1.6**、MoviePilot 未登录 sd 11.54 / 1.6、设置 sd 11.54 / 5.1、Bangumi 二次进入复测 sd 23.02 / 14.1，全部 sd>10（玻璃顶栏，修复前该页为 3.28 判 FAIL），顶栏行为与首页 / 设置页 / MoviePilot 门控页一致。

- **修「MoviePilot 分区整页只有中间一块有氛围背景」（未登录 / 未配置门控页，用户报的「整个画面都错误」）**。根因不在登录态，而在**尺寸链**：AppShell 把氛围底图挂在根节点的 `.background` 上，而 `.background` 拿到的尺寸就是宿主的尺寸、**不会反过来把宿主撑大**；分区的根视图一旦是「理想尺寸固定」的状态视图，整条链（根视图 → 导航栈 → 外壳 → 背景）就一路塌成内容那一小块。实机实测（1100×700）：`ContentUnavailableView` 的理想尺寸是 **400×400**（`MoviePilotHomeView.gate`），同一页在 1384×869 与 1100×700 两个窗口下，有图的那块都恰好是 400×400 居中——即它不随窗口变化。像素对照同窗口的 Bangumi 页：顶栏玻璃采样到的是氛围图 (159,127,99)，而 MoviePilot 页顶栏与四周一律 (41,43,43)（= `windowBackgroundColor`），八个取样点全同色，确认是背景层塌了而非遮罩所盖（截图里那块方形边界也正是它）。修法：新增共享原语 `PageFillingState`（`AppDesignKit/Layout/`）——用 ScrollView 承载状态视图，ScrollView 不吃理想尺寸、会铺满被给到的空间，尺寸链从它开始一路撑满窗口，`.background` 自然拿到整窗尺寸；`containerRelativeFrame(.vertical)` 负责把内容在可视区垂直居中。**给状态视图自己加 `.frame(maxWidth:.infinity,maxHeight:.infinity)`（哪怕连带 `.ignoresSafeArea()`）不管用**，实测仍然塌——这正是本坑的迷惑之处。落地范围：`MoviePilotHomeView` 的三态门控（`gate`）与搜索态的三个根级分支（加载中 / 失败 / 无结果，搜索态下本页没有结果列表的 ScrollView 兜底）全部包上；`HomeView` 里同款私有实现（`SearchEmptyState` 与 `errorState` 内联各一份）收敛到该原语，AppDesignKit 新增文件成为这条约定唯一的落点与解释处。验证：macOS Debug 构建通过；`swift test --package-path Packages/AppDesignKit` 24 用例、`Packages/MoviePilotKit` 60 用例全绿；实机逐项复核——修复后同一页八个取样点**互不相同**（左上 (12,2,2) / 右上 (107,57,19) / 左中 (17,5,5) / 右中 (61,21,11) / 左下 (24,18,18) / 右下 (24,19,18) / 顶栏玻璃 (108,54,23)），顶栏玻璃与 Bangumi、设置页行为一致；两种窗口尺寸（1384×869 与 1100×700）下均满窗；首页（共用同一原语）截图确认无回归。
- **修「MoviePilot 只是没登录，分区首页却报『未配置 MoviePilot』」（截图现场：登出 / 令牌失效后整页空态 + 一个「去设置」按钮，而地址与用户名其实一直好着）**。根因是首页门控用了 `MoviePilotStore.isConfigured` 当「配没配」的判据：这个属性同时要求**地址 + 用户名 + （密码或令牌）**——它的语义是「现在能不能拿这份凭据直接发请求」，而不是「这台服务器配过账号」。于是凭据被正常交还的两种情形（用户点「退出 MoviePilot」、令牌 8 天过期后没记住密码、静默重登也失败）全都落进 `false`，首页把「未登录」说成「未配置」，还把人赶去设置页；而设置页状态行对同一状态显示的是另一个词（`.isConfigured ? "未登录" : "凭据不全"`），两处文案互相打架，且默认档（不保存密码）下**每次重启后令牌一过期就必现**。本机实测当前配置正是这一态：`serverURL=192.168.5.107:30000`、`username=jumusu`、`rememberPassword=1`，而凭据文件里 `moviepilot.token` 与 `moviepilot.password` 都不存在——旧判据算出「未配置」，与截图逐字吻合。修法：把「配过账号」与「凭据可用」拆成两个语义，新增 `MoviePilotStore.hasAccount`（仅地址有效 + 用户名非空）与三态枚举 `IntegrationState`（`.unconfigured` 没配过 / `.loggedOut` 账号在但没令牌 / `.ready` 有令牌），并让**分区首页与设置页状态行共用同一判据**（`MoviePilotCoordinator.integrationState` 转发）——首页 `.unconfigured` 才给「去设置」，`.loggedOut` 给「重新登录」+「去设置」（登录窗预填地址与用户名，用户只补密码），设置页三态文案随之收敛，同一状态在两处不可能再显示成两个词。`isConfigured` 保留原语义（供「能不能直接发请求」使用，其既有测试不动）。验证：`swift test --package-path Packages/MoviePilotKit` 60 用例全绿，新增三个状态机用例——`testSignOutReadsAsLoggedOutNotUnconfigured`（登出后 `isConfigured == false` 但 `hasAccount == true`、态为 `.loggedOut`）、`testExpiredTokenWithoutRememberedPasswordReadsAsLoggedOut`（跨重启、401 清令牌后仍是 `.loggedOut`）、`testIntegrationStateIsUnconfiguredWithoutUsableAddressAndUsername`（缺用户名 / 地址非 http(s) origin / 只有孤儿令牌都必须是 `.unconfigured`，否则会把人送进一个没有「改地址」出口的页面）；macOS Debug 构建通过；本机真实配置代入新判据得到 `.loggedOut`，与修复目标一致。
- **修「设置 → 退出 MoviePilot 每次必卡死（App 未响应，只能强制退出）」**。根因是 `MoviePilotStore` 在**后台线程**上写 `UserDefaults` 造成的 ABBA 互等：`UserDefaults` 每次写入都会同步发变更通知，SwiftUI 给 `@AppStorage` 挂的 `UserDefaultObserver` 就在**发通知的那个线程**上响应它，响应体里要 `Update.begin()`——申请 SwiftUI 的 UI 更新锁（`MovableLock`）；而主线程此刻正持着那把锁在渲染设置页，同一时刻要读 `store.serverURLString`、等 `MoviePilotStore.lock`。于是后台线程「持 store lock 等 UI 锁」、主线程「持 UI 锁等 store lock」，两边互等，永不恢复（不是慢，不会自己好）。`sample` 实录（0.2.0 482）：主线程停在 `SettingsView.body` 读 `serverURLString` 的 `NSLock` 上，后台 `MoviePilotAPIClient.signOut()` 的 actor 线程停在 `clearSession()` 里 `defaults.removeObject` 触发的 `Update.begin()` 上。三个旁证全部对上：**两端都复现**（共享代码）、**永久卡死**（真互等）、**只有 MoviePilot 卡**（`BangumiContext` 是 `@MainActor`、Jellyfin 登出在主线程，两者的 store 写入天然在主线程）。另有一处更隐蔽的地方让它是无条件必现：`removeObject` 删一个**不存在**的键同样发通知（现场两个 legacy 键都早已不在）。修法：`MoviePilotStore` 的所有 `UserDefaults` 写入收进唯一落点 `mutateDefaults(_:)`——在主线程就直接写，在后台就投到主线程补做（补做时照常持锁），既不阻塞也不丢弃；真值（地址 / 用户名 / 密码 / 开关）的调用点全在主线程，能从 actor 上走到的只有「历史残留键清理」这类没有时效要求的写入。**推迟删除带来一个新窗口，同轮一并堵掉**：旧令牌键的删除被推迟的那几毫秒里，凭据文件已空而旧键还在，迁移分支会把刚作废的旧令牌搬回去——等于登出静默失败。为此加一把会话内的一次性闩 `legacyTokenRevoked`（清令牌统一走 `clearTokenUnlocked()`），此后读路径一律不认旧键；顺带把 `accessToken` 读写路径里重复的一份迁移逻辑收敛成一个 `accessTokenUnlocked()`。验证：新增两个回归用例——`testClearSessionFromBackgroundThreadKeepsDefaultsWritesOnMain`（从 `Task.detached` 调 `clearSession`，断言变更通知不落在后台线程、残留键仍被清掉）、`testClearedTokenIsNotResurrectedFromLegacyKeyWhileRemovalIsDeferred`（主线程故意占住，把「推迟删除」的窗口做成确定性可见），并**两个都做了反向验证**：临时退回直写，前者立刻报「2 次后台写入」（与 sample 现场逐条吻合）；临时摘掉闩，后者读回 `stale-legacy-token`。`swift test --package-path Packages/MoviePilotKit` 57 用例全绿。顺带记录同形状的隐患（**未改逻辑**）：`BangumiStore` 的 `auth` setter / 迁移读也会持锁写 `UserDefaults`，且 `BangumiAPIClient` 是 actor（`store.auth = …` 在后台线程）——目前够不着那条环，只因为没有任何视图在 body 求值里读该 store（`BangumiContext` 把 UI 要用的都存成了 @Observable 存储属性），已在类型注释里写明「别在 body 里读 `store.*`」以及届时的改法。
- **修「iOS 切后台回来播放器直接报错，只能点重试」（`playback error: ffmpeg error … avcodec_send_packet: Unknown error occurred (-1313558101)`）**。根因是挂起往返本身：App 没有后台音频能力（`Info.plist` 无 `UIBackgroundModes: audio`，App 层也不配 `AVAudioSession`），进程进后台几百毫秒就被系统冻住，而内核的音频出口（iOS 上是 AudioQueue）与 VideoToolbox 解码会话醒不过来——回前台第一包数据喂进 `avcodec_send_packet` 就是 AVERROR_UNKNOWN，播放器被钉死在错误态；原来的前后台钩子只做进度上报，既不拦也不恢复，只能靠用户手动重试（重建内核）。修法三段：①**进后台先停**——`PlaybackController.beginSystemSuspension()` 在进程被挂起前主动暂停在播会话（`.playing` / `.ready` 都算「用户离开时正在看」；open 在飞或本来就暂停时不动引擎），并带回「回前台接着播」的意图；②**回前台接回去**——`AppModel.playbackDidEnterForeground()` 按意图 + 当前状态决策（纯函数 `foregroundResumeAction`）：内核算健康就解开那次暂停；内核没撑过挂起（`.error` / `setupError` / `play()` 都没调成）就走与「重试」相同的重建路径静默重建——Jellyfin 条目重走完整 `play()`，本地文件 / 直连以**同一个 request id + 当前内核位置**重开（刻意不走 `retryPlayback()` 的「≥30s 才算续播点」启发式：那是给用户手动重试防片头误判的，系统往返里位置退到 0 重来才是 bug）；③**恢复后补 3 秒观察窗**（250ms 一拍）——解码器坏掉的第一现场未必在 `play()` 当场落地，而是恢复后第一包数据上，窗口内落进错误态就做一次静默重建，仍失败则按普通错误交给错误徽章，不循环重试。自动动作只发生在「离开前确实在播」的这一次往返里，播放中用户自己按的暂停不受影响；macOS 不挂起进程，这条路径整个空转。顺带修同族的一处误判：open 看门狗按墙钟算 60s，切后台期间进程被冻住而墙钟照走，「点完播放就切走再回来」会被判「连接媒体服务器超时」——现在挂起时长从 open 的账上扣掉（`openElapsedMilliseconds`），看门狗没到点只补睡差额。验证：iOS 模拟器 `OcPlayerTests` 全绿（含新增 `AppBackgroundPlaybackTests`：回前台决策表全组合 + 无控制器 / 未在播时钩子必须空转）；macOS 构建与测试通过。真机续播效果待设备回归（挂 `playbackDidEnterBackground/Foreground` 与「后台往返后自动重建播放」诊断行，日志可查）。
- **修「呈现式页面的返回键点了没反应」（下载管理 / 资源搜索 / 管理服务器 / 开源许可证）**。常规布局（macOS / iPad 常规宽度）的顶栏返回键是自绘的 `AppShellBackButton`，它只会调 `AppModel.back()`；而 `back()` 的落地是 `path.removeLast()`，并有 `guard !path.isEmpty else { return }` 守卫。`navigationDestination(isPresented:)` 呈现的页面（下载管理、资源搜索、管理服务器、开源许可证）**根本不在 `path` 上**——`isPresented` 是另一套呈现机制，栈里看不到它，于是守卫直接把这次点击吞掉：淡出都不发生，按钮像没绑事件。修法：新增 `AppModel.popPresented(_:)` 作为 `pushPresented(_:)` 的对称出口（同样走两段式，`restoreDelay` 与 `back()` 取同一档），并给自绘返回键补一个可选的 `presented: Binding<Bool>`——非空时走 `popPresented` 关掉页面自己的落地开关，为空时维持 `back()` 弹栈。六个调用点全部接上（`appShellBackChrome(title:presented:)` 新重载）：MoviePilot 首页的下载管理与资源搜索、详情页 MoviePilot 区块的资源搜索、资源搜索页的「添加下载成功后跳下载管理」、设置页的管理服务器与开源许可证——后两个是同源同病的既有 bug，一并修掉。顺带两处一致性：①呈现式页面此前没有任何离场过渡（不在路由出口 `appRouteView` 上，没人替它挂 `routeExitFade`），返回是「等 0.45s 再硬关」，现在由 `appShellBackChrome(title:presented:)` 按 `presented` 非空补挂，与路由页同一个 `Motion.exit`；②资源搜索页自动跳转的下载管理此前裸用系统返回键（与其它入口的顶栏不一致），现统一为 `appShellBackChrome(title: "下载管理")`。验证：macOS Debug / iOS（模拟器）构建均通过；`OcPlayerTests` macOS 套件 244 用例全绿，含新增回归用例 `testPopPresentedDismissesWhileBackIsNoOpOnEmptyStack`（钉住「空栈上 `back()` 是空操作、`popPresented` 必须真的关掉开关」这一形状）；macOS 实机点按确认下载管理页返回键恢复。

- **修测试宿主被「stderr → os_log → stderr」自激循环拖死（iOS 测试步骤在 CI 上从未绿过的根因）**。`KernelStderrPump`（GUI 启动时劫持 fd 2 接内核 stderr 进诊断管线）在测试宿主里也照常启动，而 iOS 模拟器的测试宿主会把进程 os_log 回声到 stderr（Xcode 控制台显示 os_log 就靠这条通路）——`record()` 把读到的行写进 os_log，回声落回 fd 2 被泵再读、再写 os_log：无限自激，每圈包一层时间戳前缀（此前测试日志里看到的嵌套行就是它）。后果：①CI 的 iOS 模拟器测试步骤自 9/22 加入起一次都没跑完过——宿主启动后零输出，挂满作业超时被取消；②本机表现为测试跑到一半宿主被静默带走，xcodebuild 假报 TEST SUCCEEDED（实际只执行了 102/229、129/229 等）；③logd 被灌爆的时段系统守护进程连环崩（与「每次测试都弹」的 WidgetRenderer/chronod 崩溃弹窗时间强相关）。修法：测试宿主（`XCTestConfigurationFilePath` 判定，与日志目录改写同款）不装泵——测试要的是解码器本身（`KernelLoggingTests` 直接喂 `KernelStderrDecoder`），不需要劫持 fd 2。修后 iOS 套件 229 用例一次跑完全绿、回声嵌套归零；macOS 套件 228 用例全绿不受影响。

## [0.2.0] · 2026-09-29 · 双端导航外壳重做与氛围背景贯通、弹幕匹配精准度、内核换装官方 v0.2.0

### 改动

- **氛围页卡片统一改半透明；iOS 设置页分组底清空（与 macOS 观感对齐）**。macOS 靠整窗氛围层垫底，页面透明处透出轮播图；但页面自己的卡片用 `.background.secondary` 实心底把图挡死（Bangumi 进度卡 / 搜索行 / 日历骨架、条目详情五处卡片），iOS 设置页更是一片死白——`Form` 的 grouped 行底是系统不透明白，`scrollContentBackground(.hidden)` 只管列表底、管不到行底。改动：①Bangumi 各处卡片与 `HoverRowHighlight`（搜索结果行 / 日历行）底改 `.ultraThinMaterial` 磨砂，透出氛围图；②iOS 设置页逐 Section 清空行底（新增 `settingsRowBackground()`，`#if os(iOS)` 限定），分组结构交给 Section 标题与分隔线表达，行直接浮在氛围图上（同 macOS 分组观感）。**踩坑记录**：`.listRowBackground` 挂在 `Form` 上在 iOS 完全不生效（行底是逐行的 trait，`Form` 自己是容器，写在它外面的值传不到行）——期间试过整档材质 / `glassEffect` / 按外观调透明度，因为修饰符没生效，观感差异全部来自轮播换片的错觉，最后用「行底涂红」实验才定位；且材质与 `glassEffect` 浅色下本身偏白（`.home` 遮罩浅色档本就盖 55%–66% 白雾），叠加仍是死白，故最终取全透。验证：iPad Pro 13″ 模拟器（iPad-repro）深浅色截图，与 macOS 设置页并排对比一致；OcPlayerTests iOS 全绿（229 用例）；macOS 构建通过。

- **自动化：启动直落分区（`OCPLAYER_START_SECTION` / `OCPLAYER_SECTION_SWITCH_SECONDS`）**。本机 Xcode 无 `Simulator.app`（模拟器只能无头跑），点按导航不可用，截图验收需要「进场即到目标页」的通道。`LaunchOptions` 增两个环境变量：`OCPLAYER_START_SECTION=home|bangumi|moviepilot|settings` 直落分区；配合 `OCPLAYER_SECTION_SWITCH_SECONDS=<秒>` 先留首页跑轮播（`homeAmbience` 要轮播加载后才非 nil）再切过去，避免冷启直奔某 Tab 时看到纯色底、误判背景没生效。`simctl launch` 传参需加 `SIMCTL_CHILD_` 前缀。

- **iOS 端 Bangumi / MoviePilot / 设置三个 Tab 补上氛围背景图**。macOS 靠整窗层把首页轮播垫在所有页面后面，这三个页自身透明所以都有背景；iOS 的 Tab 宿主不透明、轮播又只挂在首页 Tab 里，其余 Tab 一直是纯色底。改为三个 Tab 的根页面统一从 `AppModel.homeAmbience` 取轮播当前那张垫底（`BackdropAmbienceView` + `.home` 遮罩，与首页同参）——跨 Tab 背景连续、轮播换片时同步渐变，也不多拉一次图（图本就在内存缓存里）。设置页是 `Form`，其 `scrollContentBackground(.hidden)` 已在此前 macOS 轮就加好，分组底透明、氛围图直接透出。注意：TabView 未访问的 Tab 不会实例化，冷启直奔某 Tab 时 `homeAmbience` 还是 nil、该 Tab 暂为纯色底，回首页轮播跑起来后即恢复。验证：iPad Pro 13″ 模拟器逐 Tab 截图（Bangumi / MoviePilot / 设置三页背景在位）；OcPlayerTests iOS 全绿（229 用例）；macOS 构建通过。

- **iPad 推入页恢复显示顶部 Tab 胶囊（撤销 push 页收起胶囊）**。此前为避免「胶囊 + 返回键/标题」两行顶栏，在 push 页挂 `.toolbar(.hidden, for: .tabBar)`；实测（iPad mini，iPadOS 26.6）胶囊的收起发生在**推入动画结束之后**且不带过渡——推入过程中胶囊还在、返回键与标题被压在它下面，结束才消失 → 标题「从下一点的位置闪回顶部」。先后试过挂在路由页与挂在导航栈（按栈的 path 驱动）两种挂法，真机上时机都改变不了；iOS 27 模拟器则是推入首帧即收起（两版行为差异在系统版本）。系统 TabView 内无法根治，故撤销隐藏，回到系统标准形态：推入页顶部 = 胶囊 + 返回键/标题两行，全程稳定无闪烁（录屏逐帧确认：推入中与落定后胶囊、标题位置一致）。`hidesTabBarWhenRegular` 一并移除；若日后要「只有一个顶栏」，出路是 iPad 弃用系统 Tab 栏改用 macOS 同款外壳（见上一轮评估）。**并按需求去掉推入页的标题**（iPad 常规宽度）：`.navigationBarTitleDisplayMode(.inline)` + `.toolbar(removing: .title)`——页面头部自己有名字（详情页 Logo / 库页网格），顶栏只留胶囊 + 返回键。验证：iPad Pro 13″ 模拟器录屏 + 截图（推入页顶栏 = 胶囊 + 返回键，无标题）；OcPlayerTests iOS 全绿（229 用例）；macOS 构建通过。

- **iPad 进详情页不再「先黑一下」：入场动画收成 macOS 专用 + 背景从首页延续进来**。两处根因，都在 iOS 上被实测确认（iPad Pro 13″ 模拟器录屏逐帧量，30fps 亮度均值 0–255）：①`pageEntrance`（首帧 opacity 0 → 0.2s 淡入）是为 macOS 写的——macOS 系统 push 会被同帧的整窗氛围声明 / 工具栏重建吞掉，页面得自带过渡；iOS 的系统 push 本来就有滑动，再叠这层等于在滑动中多出几帧「整页透明」，露出底层黑底（实测亮度直落 **17**，落地页稳定态 34）。守卫放在 `PageEntranceModifier` 内部（`#if os(macOS)`），全仓 7 处调用一处覆盖。②更主要的那层黑：详情页背景是 backdrop@800，冷启必走一次网络；iOS 的导航栈宿主不透明（**栈后面垫一层到不了屏幕**，用醒目测试色实测确认，所以 macOS 那套「整窗层垫在栈后」在 iOS 复制不了），页面只能自己画底色，而暗色下 `Color.pageBackground` 就是黑。改为：**页面内做背景延续**——底图未就绪时先画首页轮播当前那张（`AppModel.homeAmbience`，由 `AmbientBackdropCarousel` 声明；与首页同 URL、同档解码，内存缓存命中，瞬时可画），自己的底图到位后由 `RemoteImage` 的 preserveCurrentImageOnReload 原位缓慢淡入替换。为此 `BackdropAmbienceView` 加 `fade` 参数：兜底那张用短淡入（默认的 1.6s 在推页那 0.35s 里只走到 ~25% 不透明度，观感等于没兜住），换成自己那张时仍走 `Motion.ambient` 缓慢渐变。实测转场：黑窗从「直到自己的底图到位（~1.5s）」缩到 ~0.3s，且背景与首页连续（抽帧确认：推入 → 首页那张 → 自己的底图）。**残留 ~0.3s 已根治**：兜底图虽是内存缓存命中，但 `RemoteImage` 也要异步加载再淡入，推页那零点几秒里背景仍是页面底色（夜间闪黑、日间闪白）。改为 `RemoteImage` 初始化时对内存缓存**同步**出图（命中即以位图初始化 `image` 与 `loadedKey`，加载任务直接跳过），推入页第一帧背景就是首页那张。实测推入逐帧亮度：100→91→84→77→71→66→70，全程平滑、最低 66 不低于落地页（70），黑/白闪消失。此改动在共享组件 `RemoteImage` 上、全仓生效：任何命中内存缓存的图首帧即出（此前一律异步 + 淡入）。验证：录屏逐帧对比 + 抽帧；OcPlayerTests iOS 全绿（229 用例）；macOS 构建通过（该平台走整窗层，未动）。

- **修「搜索 Tab 切走再切回后输入框消失」**。iOS 26/27 的导航栏搜索框默认「随滚动收起」，而搜索页正文不是 ScrollView（空态 `SearchEmptyState`）就是可滚动列表（`HomeSearchContent` 的结果）——正文里只要存在 ScrollView，**切到别的 Tab 再切回搜索 Tab，输入框会被系统收掉且不再恢复**（表现为搜索页只剩标题 + 空态，没有任何输入入口；首次进入搜索 Tab 是正常的）。二分实测（模拟器真机点击驱动 DeviceHub 镜像）逐项排除：外壳（TabView / 选中绑定 / path 绑定 / `appRoutes()` / Bangumi、MoviePilot 两个条件 Tab）都无关——把搜索页正文换成纯文本，切回来字段照样在；正文换成 `SearchEmptyState`、只加 `.scrollDisabled(true)`、换成内容超高的可滚动列表，三者都会丢字段。修法：搜索页 `.searchable` 改 `placement: .navigationBarDrawer(displayMode: .always)`（iOS 15+ 的「字段常驻、不随滚动收起」，非 iOS 26 新 API），字段位置与观感不变、结果列表滚动时也不再收起。验证：iPhone 17 模拟器两次「首页 / MoviePilot → 搜索」往返输入框均在位；OcPlayerTests iOS 全绿（229 用例）；macOS 构建通过（该 placement 仅 iOS，`#else` 分支保持原 `.searchable`）。

- **macOS 搜索入口修复 + 搜索实现两端共用**。上一条把搜索整体搬到 iOS 搜索 Tab 时，macOS 的搜索框（原挂 `HomeView.searchable`，窗口工具栏里那个）失去消费方，一并消失——本次补回：搜索结果区抽成两端共用的 `HomeSearchContent(query:)`（词由外部 `.searchable` 经 binding 传入，防抖与「词变了作废在途请求」改由 `.task(id:)` 承担，少一层手工 debounce 状态），iOS `HomeSearchView`（搜索 Tab）与 macOS `HomeView`（`#if os(macOS)` 的工具栏搜索框）各自提供入口与未输入提示，空态载体提为文件级 `SearchEmptyState`。两个平台各自实测：macOS 导航栏搜索框输入「朋友」命中并渲染海报墙（氛围背景正常）；iOS 测试全绿。结论同时明确：**Tab 化导航与搜索 Tab 都是 iOS 形态**——macOS 的分区入口是窗口工具栏玻璃药丸（Safari 式），`Tab(role: .search)` 在 macOS 上无对应呈现，继续保持两套外壳、共用业务实现。

- **修 iPhone 搜索点 X 收起后被系统重新展开（循环关不掉）**。上一条给首页补的 `.searchToolbarBehavior(.minimize)` 触发系统宿主互扰：iOS 27 模拟器逐帧复现——点 X 收起 0.4s 后搜索框自动弹回（文字保留）；二分实验（去掉 `.toolbar` 按钮组 → 不再重开；按钮组合/分拆无关）确认触发条件是「导航栏里存在任何 primaryAction 工具栏项 + minimize 搜索」，属导航栏搜索的宿主行为，应用侧绕不开。改用 Apple 规范化做法 **`Tab(role: .search)` 搜索 Tab**：搜索词 / 结果 / 分页状态整体从 `HomeView` 迁到新 `HomeSearchView`（同文件），`AppModel` 增 `Section.search` 与 `navPaths.search`，`compactLayout` 的 TabView 迁到 `Tab` API（`Tab(role:)` 要求全量 Tab 语法，不能与 `.tabItem` 混用）。搜索页 `navigationBarTitleDisplayMode(.inline)` 让字段常驻（大标题模式下 iPhone 会藏进下拉）。验证：模拟器驱动完整路径——搜索 Tab 进入 → 输入 → 点 ⊗ 清除（字段保持）→ 点 X 收起（0.5s/1.2s/2.5s 三帧均保持收起）→ 切回首页正常；搜索请求与空态渲染正常；OcPlayerTests iOS 全绿；macOS 构建通过（常规布局的搜索入口未动）。

- **iPhone 首页补常驻搜索钮**。`.searchable` 在 iPhone 上默认收进下拉，顶部工具组里没有放大镜（iPad 常规宽度本就渲染成搜索钮）；`.searchToolbarBehavior(.minimize)` 后两端一致——顶部玻璃组 = 打开 / 刷新 / 搜索。验证：iOS 27 双端模拟器截图确认。

- **iOS 撤掉底部「媒体库」Tab**。首页「媒体库」栏（`1112b78` 新增）已经是媒体库的唯一入口，Tab 是重复出口；`Section.libraries`、`navPaths.libraries` 与 `MediaLibraryListView` 一并摘除（`Route.library` 保留，首页栏仍走它 push 单库页），`AppModelLifecycleTests` 的清栈断言改指 `navPaths.bangumi`。验证：iOS 27 iPad Pro 13″ / iPhone 17 Pro 模拟器截图确认 Tab 只剩 首页 / Bangumi / MoviePilot / 设置、首页媒体库栏照常进库；OcPlayerTests iOS 全绿；macOS 构建通过。

- **iPad 撤顶栏药丸，分区切换改用 iPhone 同款 Tab；顺带修 iOS 首页氛围背景不显示**。顶栏药丸方案在 iPad 上从未真机验证过（当时仅编译验证），实测两处都坏：iOS 导航栏自带白底玻璃条，`.principal` 里的自绘玻璃组既不是悬浮药丸也不是 Mac 观感；氛围轮播垫在导航栈外的 AppShell 根节点 `.background` 里，被 iOS 不透明的 UIKit 宿主挡住整层到不了屏幕（iPhone 首页同病——`dd15527` 把轮播上移出页面时在 iOS 上就已不可见，`WindowAmbience.reachesScreen == false` 的判据早就写明 iOS 宿主不透明）。修法：①`AppShellView.layout` 收敛为 macOS 走顶栏药丸（`splitLayout`）、iOS 一律走 `compactLayout`（TabView）——iPad 分区切换、返回键、详情页顶栏全部回归 iPhone 同款系统行为，内容列宽仍按常规宽度取值；②AppShell 根节点的整窗氛围层改为 macOS 独占，iOS 首页轮播垫回首页 Tab 栈内页面 `.background`（布局隔离挂载——做成 ZStack 兄弟节点会复现 macOS 侧栏时代「ignoresSafeArea 撑大根布局、内容列顶出屏幕」的坑，本次实测复现后改 `.background` 消除）。AppShellChrome 的 iOS 顶栏分支随之不再可达，暂留待方案稳定后清理。验证：iOS 27 iPad Pro 13″ / iPhone 17 Pro 模拟器截图——iPad 顶部悬浮玻璃 Tab 胶囊 + 氛围背景满窗透出（含 Tab 栏玻璃下）、首页内容列边距恢复，iPhone 首页背景回归；macOS 构建通过（顶栏药丸路径未动）。

- **换页两段式转场 + pop 返回补过渡（`pageEntrance` / `routeExiting` / `routeReturning`）**。此前 macOS 上系统 push / pop 均被同帧的整窗氛围声明 / 工具栏重建吞掉（实测 1 帧硬切），只有详情页有自绘入场，其余 push 页面进出全是硬切，顶栏分区切换的交叉淡入也不可见。现统一为：①AppDesignKit 新增 `.pageEntrance()`（纯淡入，reduceMotion 经 `.motion` 直切），挂 `appRouteView` 路由出口覆盖全部路由页。②新增 `Motion.exit`（0.45s）退场 token：点击后当前页先整体淡出（`RouteExitFader` 读 `app.routeExiting`，挂在栈根与每个路由页上，从哪层发起哪层淡出），淡出完成才落地 push（`AppModel.beginRouteExit` 统一延迟落地，转场期间忽略新点击防连点）。③**pop 返回与 push 对称（自绘返回键）**：系统返回键的 pop 点击即系统级滑出，不经 binding 拦不住——常规布局把返回键自绘（`AppShellBackButton`，同位玻璃胶囊，`navigationBarBackButtonHidden` 换掉系统键），点击走 `AppModel.back()` 与 push 完全相同的两段式（淡出 0.45s → 禁动画 transaction 弹栈 → 落点页淡入）；compact（iPhone）保留系统返回键与侧滑返回。④**分区切换**同样走两段式：顶栏药丸改 `AppModel.switchSection`，当前页淡出后换分区（`selectedSection` didSet 清栈照旧），落点经同一淡出层淡入；compact（iPhone Tab）与 reduceMotion 直切。为此把 7 处 `NavigationLink(value:)`（媒体库列表、Bangumi 首页搜索行 / 进度卡、收藏列表、个人页、日历、章节区）换成 Button 走统一 `open*` 入口；设置「管理服务器…」「开源许可证」与 MoviePilot 顶栏「下载管理」、订阅卡 / 右键菜单 / 搜索结果「查资源」/ 详情页 MoviePilot 区块的资源入口改 `pushPresented` + 页级 `isPresented` + 目标页 `pageEntrance`。详情页私有入场实现撤除改共用版；落地恢复加前置拍（`Motion.restoreDelay` 0.05s）：新页先以隐藏态提交一帧、`pageEntrance` 首帧锚定后再翻 `appeared`——否则新视图与复位同帧出生（透明度无 from-state）+ onAppear 与首帧渲染合并，入场被吞成硬切。**修播放后背景丢失 / 首页透过详情页漏出**：播放器开合会翻转窗口工具栏可见性（`RootView` 的 `.toolbar(.hidden, for: .windowToolbar)`），重放 shell 生命周期——栈根 `pageEntrance` 重挂载即 `appeared=true`，首页透过透明详情页漏出、详情页氛围声明被清成「背景丢失」。栈根显隐改 **path 驱动**（`app.path.isEmpty`，栈里有页面即隐藏），与生命周期解耦；`pageEntrance(initiallyVisible:)` 参数随之移除。顶部工具栏按钮不参与过渡：分区药丸、自绘返回键、自绘标题与右侧系统工具项（打开 / 刷新 / 排序 / 添加订阅 / 下载管理 / 更多）统一走 NSToolbar 原生换项行为（与系统按钮一致，即换即现，无自定义淡出）——`routeExitFade` 只挂在页面内容上，导航条不挂。淡出层挂玻璃**外**（胶囊整颗一起淡，不是只淡内容）；顶栏标题文字系统渲染无过渡钩子，**push 页**常规布局改自绘（`appShellBackChrome(title:)`，`toolbar(removing: .title)` 隐藏系统文字，标题与返回键同一工具栏项保证顺序）参与淡入淡出，无同步名称的页面（如异步加载的 Bangumi 条目）保持系统标题；**根页面保持系统标题**——首页有 `.searchable` 搜索框与副标题都是系统渲染、无过渡钩子，自绘标题会把工具栏布局挤歪且只能淡一半，观感更差。右侧工具项（打开 / 刷新 / 排序 / 添加订阅 / 下载管理 / 更多）**保持系统按钮不参与过渡**（试过隐藏系统共享底 + 自绘胶囊让整颗淡入淡出，观感代价大于收益，回退）——系统共享玻璃底不随内容淡出会留幽灵胶囊，所以这些项不做淡出，随 NSToolbar 换项原样进出；搜索框为纯系统渲染，保持原样（无钩子，系统限制）。compact（iPhone）系统 push / present / pop 动画本来就在，直切不等待；MoviePilot 下载页的自动跳转（添加下载成功后）不属于点击导航，保持即时。遗留：切分区时顶栏按钮组整体换入换出是 NSToolbar 层重建，SwiftUI 无过渡钩子（按钮高亮随 0.45s 淡出后切换）；订阅 sheet 内与开源许可证内的深层子页仍是系统 push。验证：`OcPlayer-macOS` 与 `OcPlayer-iOS`（无签名）Debug 构建均通过；转场节奏待实机复核。

- **修详情页入场闪跳（背景图「闪一下变大再恢复」+ 进页无过渡动画）**。逐帧录屏定位到三个叠加问题，一并修掉：①**氛围背景随位图加载可见地缩放沉降**——`RemoteImage` 的位图以 `scaledToFill` 直接当 ZStack 子层画、参与布局：位图到位瞬间容器理想尺寸从「无比例」跳到「图片覆盖尺寸」，这个几何变化被氛围层挂着的 1.6s `Motion.ambient` 动画播成一段可见的缩放（裁剪窗口从紧到松，逐帧可见背景先「大」再沉降回正常）；图走网络必现、命中缓存发生在最初几帧所以「有时候」才看见，首页轮播 12s 换片同病。修法：位图一律画进 `.overlay`——overlay 不影响宿主尺寸，图到位只剩纯淡入。②**点击进详情页 1 帧硬切、无过渡动画**——系统 push 被同帧的整窗氛围声明 / 工具栏重建吞掉（录屏实测 5.83→5.90s 直接换页）；且 `isLoading` 把整页压到 0.86 透明度、数据落地再提亮，本身就是一次亮度脉冲。修法：去掉全页透明度脉冲，页面自带入场动画（内容淡入 + 12pt 上移落位，`reduceMotion` 自动直切），无论系统 push 是否被吞都有一段可见统一的过渡。③**氛围层灰占位淡入**——氛围声明改为底图预热完成后才发出（与氛围层完全同参预热：800 宽 URL + 512 解码，`DetailViewModel.prewarmAmbience`），淡入时图已就绪；取图失败保持不声明，回退纯色底。另给 banner↔ambient 头部布局切换（从续播 / 接下来看点进、占位条目无 backdrop tag 时触发）加交叉淡入，不再硬切跳变。已知遗留：进详情后顶栏右侧搜索框等首页工具栏项残留约 1s 才消失（NSToolbar 重建滞后），待观察是否与 push 被吞同源。验证：macOS Debug 构建通过、OcPlayerTests 全绿；实机复核入场过渡与背景稳定性通过。

- **常规布局撤掉侧栏，导航改顶栏玻璃图标组 + 独立「媒体库」按钮**。macOS / iPad 原来靠 `NavigationSplitView` 侧栏承载分区入口（首页 / MoviePilot / Bangumi）、媒体库列表与底部「设置」行；现在侧栏整列让给内容：分区收进顶栏**一组纯图标按钮**（共用一个液态玻璃圆角容器，当前分区带强调色底，版式对着 macOS 26 Safari 工具栏那组做——图标化后整组宽度只有原来文字版的三分之一，标题与搜索框不用再抢位置），媒体库**单独一颗同款按钮**（带小箭头，与 Safari 的「历史记录」按钮同一处理），点开弹出各库列表、当前库打勾，库拉取失败时在面板里给原因与重试——这段原本住在侧栏里，撤栏后必须跟着搬，否则「媒体库拉取失败」在常规布局下就彻底没有出口。已经在某个库里时按钮换成该库的类型图标 + 强调色底，一眼能看出身处哪个库。iPhone 底部 Tab 不变；两个集成的启用开关照旧门控对应按钮的显隐（停用瞬间选中回落首页）。

  **顶栏挂载点分两端**：macOS 挂**窗口工具栏**（`AppShellView` 根）——工具栏属于窗口而不属于某个栈，push 进详情页后这组按钮照样在，换页不必先返回；iPad 挂每个导航栈的根内容（导航栏由栈自己提供，`.principal` 居中）。`AppModel.Section` / `appRoutes()` / `RootView` 的播放覆盖层都没动。

  实现上踩到并记录两处：①**玻璃 tint 会晕开**——给选中段上 `.glassEffect(.regular.tint(...))`，颜色会顺着 `GlassEffectContainer` 的取样区域扩散，`.red` 全不透明时整条工具栏被染成粉红；而 0.55 的强调色 tint 又淡到与未选中段肉眼无差（两次实测截图对比）。选中 / hover 底最终改为**圆角矩形内的半透明填充**，落在内容层，清晰、不晕、深浅色模式下都稳。②**系统不给自定义工具栏视图提供玻璃**——把 `.glassEffect` 摘掉后按钮完全没有底（不是「双层玻璃」，HomeView 注释里那条警告只针对系统已上玻璃的标准控件）。另同步文案：设置页三处「侧栏」改「顶栏」，首页空态文案改指顶栏的「媒体库」按钮。

  验证：macOS Debug 构建通过；实机截图确认首页顶栏渲染（图标组 + 媒体库按钮）、经 AXPress 打开媒体库面板列出电视剧 / 电影 / 合集、切到「设置」后选中底与窗口标题同步跟随。**iPad 端只有编译验证**（`OcPlayer-iOS` scheme，无签名构建），未在真机 / 模拟器上跑过。

- **修 AppTests 的崩溃型 flaky（内核 stderr 解码压实回归测试）**。`KernelLoggingTests.testDecoderDoesNotRetainConsumedBytes` 有两处独立缺陷：①**进程崩溃**——`Self.mallocInUseBytes() - before` 是两个 `UInt64` 相减，而 `malloc_zone_statistics` 量的是进程级活内存、循环里既分配也释放，`after < before` 时下溢、当场 SIGTRAP（`Swift runtime failure: arithmetic overflow`）。表象极具误导性：**0.000 秒「失败」、无任何断言文案**，实为测试宿主进程被打崩；实测 5 轮崩 2 轮，崩溃报告 `OcPlayer-*.ips` 从 17:16 起共 8 份全是这一个测试。改用有符号差值。②**阈值假失败**：崩溃一直在掩盖断言抖动——2 MiB 阈值对进程级统计太紧，实测同代码 grown 跨四个数量级（272 B / 1.0 KB / 1.4 KB / 2.6 KB / 2.8 KB / 6.4 KB / 176 KB，另 4 轮为负；两轮顶到 2.23 MB），约 11% 假失败。阈值提到 8 MiB：真正的回归是「留住整条流」≈ 12 MB（生产实测 60 MB+），仍接得住。**试过并否决的替代方案**：把迭代数从 20 万提到 100 万以放大信号——实测噪声与分配次数近似成正比，100 万次下噪声跟着涨到 14.2 MB（n=6：2.2 KB / 7.4 KB / 11.9 KB / 2.9 MB / 2.9 MB / 14.2 MB），信噪比没有改善，故维持 20 万次。修后完整套件 222 用例全绿、崩溃报告 0 新增。

- **修 iOS 套件的时序 flaky（PlaybackControllerOpenTests）**。`testPauseIntentDuringInFlightOpenAppliesPauseAfterSuccess` 在 iOS 模拟器上偶发「前置：open 应处于在飞」等不到：open 的完成回调要经主线程 Task 才把**进程级**在飞计数 `activeOpenAttempts` 减回去，而测试方法返回时这些回调可能还没落地——前一个用例（`testOpenWorkersHaveABoundedCapacity`，恰好把 2 个在飞槽占满）刚一结束，下一个用例的 open 就撞上「后台媒体打开任务已满」直接走失败分支（引擎零调用、`openingRequestID` 从未赋值，与现场断言逐条吻合；macOS 上时序快，从未暴露）。修法：`PlaybackController` 加 DEBUG 观察口 `activeOpenAttemptsForTesting`，测试类 `setUp` 改 async、开跑前先把计数排到 0（最多等 3 秒，等不到就让该失败的用例自己失败）。

- **修「库内搜索后切走再回来只剩搜索结果」**。分页缓存的键只有 `libraryID`，而库内搜索是把结果**原地**写进该库那一格：搜「败犬女主」→ 点进详情 → 回首页 → 再点该库，`LibraryView.searchText` 是 `@State`、视图重建后已空，缓存里却还是那几条 → **搜索框空着、网格只剩当初搜出来的几个**，且没有任何入口能切回浏览页（只能重新搜一次再清空）。给缓存键加上搜索词维度（`AppModel.LibraryPageKey`：库 + 词，空词 = 浏览页），浏览页与各搜索词各占一格，切走再回来各自还原。配套三处：请求发出时快照当时生效的词并用它写回对应格子（否则 await 期间改词会把第一个词的结果落进第二个词的格子）；`onChange` 同步切键，消掉防抖窗口里「框里是新词、内容还是上一个词」的中间态；旧搜索词的格子随新词作废丢弃（搜索框一次只装一个词、切库还会清空，旧格子再也读不到），浏览页与上限兜底逻辑保持不变。新增 2 个回归用例。**另修掉本次改动引入的打字闪动**：切键那一拍新格必然是空的，而 `isLoading` 还是 `false`，body 会落到 `items.isEmpty` 分支、满屏渲染「没有匹配」，每敲一个字闪一次空结果页（350 ms 防抖 + 网络往返的整段窗口）；改为切键时同步进入加载态，同一窗口渲染骨架屏。清空搜索框时也不再作废浏览页缓存重拉（那是「切走再回来」的落脚点，本就是有效的），避免「内容 → 空 → 内容」的白闪。

- **「海报氛围背景」开关移除，氛围图改为常开**。设置页「通用」分组的开关与 `SettingsKeys.ambientBackdrop` 一并删除：详情页与首页轮播不再有开关维度，条目有 backdrop 图即铺氛围底，没图仍回退清晰横幅（这条判断本就与开关独立，见 `DetailView.isAmbientActive`）。**老用户无迁移成本**：该键删掉后全仓库不再有任何读取点，盘上残留的 `false` 是死键——升级后氛围图照常出，不会出现「以前关了、升级后还锁在关」的状态。残留键刻意不主动清理：无读取点即无影响，为它加启动期清理反而多一条要维护的路径（已 grep 确认 App / Packages / AppTests 三棵树除本注释外无引用）。顺带修掉「删除只做了一半」导致的 **App target 编译失败**——`AmbientBackdropCarousel` 仍在读已删的 key（包测试全绿，错误只在 App target，所以此前没暴露）；并同步 README、详情页注释、`SettingsKeys` 头注释、设置页类注释里的过时描述。

- **自定义 User-Agent（播放器白名单服放行）**。设置 → **网络**新增「自定义 User-Agent（可选）」输入框：部分 Emby/Jellyfin 服开了播放器白名单，表现为能登录浏览、一拉流即被拒——把 UA 填成白名单内的播放器（如 SenPlayer）即可通过。**全局生效**（不按服务器档案分，所以 UI 在顶层「网络」分组而不是某台服务器的分组里）。三条请求发送口**逐请求**读取偏好（`ClientIdentity.customUserAgent`），设置改完即时生效、无需重连：Emby 裸传输层 `EmbySession.data` 与 Jellyfin SDK 出口 `JellyfinServer.send` 各按当时值加 `User-Agent` 头（登录 / 探活会话另在 `URLSessionConfiguration.httpAdditionalHeaders` 带会话创建时刻的值，**合并**已有头而不是整体赋值，避免吃掉调用方自带的额外头），播放拉流 `PlaybackController.openPreparedRequest` 把它随 `Authorization` 一起传给内核 `open_with_headers`。取值时剔除控制字符：`URLRequest.setValue` 遇到带换行的值会把**整条头**静默丢掉（不报错），用户会以为白名单 UA 生效了、实际发的是系统默认；粘贴 UA 常带尾随换行，所以是剔除而不是整值作废（作废同样会静默退回默认）。留空 = 系统默认，行为不变。测试：两端传输层各一条「自定义 UA 逐请求携带」用例 + 两条取值净化用例；UA 用例改为存旧值还原，不再无条件清 key。

- **媒体库站内搜索**。库海报墙页顶部新增搜索框（`.searchable`，输入防抖 350ms 后发服务端查询）：`MediaServer.itemsPage` 协议新增 `searchTerm` 参数，Emby 走 `/Items?searchTerm=`、Jellyfin 走 SDK `searchTerm`，搜索结果与排序 / 观看状态筛选 / 分页缓存（`AppModel.libraryPages`）全链路复用——搜索也是一种筛选，不另起结果页。切库自动清空搜索词（只在**真的换库**时清：`.task(id:)` 每次 appear 都重跑，比对 id 才不会把「搜到结果 → 进详情 → 返回」的搜索词和滚动位置一起清掉）；无结果时给专属空态文案。**检索粒度到剧集为止**：剧集库只按剧集条目名匹配，单集标题不参与检索（分集搜索刻意不做——服务端 `searchTerm` 对单集命中率低，且「搜到某一集」的落点应是剧集详情而不是直接播放）。防抖重载走可取消路径（`await load`），慢速连续输入不会并发堆请求；`load` 被取消时不再把加载态落下去——缓存已清空，「非加载态 + 空 items」会闪一帧空态。测试：两端「searchTerm 落 query」用例。

- **首页全库搜索**。首页顶部新增搜索框（`.searchable`，防抖 350ms 后发服务端查询），搜的是**所有媒体库**——`itemsPage` 不带 `parentId` 即全库检索（电影 + 剧集，与首页卡片粒度一致）；各库页的搜索框不变，仍只搜各自的库。结果以库页同款海报墙就地替换 rails，支持滚动翻页与失败重试（footer 的自动预取靠 `onAppear`，必须待在 lazy 容器里——非 lazy 的 ScrollView 内容只在加入视图树时触发一次，第 3 页起就不会再自动预取）；结果是瞬态数据，只住视图 `@State`，不进 `AppModel.libraryPages` 分页缓存（回首页就该回到 rails）。氛围背景修复：`.background` 的背景尺寸跟随被包内容，搜索的空态/错误态是抱紧内容的小块——打字瞬间背景塌成内容小块、出结果再撑开，肉眼可见地闪；顶栏玻璃底下没图还会变纯白（实测像素 (249,249,249)）。现搜索空态/错误态（连带首页加载失败态）改用 ScrollView 承载（`containerRelativeFrame` 垂直居中）——只有 ScrollView 的 frame 会自然铺到工具栏/侧栏玻璃底下，裸 EmptyState 连 `frame` 撑满 + `ignoresSafeArea` 都救不回来；背景全程满窗。`searchLanded` 落地门只用来区分「还在搜」和「搜完了」：本词结论落地前搜索区显示骨架屏，不抢跑闪一帧错误的「没有匹配」；但**不能**拿它把整个搜索态挡回 rails——那样手上还有旧结果时每改一个字都会整页弹回首页再跳回来（有旧结果就继续显示旧结果，新结果回来原地替换，改词全程不闪）。搜索失败文案走 `localizedDescription`：`JellyfinError` 是 `LocalizedError` 不是 `CustomStringConvertible`，插值会把 `JellyfinError(kind: …)` 反射串直接摆给用户。搜索在途时切服务器会清空搜索词回 rails，旧服务器的结果不落进新会话。（中途试过把轮播挪成 ZStack 兄弟节点：背景的 `ignoresSafeArea` 会把根布局撑到全窗宽，内容列铺进侧栏底下、换片闪屏，弃。）另按服务端实测在单字无结果时给引导文案：Jellyfin/Emby 的 `searchTerm` 分词对单字不匹配，两字以上的子串才命中。检索粒度同样到剧集为止（电影 + 剧集条目名，单集标题不参与），空态副文案里写明，免得用户以为搜坏了。搜索速度依赖服务端自己的索引（Jellyfin/Emby 的 `searchTerm` 查询本就打在服务端 SQLite 索引上），客户端不另建本地索引。

- **内核换装上游官方 `v0.2.0`，fork 阶段收尾**。Erika 上游把 fork 上先行的改动全部合入：v0.2.0 带入杜比视界 RPU 映射 / HDR tone-mapping / 感知色域映射管线（#136）、headless GIF 导出 `erika_export_gif`（#138，App 暂未接入）、HTTP(S) 持久流式预取（#139）。实测新 release 的 `erika.h` 与上一版 fork 内核（`v0.1.9+dolby.streaming.fix.dev`）**逐字节相同**——C ABI 无变化，App 侧零适配，持久流预取 / 预取窗口封顶 / 回退预算（`http_back_buffer_bytes`）语义与 0.1.9 记账一致，0.1.8 的慢源 A/B 口径（开播 13.2 秒、78.3 秒零卡顿）沿用。钉点切回官方：`Scripts/build-macos.sh` / `package-macos.sh` / `package-ios.sh` / `release.yml` / `test.yml` 删除 `ERIKA_REPO=fork` 默认值（`fetch-erika.sh` 默认上游即生效），`ERIKA_VERSION` 默认 `v0.2.0`，新增 `Scripts/erika-v0.2.0.sha256`（哈希取自 release 自带 `SHA256SUMS`，下载实校通过）。回归：ErikaKit 30 用例全绿（含真跑内核的离屏渲染与预读行为套件）。README 内核说明与 `PlaybackPreferences` / 预读行为测试的版本注释同步更新。

- **弹幕匹配精准度：规范名合成 + 集号 token 打分 + 类型硬门槛 + 手动搜索别名合并**。四件事都有生产/实测背书（对生产网关与官方 schema 逐条核对过）。①**合成文件名**：Jellyfin 源文件名是裸数字（`01.mkv`）时，旧实现合成 `番剧名 第N季 E05 01.mkv`——实测这种「E 标记与尾巴数字冲突」的形态会让弹弹play 的模糊匹配锁到「第1话」；现在统一走 `DanmakuFilenameParser.canonicalMatchName`（原名含番剧名就原样保留、只剥扩展名，否则合成规范名且不拼回原名），standalone 同修；缓存身份改用**原始**文件名，以后调合成规则不再让已记住的映射失效。②**集号 token 与特典**：弹弹play 把特典/OP-ED 放在同一作品下的 `S`/`C`/`O` 命名空间（实测 `episode=S2` 返回「S2 …」特典），旧实现的宽松兜底会把 `S5 聖地巡礼` 当成第 5 话——新增 `DanmakuEpisodeToken`（正片数字 / 特典命名空间+序号），season-0 条目按文件名关键词判定命名空间，特典候选对正片目标不再以集数命中；**特典目标不再拿 Jellyfin 序号发 `episode=S<n>`**（实测与弹弹play 的 S 序号不同源，序号 29 会唯一命中同 IP 剧场版的 S29），改走全集搜索让打分器选。③**类型硬门槛**：剧场版与剧集是不同作品，类型不匹配直接出局——用户实报的错匹配（中二病 S00E29 特典被同 IP 剧场版的 S29 抢走；旧打分在模糊与检索两条路径分别命中无关日剧第29话 1548 / 综艺第29话 1550）实测修复为 noMatch 手动选。④**手动搜索别名合并**：弹弹play 搜索认不得「另一个中文译名」（实测搜「虽然我是不完美恶女～雏宫蝶鼠替换传～」返回的全是无关作品），手动选弹幕时并发用 Bangumi 的 nameCN 换库内标题再搜一次、按 animeId 去重合并（Bangumi 首条实测即正确标题；解析结果永久缓存、负缓存 7 天，失败静默）。自动路径的 tier-1 文件名模糊对这类译名本来就有效（实测 rank 0 命中，新旧打分同分 2898）。**特典自动匹配的边界**：hash 未命中且本地元数据无身份信息（如「第 29 集」这种泛化名）时落 noMatch 手动选——元数据里没有的信息不该靠猜。测试：DanmakuKit 156 用例、AppTests 全绿；打分器用生产真实候选集离线复验（错匹配三路径全灭、正确 case 保持命中）。

- **Bangumi 登录改走 OcPlay 网关，客户端不再持有 OAuth 应用密钥**。授权地址由 `GET /v1/bangumi/oauth/authorize?state=` 拼（`client_id` / `redirect_uri` 在网关侧），换 token 与刷新走 `POST /v1/bangumi/oauth/token` / `/refresh`，业务 API（收藏、章节、搜索）仍直连 `api.bgm.tv`。`Secrets.xcconfig` / `Info.plist` 里的 `BANGUMI_APP_ID` / `BANGUMI_APP_SECRET` 随之删除——旧 secret 已进过构建产物，应在 bgm.tv 轮换。登录前置条件变成「网关地址 + 带 `bgm:oauth` 权限的 API Key」，与弹幕共用同一份设置（`AppModel.bootstrap` 与网关设置变更时推给 BangumiKit）；未配置时登录页给引导文案，网关错误码映射为对应提示（`SCOPE_REQUIRED` / `GATEWAY_NOT_CONFIGURED` / `OCPLAY_USER_AGENT_REQUIRED`，`BANGUMI_OAUTH_REJECTED` 清凭证回未登录）。`refresh_token` 仅在 Bangumi 轮换时返回，响应缺该字段时沿用旧值；`expires_in` 缺省时按一周兜底。BangumiKit 新增 5 用例（state 每次授权轮换且与请求一致、state 不匹配不发网络请求、换 token 只带 code 且请求带 `X-API-Key` + `OcPlay/` UA、网关 403 各错误码各自文案、refresh 未轮换时沿用旧 refresh_token），用按 host 分派的 mock URLProtocol 离线跑。对生产网关做过一轮真网络冒烟（跑完即删）：authorize 返回真 bgm.tv 地址、错误 code 与错误 refresh_token 都被 Bangumi 拒绝并正确落到「重新登录」。

- **修 `BangumiAPIClient` 的 403 分支丢掉响应体**（真网关冒烟测出来的）：403 曾直接抛 `notice("请求被拒绝，请检查权限")`，body 被丢弃，于是网关的 `SCOPE_REQUIRED` / `OCPLAY_USER_AGENT_REQUIRED` / `GATEWAY_NOT_CONFIGURED` 全都退化成同一句笼统文案。现在 403 走标准映射（`.forbidden(body)`，面向用户的文案与旧行为逐字相同），网关错误码才解析得出来。


### 修复

- **弹幕偶发「弹幕服务暂时不可用」**（先定因后修）。真实根因在生产网关：OcPlay Worker 偶发抛未捕获异常，CF 把它包成 HTTP 500 返回——CF 调用统计的 `scriptThrewException` 与 App 侧 500 逐分钟吻合，而网关自己的 D1 请求日志对此记的是 200（遥测在响应投递前落库，所以网关日志里永远看不到这次失败），此前按 502/503/504 口径接的重试因此全部漏接。叠加第二个成因：本机到网关的链路有 TLS 握手被重置的抖动（实测约 12%，直连甚至会整段黑洞），客户端对这类连接错误同样一次即弃。客户端修复：`DandanplayError.isRetryable` 把 500 与 `.cannotConnect` / `.secureConnectionFailed` 纳入重试集——匹配/搜索/正文全是幂等只读，实测同一请求秒级重试即成功（08:17 / 08:57 / 13:47 三次失败均由几十秒内的同一请求成功验证）；取消（-999）仍不重试，500 进集后编排层「网关故障短路剩余降级层」语义不变、重试耗尽才短路。GatewayClientTests 新增瞬态 500 与 TLS/连接类错误重试用例，编排层「500 一次即抛」用例断言翻转为耗尽 3 次尝试。网关侧的异常原文仍待取（CF dashboard → Workers Logs 或 `wrangler tail --status error`），拿到后再治根。

- **播放越久内存越涨、关掉也不回落：内核 stderr 解码缓冲无限增长**（真机实测定位）。`KernelStderrDecoder.ingest` 用 `remainder = remainder[idx...]` 切片分帧——`Data` 切片共享底层存储，已消费的行前缀一直留在存储里，下次 `append` 沿偏移 realloc 时把它们一并保住，于是缓冲把进程一生流经的内核 stderr 全部字节都留住。详细日志开启时内核把 playback/demux trace 写文件**且**回声到 stderr（高流量），把这缓冲喂得飞快：实测一条播放会话残留 60MB+，24 分钟播放进程内存涨 200–400MB。它可达（解码器持有），所以 `leaks` 扫不出；又在 xzone 的 4 MiB 段里涨，于是进程内存以 4 MiB 步长爬升——这正是「内存随播放增长、停播不回」的真因，**与内核无关**（内核单独无头实测跨集播放零泄漏、`in_use` 每轮稳定、IOSurface 归零）。修复：消费完把残行 `Data(remainder)` 拷到全新右尺寸存储，让旧存储随切片离开被释放；残行 ≤ `maxLineBytes`，拷贝开销可忽略。真机实测（自检模式真实渲染路径）：修复前 24 分钟 footprint 持续上涨，修复后升到 ~128MB 工作集即拉平、4 分钟零增长。AppTests 补 `testDecoderDoesNotRetainConsumedBytes` 回归用例（喂 20 万行断言活内存不涨）。

- **iPad 详情页氛围背景落黑底**：详情页在常规布局下靠 AppShell 垫在整块 `NavigationSplitView` 后面的整窗层出氛围图——macOS 的 split view 是透明的，垫在后面能透出来；iOS 的 `UISplitViewController` 自带不透明底，垫在后面的层到不了屏幕，而页面自身又不垫任何底，于是整页落在 split view 的底上（深色外观下与纯黑无异：实测正文、顶栏条带、左缘全为 `(0,0,0)`）。新增 `WindowAmbience.reachesScreen` 判据（macOS true / iOS false），详情页与 MoviePilot 资源页按它分叉：够不着屏幕时常规布局也自己垫 `BackdropAmbienceView`，并补 `Color.pageBackground` 兜底（详情页原有兜底的条件同步放宽）；`windowAmbience(_:)` 声明仍只在够得着屏幕的平台发——iOS 上没人消费它，省掉一次窗口大小的离屏渲染。修复后实测正文 `(85,77,67)`、顶栏 `(153,140,102)` 都有图；macOS 上 `reachesScreen` 为 true、`drawsOwnAmbience` 退化成原来的 `horizontalSizeClass == .compact`，行为不变。

- **MoviePilot 资源页侧栏玻璃底下没有氛围图**（iPad；macOS 正常）：该页的氛围图多挂了一句 `.drawingGroup()`，它把子树栅格化进离屏纹理、纹理边界取扩展前的 frame，于是把链尾的 `.ignoresSafeArea()` 截断——图出不了内容区。iPadOS 上详情列本身跨满整窗、侧栏宽度是它的左安全区，全靠那一步 `ignoresSafeArea` 才铺到侧栏玻璃底下（详情页没有这句，所以它的背景能铺满整窗、侧栏能透出来，实测左缘 `(79,20,14)`）。去掉它与 `.allowsHitTesting(false)`（`.background` 本就在内容之下，不吃点击），和详情页写法对齐；顺带补上「没海报时兜底 `Color.pageBackground`」。修复前侧栏内部 `(21,21,20)` 中性灰、左缘 `(0,0,0)` 纯黑；修复后 `(31,35,30)` / `(27,47,41)`，与内容列 `(64,68,49)` 同族、侧栏右缘横切平滑过渡，内容列像素不变。注意 `drawingGroup()` 当初是为「资源搜索页掉帧」加的，但那批同时删掉了 300 多行实时玻璃着色器；滚动资源列表若有掉帧再单独议。

### 待跟进（内核侧，上游 Erika）

- **开播 HEAD 探测约 3.8 秒**：0.1.8 记账的待跟进项①。内核 open 先发 HEAD 探测、失败再回退一字节 range；部分源站对 HEAD 恒回 403（如三重跳转的 strm 源），这段探测纯属浪费。修复在内核（上游 Erika），本仓只记账；核心里能省掉「HEAD 失败再 range」的往返即可。v0.2.0 的 release 说明与 CHANGELOG 均未见此修复，继续记账。

## [0.1.9] · 2026-09-22 · 内核换装 v0.1.9+dolby.streaming.fix.dev——预取窗口封顶，播放期间内存不再随窗口增长

### 改动

- **内核换装 `v0.1.9+dolby.streaming.fix.dev`：持久流预取的窗口不再无界**。这是 0.1.8 里记的待跟进项②——上一版内核下播放期间进程内存会随预取窗口增长（1.6 GB 片源实测峰值 RSS 1415 MB，而 App 传的预读 / 回退各 32 MiB，疑似开放式 GET 的前向窗口没起封顶作用；macOS 无碍，iOS / tvOS 上有 jetsam 风险）。内核侧根因（fork commit 85a9738）：worker 原先只从 reader 的 `paused` 标志得知「窗口满了」，而 reader 在包队列满时就不再刷新该标志——快源上这个背压信号因此失效，整个资源被预取完（927 MB 片源实测缓存到 659 MB）；现在每个 worker 按自己的生产偏移对绝对边界自我节流，不再依赖 reader 的刷新节奏。**C ABI 无变化**：`erika.h` 与上一版逐字节相同，`ErikaOpenOptions` 布局未动，App 侧零适配。钉点同步换到 `Scripts/build-macos.sh` / `package-macos.sh` / `package-ios.sh` / `release.yml` / `test.yml`，并新增 `Scripts/erika-v0.1.9+dolby.streaming.fix.dev.sha256`（哈希与 release 自带的 `SHA256SUMS` 逐字节核对一致）。杜比视界 RPU 映射与持久流预取本体未动，0.1.8 的慢源 A/B 口径（开播 13.2 秒、78.3 秒零卡顿）仍然成立。

### 文档

- **README 的构建与测试口径对齐现状**：`--disable-swift-testing` 只对纯 XCTest 包安全——BangumiKit 与 ErikaKit 用的是 swift-testing，照旧文案加这个开关会把它们的套件静默跳过（ErikaKit 那 30 个用例全在里面，它另有 4 个 XCTest 文件，两套并存）；末尾那行「0 tests in 0 suites」只是 swift-testing runner 空跑，不代表 XCTest 没跑。CI 的实际范围也写明：macOS scheme 的 `OcPlayerTests` 加 8 个 SPM 包，AppDesignKit 未纳入循环，ErikaKit 只跑不依赖 GPU 的套件。另修 DanmakuRenderKit 的描述（`DanmakuViewAdapter` 已在 bffe2b7 删除，现为异步绘制图层）与 `SKIP_ERIKA_FETCH` 的脚本清单（补 `package-ios.sh`）。

## [0.1.8] · 2026-09-21 · Emby 全链路加固、公网慢源播放修复与详情页媒体信息

### 重构

- **Emby 与 Jellyfin 在解码契约上分家：Emby 改走裸 HTTP + 宽松 DTO，Jellyfin 保留官方 SDK 强类型；200 行 `EmbySanitizer` 整层删除**。起因是 Emby 的问题反复落在同一个根因上——`jellyfin-sdk-swift` 的强类型枚举值域就是 Jellyfin 的值域，而 Emby 作为前身产品值域更宽：`VideoRange` 会报 `"DolbyVision"`、`MediaStreams[].Type` 会报 `"Attachment"`（MKV 内嵌字体）、`LockedFields` 会报 `"SortName"`、`Type` 会报 `"CollectionFolder"`。这些值让 SDK 解码**整包炸**，于是历史实现养了一层 JSON 重写：`JellyfinServer.send` 不走 SDK 的 `client.send`，而是 `client.data(for:)` 拿裸 Data、全量 JSON 重解析 + 递归深拷贝洗一遍、再用 SDK 的 decoder 二次解码。代价有两处：**Jellyfin 的每个响应都被迫改道**（为 Emby 的问题付费），而且这层洗白**并不全覆盖**（`reportPlayback*` / `downloadSubtitle` / 登录响应都绕过它），规则本身还带「同名不同义不能互相污染」这类误伤风险（`Type` 在顶层是 `BaseItemKind`、在 `MediaSources[]` 是 `MediaSourceType`、在 `MediaStreams[]` 才是 `MediaStreamType`，历史上误伤顶层 `Type` 打挂过章节列表）。分家后的形状：① 新增 `MediaServer` 协议作为两家的唯一契约（25 条方法 + `profile` + `authorizationHeader`），`JellyfinServer` 与新增的 `EmbyServer` 各自实现；② **Emby 侧不建任何 Swift 枚举**——`EmbyDTOs` 把 `Type` / `CollectionType` / `VideoRange` / `MediaStreams[].Type` / `LockedFields` 一律收成 `String?`，脏值在映射层落到 `.unknown` / `.other`，或者干脆不匹配任何分支被自然过滤（`"Attachment"` 不再需要被改写成 `"Data"`，它只是不等于 `"Video"`/`"Audio"`/`"Subtitle"`）。**九条洗白规则全部变得不必要**，`LooseItems.swift`（`EmbySanitizer` + `LooseDecoding`，253 行）整个删除，`JellyfinServer.send` 回到 `client.send(request).value` 一行。③ 映射逻辑不重复：`ServerItemFields` 作为「服务端条目 DTO → `MediaItem`」的中间表示，SDK 的 `BaseItemDto` 与 Emby 的宽松 DTO 各填一份，季/集号语义、父级图回退规则、缺 id 时的确定性派生只存在一处（这避开了「两边都降成无类型」路线的重复代价）。④ 按 `kind` 分叉只剩**一处**：`MediaServerFactory`（造会话）与 `MediaServerLogin`（探活 + 登录，探活也改走裸传输，于是 Emby 的整条登录链路不碰 SDK）。App 层 27 处 `JellyfinServer` 全部改成 `any MediaServer`，只有 3 个调用点因协议不能带默认参数而补全了实参。⑤ 上报协议窄化：`PlaybackReporting`（3 条方法）下沉到包内、`MediaServer` 继承它，App 的播放上报协调器只依赖这 3 条——测试替身不必实现另外 20 多条。测试同步重组为 `JellyfinServerTests`（纯 Jellyfin）/ `MediaServerLoginTests`（登录与探活，两家共用）/ `EmbyServerTests`（Emby 路由与宽松值域），旧的洗白用例改写成「响应仍能解出域模型且真值没丢」。净变化：删除 1795 行、新增约 1500 行。

- **清掉三处零引用死代码，净删 747 行**：全项目过度设计审查后落地，纯删除、无行为变更——`DanmakuRenderKit` 的 Gif 弹幕子系统（`DanmakuGifCell` / `DanmakuGifCellModel` / `GifAnimator`，480 行）包内外零引用；`DanmakuViewAdapter`（SwiftUI 适配器，143 行）同样零引用，App 直接实例化 `DanmakuView`；`DanmakuViewDelegate` 体系（协议 + 默认实现扩展 + delegate 属性 + 12 处调用点，约 120 行）全仓无人 conform、无人 set delegate。另删 `ChapterSkippingEvaluator` 协议（单实现，实际跳过源在 `ChapterSession` 上游合并）与 `PlayerState.clearError()`（唯一调用方是它自己的单测）。`PlaybackReporting` / `PlaybackReportingStateSource` 经核实均有测试替身（`TestPlaybackReporter` / `TestPlaybackStateSource`），属合格测试缝，保留。

### 新增

- **Emby 的片头 / 片尾识别：从章节 marker 翻译出与 Jellyfin 同形的 segment**。Emby 没有 `/MediaSegments` 接口（那是 Jellyfin 插件生态提供的），历史实现直接返回空、回退到章节名启发式——而 Emby 其实把片头 / 片尾标成了章节 marker（`MarkerType: IntroStart / IntroEnd / CreditsStart`），这是在白扔服务端已经算好的真值。现在 `EmbyServer.mediaSegments` 读 `fields=Chapters` 并翻译：`MarkerType` 兼容枚举名与**数字下标**两种形态（下标顺序即 Emby 枚举声明顺序，不能改）；很多集只有起始 marker 没有结束 marker，取**下一个章节的起点**顶替（那正是片头交接给正片的位置），后面没有章节的保持无界不猜长度；片尾没有结束 marker 则一直跑到条目 `RunTimeTicks`。

- **Emby 4.10 的「接下来看」逐剧扫描兜底**。Emby 4.10 对**不带 series 范围**的 Next Up 恒返回空数组，而同一查询限定到某部剧时返回正确的那一集——表现是首页「接下来看」整行空着。现在空结果会触发兜底：取最近看过的 25 部剧（按 `DatePlayed` 倒序、按剧去重，连看一整季不会刷出几十条重复），逐部问 scoped NextUp 取第一条，5 条并发。**顺序必须稳定**——并发回来的顺序不保证，所以按剧 id 收进字典、最后按「最近看过」的原顺序还原（这条是测试发现的真 bug：初版用 `withTaskGroup` 直接收集，行序会随调度抖动）。非空结果不触发扫描，省掉最多 25 次额外请求；扫描自身出任何问题都保留原答案，不让整行报错。

- **详情页新增「媒体信息」区块：按当前选中集展示该集文件的媒体参数**（剧集跟随横向选集，电影显示自身；目录/合集等无文件条目整块不出现）。展示四组：视频（分辨率 + 宽高比、编码 + profile、码率、帧率、动态范围、色彩、位深、隔行）、音频（逐轨：语言 · 编码 · 声道布局 + 声道数 · 采样率 · 码率 · 默认标记）、字幕（逐轨：语言 · 编码 · 外挂/强制/默认）、文件（容器、大小、时长、文件名）。**数据源刻意用 `GET /Items?ids=&fields=MediaSources` 而不是 `POST PlaybackInfo`**：后者是开播协商端点、会建播放会话，在详情页翻看选集不该在服务端留下会话记录（与既有 `externalSubtitles` 同一条只读路由）。多版本条目（同一集挂多个文件）按**开播同款规则**选源——直连优先 → 可直推 → 第一条——该规则从 `AppModel+Playback` 的内联判断抽成 `MediaSourceSelection`，详情页与开播路径共用一份，保证「展示的文件」就是「点播放会打开的文件」；版本数 > 1 时区块头带「共 N 个版本」。其余实现要点：`MediaFileInfo` 域模型只带文件名不带完整服务器路径（浏览面不摊目录结构）；平均帧率缺失或离谱（0 / 超大脏值）时回退实时帧率；`DOVI*` 全变体统一显示「杜比视界」，与 `PlaybackSessionContext.isDolbyVision` 判定同口径；认不出的色彩/动态范围原样透传而不猜；媒体信息按条目 id 缓存在本次停留内，来回点选集不重拉、不闪 loading，且竞态守卫用「正在拉的是哪个条目」而非 Bool，避免切集时旧请求把新集的 loading 清掉。顺带把 Bangumi 作品信息用的 `EqualRowHeightGrid`（同行等高网格）从 `BangumiSubjectDetailView` 的私有实现提为 AppDesignKit 公开组件，两处共用。JellyfinKit 新增 7 用例（完整字段映射、多源选源与直推回退、无媒体源返回 nil、老服务端字段缺失、帧率回退、Emby 脏枚举端到端），App 层新增 11 用例（码率/大小/帧率/分辨率与宽高比/声道/采样率/动态范围全变体/色彩/编码容器大写/语言/时长）。

- **详情页「剧集」行新增正序 / 倒序切换**：长剧从第 1 集排起，续播的最新一集要翻几十页。行右上角加同款胶囊按钮（集数 > 1 才显示），倒序即选集条反转，选中集的自动滚动定位不受影响；排序只影响横向条展示，不动数据与选中态，偏好跨启动保留。

### 修复

- **首页三条 rail 改为各自独立成败：一条挂掉不再把整页清空**。原来 `loadHome` 用 `try await (resume, nextUp, latest)` 一个元组收口，**任何一条失败就把三条全丢**、`home.error` 一设整页白屏。起因是一台公网中转 Emby 的实测：同一会话里 Jellyfin 局域网稳定 23–56ms，而那台 Emby 中位 370ms、长尾到 22s、**13 个请求撞满 30s 上限**（超时还成组出现——16:11:22 / 16:11:58 / 16:12:01 三批，每批 5 个请求在同一毫秒一起超时，典型的服务器间歇性假死）。这种服务器上「另外两条已经拿到内容」是常态，却被一条超时全带走。现在三条并发、各自把成功或失败收进 `RailResult`（不抛），成功的覆盖、失败的**保留上一次的内容不清空**，只有三条全挂才置 `home.error`（`HomeView` 本来也只在 latest 为空时展示整页错误态，部分失败时置 error 只会白白遮住已拿到的内容）；逐条 rail 的失败各留一条 warning 日志，便于按 rail 定位是哪条接口慢。取消不算失败，避免换会话时把过期请求的取消报成错误。新增 4 用例（一条挂掉另外两条留下、三条全挂才报错、失败保留旧内容、过期 generation 不写回）。

- **Emby 的「接下来看」逐剧扫描加三层预算，不再拖住首页**。扫描是「无范围 Next Up 返回空」时的补充手段（Emby 4.10 的行为），代价是 1 + N 条额外请求（N 上限 25）。它本身在快服务器上很便宜（实测 warm 180ms/条），但在一台 warm 都要 3–9 秒、偶尔 >30s 的服务器上，逐条问一遍能把这一行拖到几分钟——而这一行在首页加载的路径上。三层收口：① 无范围那次已经慢过 1.5 秒 → **整轮跳过**（这一行拿不到内容是可接受的降级，把整页拖住不是）；② 单条请求 5 秒封顶（新增 `EmbySession` 的逐请求 `timeout` 覆盖，默认 30s 对补充请求太宽）；③ 整轮 4 秒预算，超了返回已拿到的部分。最坏情况从「几分钟」收到约 9 秒。新增 1 用例（服务器已慢时不发任何扫描请求）。

- **诊断日志的脱敏正则不再吞掉服务器 API 路径**。脱敏规则原本是 `(?i)(?:file://)?/(?:Users|home)/[^\s"'<>]+` 的泛匹配，本意是抹掉本地文件系统路径 `/Users/jumusu/Documents/...`——但 `/Users/` 同时是 Jellyfin / Emby 的 **API 路由前缀**，于是 `path=/Users/user-e/Items/Resume` 整段变成 `<user-path>`，而这正是排障时最需要的那一列（上面那次定位就因此无法区分 Views / Resume / Latest 是哪个端点慢，只能靠时间线反推）。改为锚定本机用户名（`/Users/<NSUserName()>` 与 `/home/<name>`），既只抹真正要抹的东西，也不误伤 API 路径。取舍：同机上**别的**用户的家目录路径不再被抹——App 只写自己的容器和用户显式选中的文件，这个面很小。新增 1 用例（5 条典型 API 路径逐一断言不被脱敏），原有用例改为按当前用户名构造输入，不再依赖跑测试的机器是谁。

- **Emby 认证头 scheme 从 `MediaBrowser` 改成 `Emby`**。`ClientIdentity` 原本两个产品共用 `MediaBrowser …`，现在按产品分叉（`authorizationHeader(scheme:token:)`，Jellyfin 仍 `MediaBrowser`）。这是两家唯一的分叉点，其余字段与拼接顺序完全一致，因此上层用该头哈希做缓存键的语义不受影响。

- **Emby 的 `Fields` 参数加白名单过滤**。Emby 收到不认识的 `Fields` 名字会**拒掉整个请求**（不是忽略那个字段），而 `ItemCounts` 是 Jellyfin 独有的字段名——之前没发过所以没踩到，但下一个加字段的人会踩。现在发出前摘掉，摘空则整个参数不发。

- **Emby 上 token 过期不再无声无息**。Jellyfin 侧本来就有「已登录会话收到 401 → 发通知把 UI 拉回重登流程」的兜底，Emby 侧没有——token 失效后只会让后续请求持续裸报错误。现在 `EmbySession` 在同口径下发同一条通知（`MediaServerAuthentication.authenticationRequired`，常量从 `JellyfinAuthentication` 改名，它已不只服务一家；`JellyfinServerScheme` 同理改名为 `ServerScheme`）。**关键是只有已登录会话才发**：匿名会话（探活 / 登录阶段）的 401 是密码错误，发了会把用户从登录页踢回登录页——传输层因此显式区分 `profileID` 是否为 nil，两个方向各有一条用例。

- **两处 Emby 实现自身的缺陷（由新测试发现）**：① `UserItemDataDto` 的已看标志在 wire 上是 **`Played`** 而不是 `IsPlayed`（那是 `BaseItemDto` 顶层别处的拼法）——Emby 的宽松 DTO 一开始按 `IsPlayed` 写，`PlayedPercentage` / `PlaybackPositionTicks` 全部读成 0；同时记下一个坑：`keyDecodingStrategy` 会先把 JSON 键转成小写首字母再和属性名比对，所以任何显式 `CodingKeys` 都得按转换后的形态写，这里改为直接让属性名对上。② 「标记已看 / 取消已看」的状态回读用了裸 `JSONDecoder()`，绕过了会话带键名策略的解码器，导致一次成功的写入被读成「未看」；改为统一走 `EmbySession.decode`。另：上报接口刻意**不解析响应体**——这几个端点有的回 204 无 body，去解一个空 body 会把成功的上报报成失败。

- **iPhone 横屏点开 HUD 功能面板（弹幕/字幕/音轨/章节/更多）画面被撑大再弹回（issue #5，本基线复发）**：面板是动作簇的子视图，它的高度沿 `GlassEffectContainer` → HUD 根 `ZStack` → 播放器根 `ZStack` 一路把尺寸撑大——根 `ZStack` 尺寸 = max(子视图)，而视频 surface 是贪婪子视图，frame 跟着长，内核 `resize_surface` + CoreAnimation 把旧 drawable 拉伸 = 画面被撑大/缩放。模拟器 A/B 实测（自动开合面板 + surface 尺寸日志）：基线面板开合窗口内 surface 高度 `1206→1212→1337→1384→1394→1396→1206`px 弹簧振荡（402→465pt，与此前真机实测 `rootZStack 402→465.3` 吻合），也证明模拟器能复现**布局层面**的病（`6bf6c26`「模拟器看不出差异」只对玻璃渲染成立）；修复后窗口内 surface 零变化。修复只改承载、不动观感：① 动作簇外套**固定尺寸承载框**（`.frame(width:height:alignment: .bottomTrailing)`，高度 = 按钮行 + 间距 + 卡片上限）——显式 frame 向父层报告的是给定值，面板开合与面板内部怎么测量都无法再改变簇的尺寸，传播链从结构上切断，按钮行锚定与面板展开方向不变；② 新增 `PlayerHUDPanelMetrics` 面板几何预算单一事实源，卡片高度上限改按档位取静态值（横屏 iPhone `verticalSizeClass == .compact` 按最保守 375pt 屏高推导 213pt，其余 320pt），且**把子菜单头部（返回键 + 标题 46pt）算进卡片预算**——此前只限内容不扣头部，「播放速度」这类子菜单的簇高 428pt 必然顶出 402pt 屏；③ 新增 `PlayerLayoutClamp`（GeometryReader 贪婪容器，报告恒等于提案）套在浮动跳过按钮层上——它按面板实测高度动态让位、理想高会超屏，是同一类传播路径，夹紧后层内布局与让位行为不变。`GlassEffectContainer`/`glassEffectID`/`matchedGeometry` 液态形变/按钮重排/展开动画全部保持原样（`6e82991` 回退说明要求「恢复原始展开观感」）。⚠️ 面板高度上限必须是静态档位：「实测高度回写 @State → 喂回布局」在这个视图层级会形成每帧震荡的布局反馈循环（历史教训）。

- **全屏下鼠标移到 HUD 顶栏按钮位置 HUD 立即收起、按钮点不到（issue #4）**：macOS 原生全屏时系统把工具栏条带放进独立窗口 `NSToolbarFullScreenWindow`（高 52pt，悬在主窗之上），而全屏 HUD 顶栏只留 22pt 上边距，关闭 / 退出全屏 / 音量一排控件正压在条带里——指针滑进条带落在系统窗口上，主窗口的 `NSTrackingArea` 因此收到 `mouseExited`，触发了「移出窗口立即收起 HUD」，于是「鼠标放到按钮位置」被误判成「鼠标离开了播放器」；鼠标一动 HUD 又回来，再碰再收。两层修复：`PlayerMouseTrackingView` 的 `mouseExited` 用 `NSEvent.mouseLocation` 对窗口 frame 复核，指针仍在窗口矩形内就不算移出——对全屏顶缘唤出菜单栏等一切「被别的窗口盖住但没真正离开」的场景一并免疫，真正移出窗口仍立即收起；全屏 HUD 顶栏与长按倍速徽章的顶边距从 22pt 提到 56pt，整体让到条带之下，按钮的悬停与点击不再被条带窗口截走（窗口态 58pt 避标题栏拖动区的口径不变，iOS 布局不动）。

- **Emby 上回退直连播放时进度上报全部被拒 400、续播位置丢失（issue #3 日志 87 次全 400 的根因）**：三个独立开源项目（plezy / OhMyCine / go-emby2openlist）实测交叉证实，Emby 的 `/Sessions/Playing` 与 `/Sessions/Playing/Progress` 在 body 缺 `PlaySessionId` 时必拒 400（`Value cannot be null. (Parameter 'key')`，Emby 4.9.5），`Stopped` 容忍缺失；Jellyfin 三个端点都接受缺失。而回退直连路径（`PlaybackInfo` 失败 → 裸 URL 播放）构造的会话上下文没有 `playSessionID`——在该服务器上上报 100% 失败，续播位置全部丢失。修复：只对 Emby 档案、且没有协商会话时，按 `itemId` 合成一个**确定性**会话 id（`ocplayer-<itemId>`，照 plezy 的 `_resolvePlaySessionId` 模式）——确定性保证同一片源的 start / progress / stopped 三段上报落在服务端同一会话行，而不是三条孤儿会话；有协商会话则原样透传；Jellyfin 档案行为一字不动。同时 Start / Progress 的 body 补上 `SessionId` 字段（与 `PlaySessionId` 同值，对齐 Swiftfin 的上报形状）。JellyfinKit 新增 4 用例（Emby 回退合成、Jellyfin 回退保持省略、协商会话不被覆盖、合成确定性）。

- **Emby 上杜比视界片源拿不到服务端播放会话、整个媒体库列表可能加载失败（issue #3 的枚举解码问题）**：Emby 兼容层有几个字段的值域比 jellyfin-sdk-swift 的枚举更宽，强类型解码整包炸掉。诊断日志（issue #3 附件）里共 45 次解码失败，三种值：`VideoRange` 报 "DolbyVision"（SDK 只有 Unknown/SDR/HDR，40 次）——`/Items/{id}/PlaybackInfo` 因此失败、调用方「回退直连」（日志里 7 次），杜比片源丢失 `mediaSourceID` / `playSessionID` 与服务端协商，只能裸 `?Static=true` 拉流；`MediaStreams[].Type` 报 "Attachment"（MKV 内嵌字体，SDK `MediaStreamType` 无此 case，4 次）——同样炸 PlaybackInfo，实测波及《少女终末旅行》整季；`LockedFields` 报 "SortName"（SDK `MetadataField` 无此 case，1 次）——它在 `/Items` 列表响应里，一条脏值就把**整个媒体库列表**炸成「媒体库列表加载失败」。修复都在既有的 `EmbySanitizer` 洗白层，对标准 Jellyfin 是无害透传：`VideoRange` 的未知值归一成 "HDR"（**与上游 Jellyfin 语义一致**——其 `MediaStream.GetVideoColorRange()` 对杜比视界返回的就是 `(VideoRange.HDR, VideoRangeType.DOVI*)`，Emby 只是把粗粒度字段写细了）；`MediaStreams[].Type` 的未知值归一成 SDK 已有的 "Data"（附件流保留、只修类型值）；`LockedFields` 按数组元素过滤，剔除 SDK 不认识的项（该字段 App 侧无消费方，信息损失为零）。**关键约束是只洗 `VideoRange` 而不碰 `VideoRangeType`**：App 的杜比判定（`PlaybackSessionContext.isDolbyVision`）只看后者的 DOVI 前缀，而 SDK 的 `VideoRangeType` 有完整 DOVI 系列 case、原样透传即可——洗粗粒度救解码，靠细粒度保真值域。三处规则都按 key 精确限定子树（`Type` 在顶层是 BaseItemKind、在 MediaSources[] 是 MediaSourceType、在 MediaStreams[] 才是 MediaStreamType，同名不同义不能互相污染），并保证幂等（`JellyfinServer.send` 对非 Emby 档案是「先直接解码、失败再 sanitize 重试」，同一响应被洗两次是真实路径）。JellyfinKit 新增 5 用例（三处值域各一条、标准 Jellyfin 零影响一条、幂等一条——幂等用例比对语义而非字节，因 Foundation 的 JSONSerialization 不保证键序）。

- **iPhone 播放中横屏锁整个失效（回退误撤修复后复发）**：`AppModel` 持方向切换闭包、由 App 启动时装配的写法有个隐藏前提——闭包必须装在实际存储并注入 `RootView` 的那个 `AppModel` 实例上，而 SwiftUI 会多次创建 App 值，经 `@State` 属性访问到的 appModel 与注入的不是同一实例（`ObjectIdentifier` 实测 `0x8000` vs `0xb200`）：handler 装在了将被丢弃的临时实例上，`presentedPlayer` didSet 触发时恒为 nil，`setPlayerActive` 从未被调用——`requestGeometryUpdate` 不发，手动转设备也被 `mask=portrait` 拒绝。改为无装配时序依赖的广播模式：`AppModel` 在 didSet 里发通知，`IOSApplicationDelegate` 在自身 init（App 启动最早阶段）注册观察者并执行方向切换（delegate 实例由 `@UIApplicationDelegateAdaptor` 直接创建，不存在实例替换问题）；启动即播时 scene 尚未连接，方向请求先攒下、`UIScene.didActivateNotification` 到达后补发。`setPlayerActive` 顺带补上正式诊断日志（「方向切换 playerActive=…」）。模拟器实测启动即播自动进横屏。

- **Bangumi 详情页与关联选择器在 iPhone 上横向溢出**：`BangumiLinkPicker` 写死 `minWidth: 480`，而 iPhone sheet 宽度不足 480，两侧内容被裁出可视区——最小宽度改为只约束常规宽度（`horizontalSizeClass != .compact`）。条目详情页头部同批适配紧凑宽度：海报从 130×195 缩到 100×150 给信息列留宽度；标签徽章行从 `HStack` 改走 `FlowLayout` 自动换行（不换行必横向溢出）；操作行四个元素（收藏状态 / 我的评分 / 已看进度 / MoviePilot 下载）在紧凑宽度下拆成两行，常规宽度维持原一行布局。

- **紧凑端「海报氛围背景」开关来回切时标题上下跳**：`ambientCompactHeader` 的标题原本顶边贴屏（`padding(.top, 52)`），与 `compactHeroBanner` 的标题不在同一竖直位置，于是开关切换（有图 / 无图两条头部）时标题会跳一段，正文区起点也随头部高度变。现在标题占同一个 `compactBannerHeight` 英雄带、同样底对齐 + 8pt 内边距，只是没有图片层——开关来回切标题不动，正文区起点两边一致；顺带解决顶边贴屏那版会把艺术字 Logo 压进状态栏（离灵动岛只剩几个点）的问题，底对齐后 Logo 顶边恒定落在 198pt 以下。

### 改动

- **内核换装 `v0.1.9+dolby.streaming.dev`：公网慢源上「播不动 / 卡死」的问题解决**：旧内核（`stream.prefetch.fix.dev`）的按需读取仍走每 4 MiB 一次的有界请求，**每块都要重付一次连接 + TLS + TTFB**——在一台单请求延迟 1–5 秒、且约一半请求会在传输中途挂死十几秒的公网服务器上，单次 4 MiB 读取实测 1.0–8.9 秒；而 4 MiB 在 6.5 Mbps 片源上只够 ≈5 秒画面，首块一读完补给就断。实测后果：一台三重跳转（Cloudflare → Emby strm 307 → Alist 302 → 对象存储）的服务器**开播 60 秒看门狗超时、整场播不起来**（内核自身 66.5 秒才完成 open，只比看门狗晚 6 秒）；另一台单请求延迟正常但一半请求中途挂死的服务器上，90.3 秒播放里 **41.8 秒在缓冲**（46%）、最长一次冻 37.6 秒、音频累计欠载 43.6 秒静音。新内核把预取改成**持久流 worker**：每个 worker 持有一条开放式 GET（`bytes=锚点-`），源站每个 worker 只 seek 一次、背压交给 TCP，按需读取不再逐块重付往返。同一台服务器、同一套 App 实测对比：开播 13.2 秒成功（旧版超时失败）；按需读取只剩 3 次（均为开播探测）；预取 stripe **457 条，中位 31ms / p95 75ms / 最大 900ms，0 条超 1 秒**（旧版每 4 MiB 1–10 秒），网络错误 0 条；**78.3 秒播放零卡顿——`buffered_ms: 0`、`stall_count: 0`、0 次 buffer 事件、音频欠载 0 帧**；帧延迟中位 3ms / p95 8ms / 最大 16ms。trace 事件名同步换代：`http_range_error` / `http_range_retry` 被 `http_stream_body_error` / `http_stream_open_error` / `http_stream_worker_done` 取代（排障时按新名找）。同时带入 libplacebo 风格的杜比视界 RPU 映射 / HDR tone-gamut 管线（PR #136）。**C ABI 纯增量**：`erika.h` 只 +36 行（新增 `erika_export_gif`），`ErikaOpenOptions` 布局未动，App 侧零适配。钉点同步换到 `Scripts/build-macos.sh` / `package-macos.sh` / `package-ios.sh` / `release.yml` / `test.yml`，并新增 `Scripts/erika-v0.1.9+dolby.streaming.dev.sha256`（哈希与 release 自带的 `SHA256SUMS` 逐字节核对一致）。回归：App 202 + 各 SPM 包 383 + ErikaKit 30，全通过。**两点待跟进**：① 开播仍有约 3.8 秒花在 HEAD 探测上，而这台服务器对 HEAD 恒回 403（内核先 HEAD、失败再回退一字节 range），是可再省的一段；② 该内核下播放期间进程内存会随预取窗口增长（1.6 GB 片源实测涨到约 1.3 GB，峰值 RSS 1415 MB），而 App 传的是预读 / 回退各 32 MiB，疑似开放式 GET 的前向窗口未起封顶作用——macOS 无碍，**iOS / tvOS 上需留意 jetsam**。

- **内核换装 `v0.1.9+stream.prefetch.dev`：HTTP 预读改持久流，回退预算开放可调**：fork 的预加载重做（commit 5ff79d7）——两个 worker 持有**开放式 GET**（`bytes=锚点-`），源站每个 worker 只 seek 一次，背压就是 TCP 本身，替代了 `dolby.buffering.dev` 的 4 MiB 分块链（旧方案每个 4 MiB 都付一次请求延迟，慢源上预读追不上播放）。慢源 A/B（72 Mbps、单请求 2 秒延迟）：播放速率 0.15x → 0.73x，健康时段可到 1.0x。同时带入杜比视界 RPU 映射与 #137 request-cap/resume/rewind-cache。**回退预算从内核固定 16 MiB 开放为 `ErikaOpenOptions.http_back_buffer_bytes`**（C ABI 变化：`reserved[3]` 缩为 `reserved[2]`、新字段落在偏移 24，结构体尺寸不变仍为 48 字节，read-ahead 偏移 16 不动），高码率片源按「码率 × 期望回退时长」取值（16 MiB 在 71 Mbps 下只够回退 ~1.8 秒）。App 侧适配：`PlaybackSource` 新增 `backBufferBytes` 透传内核；设置页「播放」组新增「回退缓冲」档位（默认 16 / 32 / 64 / 128 MiB，0 = 内核默认），预读说明文案随持久流语义回落；`open.start` 诊断事件补 `back_buffer_bytes` 字段。ErikaOpenOptionsLayoutTests 锁死新布局（回退预算落在偏移 24）。

- **跳过片头/片尾加入设置开关，保底片尾保留时长从 20 秒改为默认 10 秒且可选**：设置页「播放」组新增「跳过片头」「跳过片尾」两个开关（默认开，关闭后播放中不再弹对应类别的「跳过」按钮，改动即播即生效）与「片尾保留」档位（不保留 / 5 / 10 / 15 / 20 / 30 秒，默认 10——原硬编码 20s 会拖到黑屏、错过自动连播窗口）。保留时长只作用于「末 90 秒保底跳过片尾」的落点（片长 − 保留秒数，不往回跳；不保留时钳在片长 − 0.5s 防内核 EOF 错误风暴）；服务端 MediaSegments / 章节启发式给出的片尾标记有精确区间终点，仍按终点跳。App 层新增 11 用例（门控、落点钳制、默认值与非法存量回落、控制器 seek 实测）。

- **关于页开源许可证新增「社区数据与服务」组**：App 设置 → 关于 → 开源许可证按 catalog 顺序分四组（主要依赖 → 社区数据与服务 → SwiftPM 依赖 → Erika 内置组件），新增组列出 Jellyfin / Emby（媒体服务器）、弹弹play（弹幕数据）、AniSkip / AniList（片头标注与 ID 映射）、Bangumi、MoviePilot；服务类条目没有随包文本，详情页只列主页与数据来源说明。打包脚本的许可证拷贝走自己的清单（SwiftPM checkouts + Erika licenses）、不读 Swift catalog，新增条目不影响打包校验。

## [0.1.7] · 2026-09-16 · 弱网播放修复（issue #1）、日志系统重整与设置页重组

### 修复

- **播到一半就停（issue #1）：内核换装 `v0.1.9+dolby.buffering.dev`，弱网只缓冲不再中断**：根因是内核把整个预读窗口作为**一次** HTTP 请求拉取，而单请求有 15 秒响应上限——32 MiB 档等于要求 ≈18 Mbps 持续带宽，低于门槛两次超时后 demux 直接把播放判死，只能手点「重试」。新内核（fork 合流版 commit 122be55：dolby.1 杜比管线 + 上游 PR #137）改为 **4 MiB 分块拉取**——单请求封顶、超时续传、预取失败降级同步读（不再判死）、保留 16 MiB 已播尾巴供回退命中（实测回退 10 秒零网络请求）、媒体源原始错误透传到 demux 错误。节流压测（3 Mbps 测试片 + 32 MiB 档）：700 KB/s 下 2 倍速播放（需求 750 KB/s 超过供给）全程只缓冲、干净播到片尾；250 KB/s（需求 3 倍于供给，旧内核 open 阶段即死）约 3 分钟拖完整片，0 播放错误。该 release 附全平台资产，macOS / iOS 首次同内核。C ABI 无变化，App 侧零适配。ErikaReadAheadBehaviorTests 断言适配分块语义（单请求 ≤4 MiB 封顶为回归守卫，另支持 `ERIKA_READAHEAD_TEST_MEDIA` 指定本地大文件验证）。
- **MoviePilot token 过期后不再甩原始 JSON、不再挂着无效的「重试」**：服务端对**过期 JWT** 回的是 403 + 自家信封 `{"success":false,"message":"token 校验不通过","data":null}`（只有缺 token / 解不出 payload 才是 401，jwt 过期签名落在 `verify_token` 的 `InvalidTokenError` → 403 分支），而客户端此前只把 401 当登录失效——403 落进 forbidden，信封里又取不到 FastAPI 的 `detail`，整包原始 JSON 直接当文案甩给 UI，且完全绕过「401 → 静默重登 → 失败才广播」的自愈链路：token 死了页面还显示已登录，「重试」永远失败。三层修复：错误体解析兼容 MP 信封（文案取 `message`，`detail` 兜底）；401/403 带 token 校验措辞一律归为 `requireLogin` 走静默重登——密码没改就无感自愈（订阅/搜索/下载全链路受益），密码改了或登录不上才清 token 广播通知把 UI 拉回未登录态；SSE 流式搜索的 401/403 同口径归一。订阅页与搜索页的错误态区分登录失效：标题「登录状态已失效」，按钮从「重试」换成「重新登录」直弹 MoviePilot 登录窗（预填地址与账号，只补密码）；「未登录」门控同样补了直弹登录窗入口。MoviePilotKit 新增 4 用例（403 信封自愈重放 / 普通 403 不误伤 / 信封文案提取 / 分类契约）。
- **缓冲不再强弹 HUD（issue #2「三十秒闪一次」的可见症状）**：HUD 的显隐判据此前只有一个 `canAutoHideControls`（`(playing||paused) && !isBuffering && 无遮挡`），且「变化即唤出」——于是每轮缓冲起止都强制唤出一次 HUD，跟着弹出来的是全屏压暗遮罩（`PlayerHUDReadabilityScrim`，32% 黑）＋转圈＋弹幕冻结，网络抖动下就是用户看到的「画面暗一下亮一下」。判据拆成 `PlayerHUDGates` 的两个值：`revealTrigger`（该不该唤出：暂停 / 错误 / 字幕导入 / 弹幕选择 / 辅助功能 / 播放起止）与 `canAutoHide`（能不能自动收起，缓冲期间为 false）；`PlayerHUDVisibilityCoordinator` 新增 `refreshAutoHide(canAutoHide:)`——缓冲只续期、不计显隐：HUD 在屏上就留住，已收起则不会被弹出来。**顺带修掉因此暴露的转圈对比度问题**：中央缓冲指示以前靠 HUD 的全屏暗幕托底，HUD 不再强弹后白转圈直接压在亮画面上几乎看不见，改成套 `PlayerHUDPanel` 暗底（与错误徽章 / 2 倍速徽章同族）并常挂载 + `.opacity` 淡入淡出（HUD 收起期间没有容器动画托底，`if` 挂载会是硬闪）。App 层新增 6 用例（含「缓冲只改收起资格」「不弹已收起的 HUD」两条回归）。
- **UI 缓冲态加迟滞，单帧饿数据不再闪动控件**：`PlayerState` 新增 `isBufferingSustained`——进缓冲要**连续持续 300ms** 才置位，恢复时补足 500ms 最短可见时长再收回（期间再进缓冲不重计、不收回）。转圈、HUD 状态行「缓冲中」、弹幕冻结/续播、HUD 收起计时全部改用它；诊断真值 `isBuffering`（`buffer.start/end` 事件、卡死看门狗）不受影响——埋点里不留迟滞。PlaybackKit 新增 4 用例（单帧饿数据完全不惊动 UI / 上沿与最短可见 / 收回前再进不闪 / reset 取消在飞计时）。
- **日志跨进程共写把记录撕碎（116 行残缺）**：`diagnostics.jsonl` 用 `FileHandle(forWritingTo:)` + `seekToEnd()` 打开、各进程各记文件偏移，"App 进程 + 测试宿主进程"共写同一文件时，后写者的 write 落在旧偏移上覆盖对方——实测三份文件共 116 行残缺（两条记录互相插入、或一条被拦腰截断，样本里能看到测试假内核名混进真实日志）。改为打开后置 `O_APPEND`（每次 write 由内核原子追加到真实末尾），补回归用例 `testAppendLandsAtRealEndWhenAnotherWriterIntervenes`，A/B 验证有牙齿：禁用 `O_APPEND` 时该用例必挂（对方写入被覆盖，3 行变 2 行）。历史残缺行仍在旧归档里，未清理。
- **维护会把「正在写的」日志文件删掉**：保留策略要跳过当前会话文件，但 `contentsOfDirectory` 返回的 URL 会把 `/var` 解析成 `/private/var`，直接比 URL 恒不相等 → 当前文件被判成淘汰候选。改成解析符号链接后比路径。由新写的「按数量淘汰最旧、当前文件永不删」用例抓出（实测确认 URL 字符串差异）。
- **测试宿主污染真实日志目录**：`xcodebuild test` 注入的 App 进程跑真实代码，一次全量 AppTests 会在 `~/Library/Logs/OcPlayer/` 留下 6 个会话文件（也是上面那 116 行残缺的另一半来源）。测试宿主现在改写临时目录（`XCTestConfigurationFilePath` 判定），跑完真实目录文件数不变。
- **弹幕时基混用致偏移非零时弹幕整集不出现（清屏死循环）**：弹幕 overlay 的 seek 跳变检测在 `tick` 里比较**原始媒体时间**，而 `resync`（装载 / seek / 改偏移后对齐）写入的却是**减过偏移的生效时间**——两个时基混用。只要偏移非零（dandanplay 匹配返回的 shift、或 HUD「时间偏移」调出 ±0.5s 以上），对齐后的下一拍算出 `delta ≈ 偏移量 + 1/60s`，越过 seek 阈值被误判成 seek → 再对齐 → **永久循环**：每拍 `view.stop()/play()` 清屏、发射逻辑永不执行，表现为「弹幕一条都不出来」。检测逻辑抽成纯值类型 `DanmakuSeekDetector`（只持原始媒体时间一个时基，类型本身杜绝再次混用），`resync` 的对齐基改回原始时间（积压兜底基维持生效时间同源不改）。修复后「调偏移修对齐」不再把弹幕全部弄没。App 层新增 7 用例：核心回归是「偏移 3s 下对齐后下一拍必须连续」，另覆盖前后向跳变仍被检出、`jumped` 后基准推进、`reset` 回无基准态。
- **Bangumi 集成开关读取吃掉默认值，全新安装的播放结束自动标记静默关闭**：后台门控用 `UserDefaults.bool(forKey:)` 读「启用 Bangumi」——这个开关默认 `true` 但**默认值从不落盘**（Toggle/`@AppStorage` 只写用户拨过的值），键不存在时 `bool(forKey:)` 返回 `false`，于是对所有从未拨过开关的人（含全新安装）实际是「停用」：播放结束不再自动标记看过，只在诊断日志里留一行「集成已停用」。新增 `UserDefaults.bool(forKey:default:)`（键不存在回 fallback，注释写明这个坑并落在 `SettingsKeys` 便于发现），门控改用它；`PlaybackPreferences.storedBool` 的私有同款实现收敛为委托该方法（行为逐字不变）。App 层新增 3 用例。
- **章节 / MediaSegments 链路静默失效（时序竞态）**：`loadChapters` 与引擎 `open` 并发执行（章节请求 28ms 即回，引擎 open 约半秒），但其时效守卫要求 `activeRequest` 已是当前请求——而 `activeRequest` 恰恰要到 open 完成才赋值，守卫因此**每次必败**，三个 await 检查点静默 return：MediaSegments 请求不发、章节与服务端跳过标记全部丢弃、日志零痕迹（媒体库装了 Intro Skipper 插件也不会生效）。守卫改为只认装配层的 `expectedRequestID`（跨请求换片时同步更新，是这路数据真正的失效判据），与引擎 open / 引擎重建解耦；作废路径补日志，不再无声。修复后 Jellyfin / Emby 的章节列表、章节名启发式与 MediaSegments 片头片尾识别首次真正可用。

### 改动

- **设置页「网络预读缓冲」文案随新内核回落**：内核按 4 MiB 分块拉取后，档位不再对应成比例的带宽门槛（约 2 Mbps 即可稳定拉取），文案改为「数值越大越能抗带宽抖动，内存占用相应增加；弱网下无需刻意调小，回退播放有 16 MiB 缓存兜底」——`PlaybackPreferences` 档位注释、设置页说明与 README 同口径。
- **内存 tick 记录补 `output_mode_switches`**：输出模式切换计数此前只参与「这次 tick 要不要记」的判定，日志里看不到值。现在进字段（每次记到的 tick 都带），配合内核 `ERIKA_HDR_DEBUG` 的 `ErikaHDR: … output mode=…` 行，现场就能分辨「显示器侧真的切了 HDR / 刷新率」还是 UI 自己闪（issue #2）。ErikaKit 新增 1 用例。

- **日志系统重整：默认档精简 + 一键诊断包 + 播放事件行 + 内核 stderr 接入**（issue #1/#2 排障暴露的缺口，完整清单见提交历史与 `Docs/LOGGING.md`）。四件事：
  1. **级别口径重定 + 默认 `info` 档**：全仓 119 处 debug 调用点逐条定级（升 info 约 63、升 warning 27、留 debug 18、合并删除 25，另删 6 个无调用方的网络日志死包装）——「一次操作的结果」「状态迁移」必须在默认档可见，守卫与中间态留 debug。管线加了进程级最低级别（默认 info）与实例覆盖，过滤放在**消息求值、脱敏、节流之前**（`@autoclosure` 消息因此不求值；被压掉的记录不污染节流计数）。
  2. **设置页「详细日志」开关 + 「导出诊断包…」**：开关打开 = debug 档并联动内核 `ERIKA_HTTP_TRACE`/`ERIKA_PLAYBACK_TRACE`/`ERIKA_HDR_DEBUG`（内核在引擎创建时读环境变量，**下一次播放生效**）；刻意不含高频开关（`ERIKA_FFMPEG_DEBUG` 实测 1500+ 行/秒、`ERIKA_SUBTITLE_DIAG` 约 100 行/秒，会把诊断文件冲掉，需要时手动加）。导出产出**单个 `.txt`**（头部：版本/构建/commit/平台/系统/当前档位/脱敏说明 → 全部 JSONL 记录 → 内核 trace 文件），走 `.fileExporter` 双端同一实现（不用 zip：iOS 起不了 `ditto`）。验证：设置开关 → 播放 → 导出，文件可直接附件。
  3. **播放生命周期事件行**：`open.start`（源类型/预读窗口/是否续播）、`open.done`（`ok` + `elapsed_ms`）、`first_frame`、`buffer.start`/`buffer.end`（带位置与这轮缓冲时长）、`stall`（宿主看门狗：在播、内核**没**报缓冲、位置连续 5s 不动 → warning，恢复后补 `recovered=true`）、`seek`（`kind` 区分 scrub/skip/chapter/auto/resume）、`error`（带内核原文）、`session.end`（`played_ms`/`buffer_count`/`buffered_ms`/`error_count`/`stall_count` 汇总）。每条记录带**会话标识**（进程级 8 位 id，一次启动一个）与**毫秒时间戳**，按 `session` 过滤即得一次启动的完整时间线（此前秒级精度判不出「续播 seek 与弹幕注入谁先」）。
  4. **内核 stderr 接进诊断管线**：GUI 启动时进程 fd 2 归 launchd，内核 stderr（`ErikaHDR`、结构化事件、Rust panic、ffmpeg 告警）此前完全丢失。现在 fd 2 → 管道，按前缀分类写进同一份 JSONL（`Erika/Output`、`Erika/Open`、`Erika/Stderr`；错误特征行提到 warning/error 让默认档可见），**原 stderr 保留一份 fd 做 tee**（终端/Console 行为不变、崩溃栈照样可见）；内核逐帧 trace 的 stderr 回声不入管线（内容在 trace 文件里），200 行/秒限速兜底。实测（自检模式 + DV/HDR 片源）：同一场景从 3469 条降到 100 条，留下的全是高价值事件（`video_seek_preroll elapsedMs/firstOutputPts`、`ffmpeg_seek`、`video_decoder_changed backend=videotoolbox`）。

- **日志文件改为按会话组织**：一次启动一个 `diagnostics-<时间戳>-<会话id>.jsonl`（写满续编 `-2`），保留最新 10 个 / 总量 ≤50MB / 不超过 30 天，当前会话文件永不删；替掉「单文件 2MB 滚动 + 3 份归档」（长会话的关键行会被切碎、上限一到还会直接删掉正在写的文件）。单条超长记录改成**截断保留**（头 1KB + 标注被截字节数），不再整条换成一条 warning（旧行为等于把内容丢了）。终止路径改有界 `flush(timeout:)`（macOS 2s / iOS 1s）——iOS 此前**完全不 flush 日志**，最后一批排队写入随进程丢。验证：连开三次产生三个会话文件；旧版 `diagnostics.jsonl.1/.2` 被同一策略自然淘汰。

- **降噪两处**：`displayEDRHeadroom` 同值不再下发（屏参通知风暴实测一次播放刷 3155 条同值记录）；内核内存 tick 采样改成「有实质变化才记」（关键分项变化 ≥8MiB 或 ≥10%，或 drawable 数／输出模式切换计数变了），open/stop 基线照常记——播放中每 5s 一条会让 1 小时片子多约 700 行噪声。

- **文档**：新增 [`Docs/LOGGING.md`](Docs/LOGGING.md)（级别规范、模块矩阵、事件字段口径、内核开关、不记什么）与 [`Docs/TROUBLESHOOTING.md`](Docs/TROUBLESHOOTING.md)（症状 → 看哪几行 → 常用命令），README 补链接与「遇到问题先导诊断包」的使用建议。

- **「跳过片头」接入 AniSkip 社区标注（第四路数据源）**：在弹幕报点推导之上再接 [AniSkip](https://api.aniskip.com/api-docs)（社区提交 + 投票背书的 OP/ED 区间库，浏览器扩展/IINA 跳 OP 脚本同源），优先级变为 **MediaSegments > AniSkip > 弹幕 > 章节启发式**。解析链：Jellyfin ProviderIds 直取 MAL ID（`MediaItem` 新增 `malID`/`anilistID` 透出，`Mal`/`MyAnimeList` 键都兼容）→ 缺失时 AniList GraphQL 换算/标题搜索（本地 24 部真实番实测映射成功率 20/24）→ `AniSkipClient` 按集查询 OP/mixed-op 区间。MAL ID 解析结果永久缓存（`aniskip-ids.json`），标题搜不中记负缓存 7 天过期重试，不重复打 AniList；AniSkip 无数据（404）/网络失败静默降级到弹幕推导，查询放在弹幕注入之后不拖慢弹幕上屏。AniSkip 区间转提示时起点直接用 OP 区间起点——有冷开场/前情回顾的集（如 OP 在 638–728s 的命运石之门）按钮只在 OP 区间内出现，比弹幕的最早报点估计更准；区间长度/绝对值双向合理性钳制防错季脏数据。已知局限记账：AniSkip 只认 MAL ID 且集数按条目内计，长篇连载/标题搜索不分季可能错季（有 episodeLength 过滤 + 钳制兜底）；覆盖与弹幕互补（我的朋友很少/来玩游戏吧/蜂蜜柠檬碳酸水等弹幕零信号的番 AniSkip 有数据，2026 新番两边都还没有）。`DanmakuIntroHint` 增加 `source` 字段（存量缓存解码兼容，缺省弹幕来源），`ChapterSession` 合并按 `SkipMarkSource.rank` 取舍、同级别刷新原位覆盖。DanmakuKit 新增 AniSkip 客户端 5 用例 + ID 解析器 3 用例 + 编排层优先级 2 用例，App 层 1 用例。

- **弹幕驱动的「跳过片头」**：播放器已有的片头/片尾跳过系统（Jellyfin MediaSegments 优先、章节名启发式兜底）接入第三路数据源——**弹幕报点推导**。弹幕文化里观众跳 OP 时会发「跳伞/空降 02:12」报出落点，落地后再发「空降成功/感谢指挥部」确认；两批独立行为在真实缓存弹幕上收敛到同一秒（54 集标定：报点主簇中位数与着陆确认逐秒吻合，同集冷开场长短差异也能如实区分）。新增 `DanmakuKit.DanmakuIntroDetector`：报点目标按 25s 间距聚类取最大簇（片头结束点 = 簇中位数），着陆/正片标记做交叉确认（无确认时要求 ≥3 个不同目标值），片尾玩笑报点（22:17）、中段跳过（11:50）被目标区间 + 聚类自然剔除，片头起点由最早报点帖估计（有冷开场的集不从 0 跳）。提示按 episodeID **永久缓存**（`intro-hints.json`，独立于弹幕正文的 1h TTL），之后弹幕过期或网关不可达跳过按钮照样可用。`DanmakuLoadOutcome.loaded/.empty` 带出提示，`DanmakuCoordinator` → `PlaybackController` 注入 `ChapterSession`（requestID 守卫防旧代迟到回调；章节与弹幕两条异步链路谁后到谁负责合并）；`SkipMark` 增加 `source` 字段标注来源，合并按可信度取舍：MediaSegments > 弹幕 > 章节启发式。顺带修掉 `performSkip` 跳过目标不钳制片长的隐患（越过 EOF 会触发内核错误风暴，与 `skip(by:)` 同一道防线）。UI 零新增：现有悬浮「跳过片头」按钮、窗口判定与会话内去重全部复用。DanmakuKit 新增检测器用例 9 个（真实形态回归含全角冒号/`2.21`/`3:9` 变体解析与「跳伞1.5倍」防误伤）+ 提示链路用例 4 个，App 层注入用例 6 个。

- **液态玻璃文字/图标动态颜色修复**：跳过片头/片尾按钮此前沿用 HUD 的固定白调色板（`PlayerHUDPalette`），但它挂在 HUD 之外、不享受全屏压暗暗幕的保护——HUD 自动隐藏后玻璃直接采样原视频，亮场面下玻璃翻浅变体、白字图标随之看不见；改用动态色 `.primary`（玻璃上的动态色随玻璃明暗变体自动翻转，WWDC25 session 284 确认），`PlayerHUDPalette` 补注释钉死「固定白仅限 HUD 暗幕之内」的使用契约。iOS 横滑 seek 预览条（白字白条裸压视频、拖动期间 HUD 不唤醒）包进实底 `PlayerHUDPanel` 背板，与音量/亮度 OSD 同族，任何画面下对比度都有保证。弹幕选择弹窗与 MoviePilot 资源页 4 处写死白的描边/行高亮改 `Color.primary` 同值——深色模式渲染零变化，浅色模式（浅玻璃下白描边隐形）修复。

- **设置页信息架构重排为六组**：原 10 个 Section 平铺一条龙（服务器/播放/播放内核/界面/弹幕/MoviePilot/关于/存储/诊断/无名登出）重排为 **通用 → 播放（含播放内核）→ 弹幕 → Jellyfin 服务器 → Bangumi → MoviePilot → 关于 → 维护**，并按「说明文字一行为辄」瘦身：「播放内核」删掉构成行、永久禁用的弹幕渲染开关与内核 notes（工程信息归开源许可证页），只留内核信息行与「下次播放生效」提示；「关于」删掉直连策略 / 弹幕来源两条静态文案；弹幕网关的 API Key / 状态行收进配置弹窗语境，区块缩为一行 + 条件提示；MoviePilot 介绍长文删除；存储 + 诊断合并为「维护」。**服务器管理抽成「管理服务器」子页**（新增 `ServersView`）：当前服务器首次进入列表（带「使用中」标），切换 / 删除 / 默认星标都在子页完成，不再需要先「连接其它服务器」才能看到自己的档案；页尾无名 Section 的 Jellyfin「退出登录」并入服务器区块并改名「退出 Jellyfin」，与 MoviePilot 的「退出 MoviePilot」消除同名歧义。

- **播放入口迁出设置页（首页工具栏「打开」菜单 + macOS 文件菜单）**：首页工具栏新增「打开」菜单（本地视频文件 / 直连链接，macOS / iOS 共用）；macOS 补上惯例的文件菜单——`CommandGroup(replacing: .newItem)` 提供「打开本地视频文件…」⌘O、「打开直连链接…」⇧⌘O。`fileImporter` 与 `URLEntrySheet` 上移到 `RootView`（`isPresented` 绑 `AppModel` 的请求标志，工具栏菜单 / 文件菜单只置标志，任何分区下都能触发，⌘O 在设置页按下也有效），`URLEntrySheet` 随迁 RootView；设置页「播放」区块只剩网络预读缓冲。

- **播放内核选择失效自愈**：装配点（`PlaybackEngineAssembly.registerAll`）注册完成后若发现存的选择指向本构建不存在的内核（MPV 实验分支残留的 `mpv-that-does-not-exist`），就地清除回退第一个可用内核并记 PlaybackLog——失效偏好在启动时自愈，不再常驻；设置页「播放内核」的橙色回退告警随之删除，本机 defaults 残留已清。

- **Bangumi / MoviePilot 集成启用开关（设置页）**：不用这两个集成的人可以整体停用——关闭后侧栏 / iPhone Tab 的对应入口消失（停用瞬间正停在该分区则选中回落首页）、详情页的 Bangumi 章节区块与 MoviePilot 资源区块 / Bangumi 条目页「MoviePilot下载」按钮隐藏、播放结束的 Bangumi 自动标记与 MoviePilot profile 校验等后台活动一并停止。默认开（现有行为不变）；关闭只藏 UI 停网络，登录凭据、服务器配置、条目关联与本地缓存全部保留，重新打开即恢复。开关 key 收进 `SettingsKeys`（`bangumi.enabled` / `moviepilot.enabled`），各触点经 `@AppStorage` 读同一登记 key。

- **macOS 菜单栏与系统界面中文化**：App 声明支持简体中文（新增 `App/Shared/zh-Hans.lproj/Localizable.strings` 声明载体 + Info.plist `CFBundleLocalizations` 登记），系统语言为中文时 AppKit/SwiftUI 提供的标准菜单（文件/编辑/显示/窗口/帮助）、菜单项（关闭/全部关闭等）与系统面板按钮（打开/取消）跟随中文渲染——此前整个菜单栏落在开发区域语言（英文）上；App 自有文案本就是中文硬编码不受影响。无障碍树里合并子标签的连接符也随语言变为顿号（如卡片「标题、年份」），VoiceOver 朗读更自然。

- **设置页内核行带版本号**：「内核」行显示为「Erika v0.1.9+dolby.1」。`PlaybackEngineDescriptor` 增加可选 `version` 字段（多内核时选择器同样带版本）；版本来源为新增的 `Packages/ErikaKit/Sources/ErikaKit/ErikaVersion.swift`——由 `Scripts/fetch-erika.sh` 在每次拉取内核时重写，与 vendored 二进制保持同源（该文件入库、diff 可见，拉了新内核不提交它会立刻暴露漂移）。

## [0.1.6] · 2026-09-11 · 前端组件化重构、HUD 液态玻璃与内核 v0.1.9

### 改动

- **修复 Bangumi 搜索「请求参数有误」**：带类型过滤的搜索（关联条目选择器、自动匹配的动画优先搜索、主页分类筛选）此前把 `filter.type` 编码成 `{"type":{"0":2}}` 对象——`BangumiJSONValue` 缺数组 case，只能用字典伪造，Bangumi 服务端校验拒绝直接 400（`body/filter/type must be array`），UI 报「请求参数有误，请检查后重试」。现在 `BangumiJSONValue` 补 `.array` case，搜索请求体改为 `{"type":[2]}` 正确数组形态；自动匹配原先靠吞 400 回退全类型搜索才没挂，修复后不再依赖兜底。新增 2 个请求体形状单测钉住编码。

- **弹幕网关瞬断自动重试**：匹配偶发「弹幕服务暂时不可用」的根因是网关（Cloudflare Workers）冷启动/子请求超时导致的瞬时 502/503/504——该文案是 `httpStatus` 兜底，此前 `GatewayClient` 一次请求即弃、四层降级只是换参数重试。现在接入阶段 3 的共享 `RetryPolicy`（3 次尝试、指数退避带抖动、429 尊重 Retry-After 封顶 60s，判据与 Bangumi 同口径）：网络超时/断网、502/503/504、429 自动重试；任一降级层命中网关级错误即短路剩余层，不再连打必败请求（也避免自触网关限流）；403 拆出独立语义「网关拒绝了请求（API Key 无效或已被限制）」，不再误报「暂时不可用」。匹配/搜索/弹幕正文接口全部幂等只读，重试天然安全；手动搜索与手动选集同享。新增重试用例 8 个（客户端 7 + 编排层短路 1），既有网关失败用例加请求计数断言。

- **macOS 26 全屏顶栏衔接层**：全屏时系统把工具栏搬进独立的 `NSToolbarFullScreenWindow`，顶部画一条与窗口底色同源的不透明硬底条带，氛围图被拦腰截断。新增 `FullscreenTitlebarFade` 衔接层（顶部 52pt 保持窗口底色、再 84pt 渐隐进氛围图），挂在整窗氛围层（`AppShell.windowAmbienceLayer`）与首页轮播两处；**衔接层必须放在氛围层的动画作用域之外**——放进去会被切页/换片时的 `Motion.ambient` 交叉淡入卷着一起动，背景里滑出一条渐变带（全屏专属症状）。工具栏本身不藏：实测 `.windowToolbarFullScreenVisibility(.onHover)` 会在全屏进详情页后留下旧页面残影并吃掉那片点击，AppKit 改 `toolbar.isVisible` 会把窗口踢出全屏——两条藏工具栏路线均已否决并留档。

- **播放器收边（阶段 4）**：弹幕偏好到引擎的映射合并为单一 `DanmakuPrefsSnapshot` 通路（原来 open 队列闭包的静态版与实例版各写一份字段对应表）；Erika 弹幕 JSON 的解析从 App 层（DanmakuOverlay）下移到 DanmakuKit（新增 `DanmakuJSONParser`，与写入侧 `DanmakuJSONConverter` 同包同 schema），App 不再认识内核数据格式；新增解析器测试 5 用例（含 converter↔parser 往返一致）。手势分类纯逻辑此前已抽 `PlayerPanGestureModel`（有测试），PlayerScreen 剩余的触摸编排评估后保留在视图（与控制器/HUD/亮度耦合，换壳无收益）。

- **网络层收敛（阶段 3）**：共享 HTTP 执行层落到 DiagnosticsKit——`HTTPClient`（请求构造/发送/计时日志/传输错误映射，状态码 ≥400 记失败级）+ `RetryPolicy`（指数退避 + 抖动 + 429 Retry-After，封顶 60s，支持 `sending` 闭包与调用方隔离域继承）。BangumiKit（`BangumiAPIClient.request`）、MoviePilotKit（`sendOnce`）、DanmakuKit（`GatewayClient.send`）三个客户端的手写「组请求/发送/URLError 分类/状态分支」全部替换为共享执行器；各域只保留自己的鉴权与状态语义。新增 `HTTPClientTests`（6 用例钉住退避/重试/取消语义）。新增 `SettingsKeys` 登记表，收编跨文件重复的 UserDefaults key（`ambientBackdrop`、`httpReadAheadMiB` 等曾各写三份）。纯重构，无行为变化。

- **状态层重构（阶段 2）**：
  - `AppModel` 域模型全部改为 init 显式注入（`store/bangumi/moviepilot/danmakuModel`，默认值不变），`bangumi.setup()` 从 init 挪进 `bootstrap()`——构造 AppModel 不再有副作用，测试拿到干净实例。
  - `BangumiCoordinator` 支持注入 `BangumiContext`（默认 `.shared`）。
  - **MoviePilot 凭证存储收敛为单实例**：`MoviePilotStore.shared`——此前协调器与 `MoviePilotAPIClient` 各持一个实例、只靠同一份 UserDefaults 碰巧同步。
  - 401 凭证失效接线收敛：RootView 里 Bangumi/MoviePilot 两段几乎相同的 `onReceive` 合并为共享的 `onAuthenticationRequired` 修饰符 + `AuthNotification` 解码。
  - **`DetailView` 数据面抽成 `DetailViewModel`**（1342→1083 行，@State 21→6）：详情/季/集/类似的加载、SWR 快照缓存、按季缓存、选中态与智能默认季/集全部进 VM，视图只剩布局与交互编排。详情页行内错误条并入共享 `ErrorNotice`，集列表空态/失败态并入 `EmptyState`。
  - 决策记录：`AppModel+Playback` 的播放编排**不**再抽独立对象——它要协调导航层/上报/弹幕/Bangumi/首页缓存五方，抽出来只是把同一份耦合换个壳；`@Observable` 本身已按属性粒度隔离重绘。播放侧的真正整改在阶段 4（PlaybackController 职责拆分）。

- **前端组件化重构：设计系统下沉为新包 `AppDesignKit`，卡片/胶囊/分页/空态向共享原语收敛**（`refactor/component-reuse`）。
  - 动效/尺寸 token、骨架屏、卡片原语、横向滚动、液态玻璃、远程图管道（`ImagePipeline`/`RemoteImage`）从 `App` 移入新包 `Packages/AppDesignKit`——只吃纯值、不依赖任何域模型，新 Feature 直接复用。
  - 新增模型无关原语：`MediaArtwork`（海报/剧照画幅 + overlay 槽）、`CardProgressTrack`（3pt 胶囊进度细轨）、`PillChip`（分类/印章徽章，三档语义色）、`RatingPill`（评分徽章统一橙）、`EmptyState`、`ErrorNotice`、`PagedListLoader` + `LoadMoreFooter`（分页状态机：代次守卫/追加去重/满页判断，含 `replace`/`remove`/`reportError`）。
  - 收起重复卡片：Bangumi 的 `CollectionTile`/`ProgressCard`/`CollectionRow`/`SearchResultRow`/`CalendarItemCard` 与 MoviePilot 的 `MoviePilotSubscribeCard`/`MoviePilotMediaGlassCard`/`MoviePilotTorrentGlassCard`，以及 `PosterCard`/`StillCard`，全部落到 `MediaArtwork`/`CardProgressTrack`/`PillChip`/`RatingPill`。
  - 收起手写分页：Bangumi 首页在播/搜索两套分页 + 收藏列表页改用 `PagedListLoader`。媒体库 `LibraryView` 因分页数据住在 `AppModel.libraryPages` 缓存而有意保留自管状态机，避免再造一个数据源。
  - 收起错误/空态/胶囊：`BangumiNotice` 并入 `ErrorNotice`；LibraryView/AppShell/Home/Bangumi 收藏列表空态并入 `EmptyState`；展示型标签用 `PillChip`，交互型菜单/状态胶囊按钮保持原生。
  - 净效果：App 层约 -1000 行；`BangumiHomeView` 999→836、`BangumiCollectionListView` 160→151。新增 `AppDesignKitTests`（12 用例）。纯 UI 重构，无视觉/行为变化，播放器 HUD 零改动。

- **HDR 片首次真出 EDR**：内核在 macOS 不探测屏幕，HDR 输出档位全靠宿主喂 headroom，而 App 从 v0.1.0 起一直传 `Auto + 0`——HDR 片始终被映射成 SDR（播放详情的「映射 SDR」标注只是让它显形）。现在引擎创建时按窗口所在屏的 `maximumPotentialEDR` 传 `edr_headroom`（SDR 屏 = 1.0 行为不变，XDR 屏 ≈8 真出 EDR），`PlaybackEngine` 增 `updateDisplayEDRHeadroom`（默认实现防静态派发坑），PlayerScreen 监听换屏/显示配置变化并首报、引擎重建时补推。非 macOS 不查不推。**限制**：运行时切换要等内核 Metal 后端实现 `set_output_headroom`（当前只在创建时生效，播放中换屏档位不跟手）。

- **关于页与产物可追溯到提交**：构建号与 Git commit 全程注入——`App.xcconfig` 增 `CURRENT_PROJECT_VERSION` 默认值，`Info.plist` 增 `GitCommit` 键（构建时注入，字面量兜底为 nil）；AppVersion 新增 `gitCommit`，关于页显示 `v版本 (Build N · 短哈希)`、启动诊断日志带 commit；构建脚本 Build 号 CI 取 run number、本地取提交总数，dirty 构建带 `-dirty` 后缀，本地产物文件名带 build + commit 后缀，打包脚本语义版本校验前置。补 `AppVersion.displayString` 单测。

- **弹幕匹配成功率提升（模糊候选打分 + 四级降级检索）**：`isMatched == false` 的模糊候选接入 `DanmakuCandidateScorer`（集数 / 季度 / 标题打分）救回有效弹幕；检索引入四级瀑布流降级——Hash 匹配 → TMDB ID 搜索 → 标题+集数精准搜索 → 提纯标题全集匹配（此前每级静默吞错，见「修复」里网关故障误报那条）。新增 `DanmakuFilenameParser`：全角半角转换、中文数字解析、剥离发布组与压制参数噪声；Jellyfin 与单播文件的元数据推断同步优化（解决 `01.mkv` 丢番剧名、单播支持向上回溯父目录）。

- **MoviePilot 与弹幕选择界面重构为液态玻璃 + 多层子菜单**：DesignSystem 增通用 `liquidGlassCard` / `liquidGlassCapsule` 材质修饰器；MoviePilot 媒体搜索结果改通透流式卡片（去掉放大悬浮动效），资源搜索页引入氛围背景、移除 300+ 行实时 glass 着色器与 textSelection、背景启用 Metal 离屏栅格化（此前严重掉帧）；弹幕选择面板重构为「作品 → 选集」两级下钻（平滑层级返回 + 透明液态玻璃背景），播放器为该弹窗配透明背景。

- **播放中 HUD 自动隐藏时一并藏鼠标光标**：用 `NSCursor.setHiddenUntilMouseMoves` 与 HUD 同步显隐，退出播放器强制 unhide 兜底；暂停 / 缓冲 / VoiceOver 时光标保持可见。
- **播放内核升级到 fork 的 `v0.1.9+dolby.1`（macOS）**：基于上游 v0.1.9 + libplacebo 风格 Dolby Vision RPU 映射（P5/P8.1 SSIM≈0.995）。相对 `v0.1.7+dolby.3` 带来上游 0.1.8/0.1.9 一系列播放修复——渲染阻塞恢复后的音画时钟重校准、倍速切换平滑过渡、iOS 前台/音频中断恢复、首条音轨解码失败自动回退后续音轨、弹幕跨规划窗口重现跳轨、`ErikaOpenOptions` 预读（本 App 已在用）。C ABI 与 `v0.1.7+dolby.2+` 一致（`ErikaPresenterConfig` 四字段），App 侧无需改代码。**iOS 暂维持 `v0.1.7+dolby.3`**：该 release 仅手工打包了 macOS arm64 资产，`package-ios.sh` / CI iOS job 继续钉最近一次全平台 tag；`fetch-erika.sh` 支持 macOS-only release（无 iOS zip 时复用本地已有切片并在 Info.plist 登记）。下载哈希 pin、脚本与 CI 钉点同步换版。

- **设置页新增「启动时默认服务器」**：多服务器用户可在设置 → 服务器里选定打开 App 时优先连接的档案，不必再被「上次使用的服务器」绑死。选「上次使用的服务器」保持旧行为；选定具体档案后启动静默恢复优先走它，token 失效仍回退到其它有有效会话的档案。默认服务器在已保存列表带星标；删除该档案会自动清掉默认设置，不留悬空 ID。默认与「当前会话」独立：临时切到另一台看片，下次打开仍回到你指定的默认服务器。

- **媒体库每个库页面右上角新增排序与观看状态筛选**：电影 / 剧集等库的网格页工具栏加「排序与筛选」按钮，点开系统下拉菜单（macOS 26 / iOS 26 原生液态玻璃，与首页 / MoviePilot 菜单同款）三组单选——排序字段（名称 / 最近添加 / 年份 / 评分 / 时长 / 随机，带图标与对勾）、顺序（升序 / 降序）、观看状态（全部 / 没看过 / 看过，服务端 isPlayed / isUnplayed 过滤）。排序完全在服务端生效（items API `sortBy`/`sortOrder`，主键外固定挂名称升序副键），分页大库全量有序；候选集按库类型收敛——剧集库去掉时长（Runtime 是单集时长）、混合内容 / 家庭视频等只留名称 / 最近添加 / 随机，随机无方向不显示顺序组。换字段时方向自动重置到自然默认（评分默认高→低等），排序与观看状态按库独立记忆，变更即作废该库分页缓存从第一页重取。顺带把 MoviePilot 筛选条与 Bangumi 详情页两份逐字节相同的私有 FlowLayout 抽到 DesignSystem 共用（新增 `FlowLayout` / `OptionChip` 共享组件）。

- **资源搜索筛选排序对齐 MoviePilot 网页端**：原先「站点选择 + 一颗筛选按钮弹整表单 + 排序菜单」换成官方同款筛选条——排序（字段 + 升降序）与七组筛选（站点 / 季 / 促销 / 编码 / 质量 / 分辨率 / 制作组）平铺一行，每组点开是候选值 chips 下拉（头部「全选 / 清除」，可多选，点击即时生效；iPhone 紧凑宽度自动升级为半屏 sheet）；激活的分组按钮 tint 玻璃高亮并记数，下方以「站点:观众 ×」样式的已选 chip 汇总、可逐个移除或一键清除。全部走原生 Liquid Glass（`glassEffect` 胶囊），候选值随搜索结果聚合并记忆化（随批次落账，不随界面求值重算）。搜索固定全站（与官方默认一致），「搜索范围」站点选择弹窗整个移除，站点收窄一律走结果筛选；原整表单筛选弹窗移除。
- **资源搜索结果懒加载（MoviePilot）**：聚合结果多时页面内存暴增、操作卡顿——筛选+排序原先在每次界面求值时全量重算（关键词逐键输入、流式批次、下载按钮状态变化都会触发），整表结果也无差别塞进列表。现在筛选+排序结果记忆化，只在搜索批次落账、筛选弹窗勾选/清除、排序切换这几个赋值点重算；列表按 60 条一窗懒加载物化，滚到底部自动续载并显示「已展示 X / Y 条」，视图 diff 与卡片状态只随窗口走。全量结果仍留在内存（筛选候选聚合与下载时原样回传服务端需要），但界面求值与渲染开销不再随结果数线性放大。
- **播放内核升级到 fork 的 `v0.1.7+dolby.3`，修复播放中切换全屏的音画失步**：全屏 Space 切换动画期间 WindowServer 扣住 `CAMetalLayer` 全部 drawable，内核渲染线程的 `nextDrawable()` 会被阻塞（实测 733ms，GPU 本身仅 0.4ms），而音频补泵同在该渲染 tick 上——音频环（原 ~290ms 存货）被抽干，underflow 约 450ms 静音；更糟的是恢复后积压回填让环指针落后时钟 ~0.7s，距离型 stale 判定（250ms）把之后所有时钟重锚永久拒绝，**失步一直持续到手动 seek/暂停**（trace 实测 35,769 次重锚全部被拒）。三处内核修复：Metal surface 启用 `allowsNextDrawableTimeout`（拿不到 drawable 跳帧而非阻塞，含跳过计数与节流诊断）；播放时钟对音频环样本改按设备活性判定（计数推进即重锚，大偏差走既有 snap），积压照常播出、画面短暂定格后重新对齐；CoreAudio 输出环 1.2s 真门控 + worker 预填同步加深，停顿期间音频从积压播出。真机压测：6 次全屏切换 underflow 从 1,140ms 降至 25ms（不可闻）、时钟校正零断流、窗口态渲染 tick 均值 1.35ms。C ABI 无变化，下载哈希 pin、脚本与 CI 钉点同步换版。
- **`build-macos.sh` 支持 `SKIP_ERIKA_FETCH=1`**（与 `package-macos.sh` / `package-ios.sh` 同一开关，含 shim 头防呆）：此前 build 脚本无条件跑 fetch，会把手动铺进 Vendor 的自编译内核按钉点版本静默覆盖回 Release 产物。

- **播放内核升级到 fork 的 `v0.1.7+dolby.2`，新增杜比视界支持**：内核在 HTTP 预读之上引入杜比视界 RPU 处理——profile 5（单层非兼容）自动回落 FFmpeg 软解并按 RPU 逐帧重映射色彩（libplacebo 同路线），profile 8（HDR10 兼容双层）保持硬解走 HDR10 底层；C ABI 无变化，预读链路不受影响。下载哈希 pin、脚本与 CI 钉点同步换版。
- **播放信息面板「动态范围」标注杜比视界**：从 Jellyfin/Emby 的流信息（`MediaStreams.videoRangeType`）识别杜比源，杜比片源不再裸报 HDR (PQ)/SDR——输出端实际映射成 SDR 时显示「杜比视界（映射 SDR）」（SDR 屏上放杜比片的最常见场景），真出 HDR 时显示「杜比视界（HDR）」；输出状态来自内核 `get_output_status` 的新封装（`PlaybackOutputEncoding` 中立枚举进 `PlaybackEngine` 协议）。本地文件/手动 URL 拿不到服务端流信息，维持原有文案。

- **详情页简介在 Mac / iPad 上同样超行折叠**（原先只有 iPhone 折叠、桌面端全文铺开）：超过 3 行截断，底部附「展开全文」/「收起」按钮，与紧凑宽度行为一致（仅字号随宽度）。按钮按实测截断与否显隐——全文不足 3 行不出按钮，窗口拉宽到不再截断时自动消失，收起状态重新截断时恢复。
- **详情页新增 Emby 风格全页氛围背景**（设置 → 界面 →「海报氛围背景」，默认开）：开启时去掉英雄区横幅，海报、标题、元数据与播放钮直接浮在整页 backdrop 氛围背景上——背景低档模糊（能认出是哪部剧）、固定不随滚动，全屏遮罩日间白雾 / 夜间黑纱，无额外压暗带。头部文字与按钮颜色跟随外观自适应（日间深字、夜间白字），白色按钮带柔和投影分界；两种布局共用同一套自适应文字——清晰横幅布局的压字渐变日间换白雾、元数据行同样随外观变色。条目没有 backdrop 图时始终走清晰横幅布局。氛围图为 800 宽小图 + 512px 解码下采样，不为糊图拉原画。
- **首页背景库内随机 backdrop 渐变轮播**（同一开关控制）：服务器端 `SortBy=Random` 从全库随机取 8 张带 backdrop 的电影 / 剧集（查询失败或为空回退首页已加载条目），同样模糊+雾化垫底，每 12 秒淡入淡出换一张（减弱动态效果时保持静态首图）。首图进缓存后才亮相，其余后台预热，切换零占位闪烁；切换服务器会话或开关时自动重取。
- **播放器 HUD 改用原生 Liquid Glass 液态玻璃（Infuse 风格）**：右下角五个功能入口（弹幕/字幕/音轨/章节/更多）从标题行旁的独立圆钮改为融合成一颗玻璃胶囊，悬浮在进度条上方右侧；点开的按钮整体液态形变为玻璃面板，其余按钮回流成短胶囊，点击面板外任意处收起。面板内容重写为「行 + 子菜单」结构——根层是「图标 + 标题 + 当前值 + 箭头」的行列表（如「不透明度 100% ›」「字幕轨道 简体中文 ›」），点入后子菜单滑入显示选项（选中行带 checkmark）、返回滑出；音轨与章节保持单层选单；弹幕根行含启用开关与匹配状态徽章。面板内不再放关闭/快速切换按钮：切换 Tab 直接点胶囊上其余按钮，与 Infuse 一致。
- **最低系统要求提升至 macOS 26 / iOS 26**：HUD 玻璃改用系统原生 `glassEffect`（原先 26+ 才走玻璃、旧系统回落 ultraThinMaterial 的双轨制移除，旧系统不再支持）。
- **播放器「播放信息」与「播放统计」合并为一个面板**：更多面板里的两个开关收敛为单个「播放信息」开关，面板从两块各自为政的散字改为分区排版——播放（状态/进度/倍速/音量/章节）、视频（分辨率与宽高比、动态范围 HDR/SDR、色彩空间、出画状态）、音频（当前音轨与采样率）、字幕（当前字幕轨，外挂标注）、内核统计（解码/渲染/硬解/软解/零拷贝/音频帧/失败计数，每秒刷新）。
- **首页右上角新增刷新按钮**：长期停在首页也不怕数据过期，点一下重新向服务器请求首页与媒体库数据（等同下拉刷新）；按钮为 macOS 26 / iOS 26 原生液态玻璃工具栏样式，加载中原地转圈，未连接服务器时置灰。
- **设置页新增「弹幕诊断日志」调试开关**（默认关闭）：开启后弹幕 overlay 记录时间轴对齐点、爆发发射与续播定位日志（写入 `~/Library/Logs/OcPlayer/diagnostics.jsonl`），用于排查「续播起播爆出一大片非当前时间点的弹幕」等时间轴错位问题；平时保持关闭以减少日志噪声。

### 修复

- **弹幕装载在主线程解几 MB JSON**：`DanmakuService` 早在 actor 上把弹弹play 弹幕转成了 Erika JSON 串，界面侧拿到后又在**主线程**解码 + 排序一遍——三万条 = 主线程 100–400ms，正好压在「源就绪、视频起播」这一拍。现在转换与排序都留在 actor 上（`DanmakuJSONConverter.entries(from:)`，与 JSON 路线共用一套滤镜判据），overlay 装载只是赋值；JSON 串保留给当前停用的内核弹幕轨路线。新增 2 个包用例钉住「两条产出路径同结果」。

- **2s 阈值内的前向 seek 把窗口内弹幕一帧喷完**：出场循环没有单拍上限，往回跳 1.9s（不到 `seekJumpSeconds` 的 seek 重同步阈值）时窗口里几十到几百条会在同一拍出场，每条都要测字宽、取 cell、建视图。现在发射决策抽成 `DanmakuSpawnPlanner`：每拍最多 24 条、超出顺延（60Hz 下约 1440 条/s，远超正常密度），积压跳变的清屏兜底原样保留。新增 6 个用例（正常节奏 / 上限顺延 / 1.9s 前向 seek 摊成 7 拍 / 跳变清屏 / 指针越界钳制）。

- **截图瞬间整个播放器卡住**：`captureScreenshot` 在主线程一气做完取帧（33MB 缓冲分配 + 持引擎锁整份拷贝）、PNG 编码（再拷一份 + CGImageDestination）与写盘，4K 片可达数百 ms——期间 HUD / 手势 / 弹幕全冻。现在只有取帧留在主线程（必须与渲染线程串行），编码与写盘挪到后台任务，回来后只更新界面提示；顺带加一条「截图编码写盘 宽x高 耗时=Nms」诊断日志。

- **MoviePilot「保存并登录」失败会毁掉原本可用的会话**：改密码打错一次（或把地址改到另一台服务器再登录失败），错误凭据已经落盘、旧 token 已被删——点「取消」也救不回来，之前能用的 MoviePilot 会话彻底没了（gate 变「未登录」，后续请求 401 → 静默重登拿着错密码 → 通知登出）。现在登录前先打「服务器地址 / 用户名 / 密码 / token」四键快照，失败把快照原样还原（含旧 token），错误凭据只作尝试不落盘；成功路径不变（换凭据 ⇒ 旧 token 照旧作废）。同批修掉密码被静默 trim：含首尾空格的密码此前被改写、登录永远失败且无提示，现在密码原样存取与发送（地址与用户名仍 trim，判空用 trim 结果）。快照与回滚落在 `MoviePilotStore.credentialSnapshot()` / `restore(_:)`，新增 3 个包用例钉住「失败不动旧值」。

- **MoviePilot 订阅里清空的字段清不掉**：编辑订阅以服务端原始记录起底，「自定义存储路径」「TMDB / Bangumi / 豆瓣 ID」「海报」「简介」这几个字段只做「非空才写」、清空不回删——用户删掉存储路径或 ID 保存后旧值原样回传服务端继续生效（而关键词 / 包含 / 排除 / 画质同表却是会删的，一张表单两套语义）。现在可清空字段统一走 `MoviePilotSubscribeFieldRules`：空 = 从字典删键；成对键（`tmdbid`/`tmdb_id`、`doubanid`/`douban_id`、`bangumiid`/`bangumi_id`、`poster`/`poster_path`、`overview`/`description`）同进同出——只删一个等于没删，读侧是 `raw["tmdbid"] ?? raw["tmdb_id"]`。简介仍写原值（保留换行）、判空用 trim 结果。新增 5 个规则用例。

- **Bangumi 条目瞬时网络抖动下被清出「在看」**：单条目接口 `p1/subjects/{id}` 本就不返回收藏状态，回读路径（详情页加载、播放结束后的进度对齐）靠附加请求补，补失败即 `nil`——而落库把 `interest == nil` 当成「服务端确认没收藏」，把本地 `interest`/`ctype`/`collectedAt` 一并清零：条目从「在看」消失、已看进度与评分归零，直到下次全量同步才回来。现在「按 nil 清空」改成显式参数 `authoritativeInterest`：只有收藏全量同步（每页都带收藏状态）这条权威路径传 `true`，单条回读与进度对齐默认保留本地收藏态、只更新元数据（本地改收藏走专用方法，从不置 nil，不受影响）。新增 2 个库用例（非权威保留 / 权威仍清空）。

- **GitHub CI 修复：fetch-erika.sh 全角逗号粘连变量名 + v0.1.9+dolby.1 资产哈希 pin 过期**：CI 自 09-10 起秒挂，根因两条——(1) 脚本 4 处 `$var，` 全角逗号直接粘在变量名后（203 行 `$expected，`、三处 `$f，`），在 CI runner 的 bash/locale 下被当成变量名一部分，`set -u` 直接报 `expected: unbound variable`（3b39961 修过同款 `$PINNED，`，本次漏网；已全部改 `${var}` 花括号隔离）；(2) v0.1.9+dolby.1 的 macOS 资产在本地下载（09-10 13:21）之后被重新上传，pin 哈希停留在旧资产（98cde716），缓存过期后 CI 首次实拉即哈希不匹配——粘连 bug 又把真实的「哈希不匹配」报错吞成 unbound。pin 已更新为线上资产哈希（7b622c21），本地全流程（实拉→校验→合成 xcframework→缓存复用）验证通过。

- **播放信息面板打开时快捷键操作后 HUD 不再自动收起**：`canAutoHideControls` 此前把 `showInfoPanel` 一并收进「不许自动隐藏」——面板开着时用快捷键调进度/音量唤出的 HUD 被钉死，直到关面板或鼠标移出窗口才消失。信息面板只读、`allowsHitTesting(false)`、且独立于 HUD 挂载（HUD 卸载后它照常每秒刷新），不依赖 HUD 常驻，从规则中移出后两者各自独立显隐。

- **跳过钮被面板压住、且展开动画被打断**：展开面板高度上提到 PlayerScreen 后，跳过钮保持单实例、锚点改为「簇底距 + 按钮高 + 间距 + 面板高度」平滑上移；上一版挂在卡片 overlay 里的副本会因挂载时的 prompt 状态写入打断 `glassEffectID` 液态展开动画（面板直接弹出），副本已移除；面板切子菜单变高变矮时跳过钮跟随移动，`reduceMotion` 生效。

- **HUD 展开面板被撑满 320pt**：`ScrollView` 是贪婪布局、`frame(maxHeight:)` 只封顶不收缩，只有一个选项的子菜单也撑满 320。改为隐藏镜像（`fixedSize` 实测自然高度）驱动分支——内容 ≤320 原生高度贴合，超出才滚动（`ViewThatFits` 方案在 `GlassEffectContainer` 内实测不生效，弃用）。

- **氛围背景不铺侧栏、顶栏露出窗口底色**：页面的氛围图此前挂在详情列 ScrollView 的背景上，而 macOS 26 的 `NavigationSplitView` 里只有**栈根**的背景能铺满全窗（首页轮播正是这样垫到侧栏玻璃底下的），pushed 页被裁在详情列内、导航栈宿主自带不透明底——在列内垫什么都连不到侧栏，侧栏整列（尤其下半截）空玻璃，详情页顶部工具栏区域还会露出一条窗口底色。现在有氛围图的页面出现时经 `windowAmbience(_:)` 向 `AppModel.windowAmbience` 声明、离屏时撤回（MoviePilot 资源搜索页声明海报、详情页声明 backdrop，与「海报氛围背景」开关一致），AppShell 把声明图垫在整块 `NavigationSplitView` 后面——透明的 pushed 页、侧栏玻璃和顶部工具栏透出的都是同一张连续的图，观感与首页完全一致；返回或切到无氛围页自动回落系统玻璃，iPhone 紧凑布局没有整窗层、页面自垫不受影响。实现坑：氛围图的 fill 溢出若作为 ZStack 兄弟参与布局会把 split view 撑出窗口，必须走 layout 隔离的 `.background` 挂载；层必须在调用点显式 `ignoresSafeArea()`——详情页这类自带顶部 ignoresSafeArea 滚动视图的页面会改变层继承到的安全区，让图片被 `.clipped()` 裁到工具栏以下。
- **iPad 氛围布局海报被顶部导航栏按钮遮挡、上沿发糊**：详情页氛围头部内容整体越过顶部安全区，顶部只留 64pt，而 iPadOS 26 导航栏的玻璃按钮（侧栏开关 + 返回）悬深到 ~76pt、滚动边缘渐进模糊尾部到 ~82pt——海报顶部正好压进两者：上沿一截被系统渐进模糊洗掉，收起侧栏后海报左缘（52pt）正对按钮列，左上角直接被玻璃圆钮盖住（侧栏展开时返回键也压着海报一角）。现在 iOS 上头部顶距抬到 104pt，海报整张落在模糊带与按钮之下；Mac 工具栏浅，维持原深度不变。
- **看完一集退出到详情页，Bangumi 章节格子不变「已看」**：播放结束的自动标记走「远端 PATCH → 写本地库 → 广播失效通知」，而详情页内嵌的 Bangumi 章节区块一直没监听这条通知——它唯一能感知的刷新（退出播放器触发的 `detailRefreshGeneration` 重载）通常赶在标记落库之前，自动标记完成后也没有任何信号再推它重读，格子就停在旧的未看状态（手动点标记因为更新完自己重读，所以有转圈和即时刷新）。现在章节区块与进度页 / Bangumi 条目详情页同款：监听失效通知、按关联条目过滤后重读本地库，自动标记落库后格子立刻刷新。
- **弹幕网关挂掉时误报「未匹配到剧集」**：自动匹配的四级降级检索（Hash → TMDB → 标题+集数 → 提纯标题）每级都把请求错误静默吞掉，网关宕机、断网、额度用完最终都落成「未匹配到剧集」，用户误以为这部剧没弹幕且日志无告警。现在任何一级检索抛错都会落到「失败可重试」态并复用稳定文案（额度用完 / 网络请求失败 / 服务暂时不可用），全部干净无结果才报未匹配；错误路径升 warning 日志。同批顺带：open 在飞期间字幕缩放 / 弹幕设置 / 选轨等入口不再撞引擎长持锁（loading 中动菜单不再卡主线程）；loading 中按下的暂停在起播后生效；弹幕解析的 ~20 个正则改静态编译，长篇全集搜索不再卡主线程；文件名解析支持行首发布组位与年份括号剥除（VCB-Studio 等枚举外组名不再污染标题、[2023] 不再混进标题）。
- **网络差时播放加载页让整个 App 卡死（繁忙光标、取消按钮点不动）**：内核打开媒体源是在调用线程上同步完成网络连接与格式探测的，而这条调用整个跑在主线程上——弱网下连接 + 探测可达数十秒（DNS 解析甚至没有超时），主线程不处理事件就是 macOS 的「繁忙」转圈光标，loading 层的取消按钮根本点不了；就算点得了，取消路径的 stop / detach 也要和正在进行的 open 抢同一把引擎锁，照样卡死。现在 open 的阻塞段移到专用串行后台队列（完成后回主线程落状态，代次守卫防串台）；引擎适配层加「让位契约」——open 在飞期间 stop / detach / resize 只登记意图立即返回、由 open 收尾补做，play / seek / 改速率音量直接丢弃，统计快照与媒体时间一样走独立小锁，loading 轮询首帧标志不再撞锁。取消、换片（自动连播）、失败重试全程主线程零阻塞，取消按钮即点即生效；另加 60 秒看门狗，open 卡死时强制转「连接超时」给重试入口，不再无限黑屏；同请求重入不会二开。
- **关闭播放器时闪现「画中画样式」的占位画面**：点 × / ESC 后引擎被同步停掉，无引擎占位图（画中画样式图标 + 剧集标题）与常驻 HUD 在停播到退出播放器的约 0.25s 窗口期裸露闪现。现在关闭时窗口先带着正在播的画面缩回原位（与打开时的展开动画对称）、HUD 同步淡出，缩完再停引擎并退出播放器，全程看不到占位图；停播前校验屏上仍是被关的那片，不会误停窗口期内新开的内容。
- **继续播放起播时爆出一大片非当前时间点的弹幕**：续播 seek 与弹幕注入竞速，注入时媒体时间还在片头 0.5s，弹幕出场指针被对齐到片头；seek 跳到续播位后跳变检测又被 resync 后的首拍空窗吞掉，0.5s~续播位之间的弹幕被一次性补发。现在 resync 后首拍照常做 seek 跳变检测，且发射端增加兜底——两次发射机会之间媒体时间前进超过 2s（漏检跳变）时清屏重对齐、跳过积压的过期弹幕，任何路径的漏检都不可能再把一大片旧弹幕喷出来。
- **首页「继续观看」与「接下来看」重复**：播了一部分但没看完的剧集会被服务器同时算进两条 Rail——Resume 按 IsResumable 收录它，NextUp 又把它当「第一部未看完的剧」（服务端只认 PlayCount，半集仍是未看）。现在有播放进度的条目只留在「继续观看」，从「接下来看」剔除；首页骨架屏有无记录与剧集详情页「播放」按钮的条目复用同步适配。

## [0.1.5] · 2026-08-30 · Emby 适配、iOS 安装包与自编译预读内核

### 服务器支持

- **新增 Emby 服务器适配**：登录流程探活时自动识别服务器类型（`ProductName` 含 Emby / 主版本 4.x），Emby 走 `/emby` API 前缀与老式路由（媒体库 `/Users/{id}/Views`、继续观看 `/Users/{id}/Items/Resume`），账号密码登录、浏览、播放、图片、字幕、播放上报全链路可用。Emby 没有 Quick Connect（Jellyfin 独有），登录页在 Emby 服务器上只显示账号密码表单；Emby 老版本密码错误返回 400 时也归入「账号密码不对」提示。服务器卡片显示所属类型（Jellyfin / Emby）。
- `ServerProfile` 新增 `kind` 字段（jellyfin/emby）；旧版本落盘的档案无此字段，解码默认 Jellyfin，静默恢复不受影响。
- **多服务器记忆与快速切换**：登录页新增「已保存的服务器」区块，token 还在的一键重连；设置页「服务器」区块列出其余已保存的服务器，支持就地切换和删除（删除连 token 一起清，有确认弹窗）。登出不再等于遗忘——档案持续保留，来回切服务器不用重新输地址。启动恢复也更聪明：当前服务器 token 失效时自动尝试其它有有效 token 的档案，而不是直接弹登录页。

### Emby 真机联调修复

- **标记已看/取消已看失败**：`/UserPlayedItems/{id}` 是 Jellyfin 新式路由，Emby 上不存在（404）。Emby 改走老式 `/Users/{uid}/PlayedItems/{id}`；详情页「标记已看」按钮在 Emby 上恢复可用。
- **播放时 MediaSegments 404 日志噪音**：`/MediaSegments/{id}` 是 Jellyfin 插件提供的端点，Emby 没有。Emby 服务器现在跳过该调用直接回退章节启发式。
- **外挂字幕下载路径**：路由第二段原先硬编码为条目 id，多版本条目（同一影片挂多个 MediaSource）会 404。现从 `/Items` 响应透传真实的 MediaSource id；单源条目行为不变。
- **章节与条目详情解码失败**：Emby 响应洗白规则误伤顶层 `Type` 字段，SDK 解码报 "Cannot initialize BaseItemKind from invalid String value Default"，章节列表每次都拉取失败。改为按 `MediaSources` key 精确处理子树；回归测试覆盖真实机场景。

### iOS

- **首次提供 iOS 安装包**：release 附带未签名 IPA（`OcPlayer-<版本>-ios-unsigned.ipa`），通过 AltStore / Sideloadly / TrollStore 等工具重签安装；与 macOS 包同一内核、同一测试门禁。iPhone 与 iPad 均已真机验证。
- **播放画面手势**：长按 2 倍速（HUD 独立「▶▶ 2.0x」徽章，不唤醒面板）、横滑 seek（独立进度条）、纵滑调节亮度/音量；手势收敛为单一状态机，双击暂停不再被吞，多指不再误触发，切后台/来电自动收尾。
- 打开播放器自动转横屏；iPad 浏览态跟随重力旋转，不再锁竖屏；iPhone 首页横向卡片收紧显示更多内容、详情页紧凑重设计、海报上下渐变适配全端。
- iOS 测试链路修复：测试 target 改为零产品依赖 + BUNDLE_LOADER，Archive 链接失败修复。

### 播放内核（Erika）

- **网络预读缓冲可调**：设置 → 播放 新增「网络预读缓冲」（默认 2 MiB / 8 / 16 / 32 MiB）。公网高延迟服务器（远程 Emby 等）建议 16 MiB 以上，可显著减少播放中的反复缓冲。基于自编译 Erika 内核新增的 `erika_presenter_open_with_options` C API（fork 分支 `feat/http-readahead-option`，已提上游），逐请求生效，本地文件自动忽略。
- 发版内核 `v0.1.7+readahead.1` 的下载哈希固化入仓（`Scripts/erika-v0.1.7+readahead.1.sha256`），构建时可复验。
- 修复拉取脚本 zip-slip 防护对绝对路径归档必然误报的问题（会让全新 CI 环境无法拉取内核）。

### 应用内更新

- 关于区显示版本号，可手动检查 GitHub Release 更新；应用启动与进入设置页时静默检查，发现新版本自动弹窗，支持「忽略此版本」。

### 新功能与优化

- **Jellyfin Clear Logo**：媒体库与详情页支持服务器提供的透明 logo 展示。
- **Bangumi**：播放结束自动标记已看时先把条目推进为「在看」；番剧候选打分算法多维度优化并与剧集季信息联动。
- 详情页海报顶部/底部渐变过渡适配全端。

### 播放器修正

- 弹幕颜色为负数时先夹紧再转换，修复内核 trap 崩溃（P0）。
- seek 不再越过片长；内核重复错误事件去重。
- 保底跳过片尾记入会话，按钮不再原地循环。
- 弹幕「时间偏移」按 overlay 数据显隐；暂停态下弹幕恢复逻辑不再被误触发。
- 音量落盘 300ms 尾去抖并在停止收口补写，消除丢失窗口；2x 临时倍速不再持久化。

### 稳定性与性能

- 播放停止后 malloc pressure relief 四拍调度（+2/+25/+60/+120s），进程占用回落更快。
- RemoteImage 复合加载键守卫修复：图片悬停闪烁（认证头字典序抖动致缓存键漂移）与全量图片不加载回归。
- 详情页横幅渐变被裁剪的回归修复（图片层定高钳制）。
- Bangumi 数据库换 DatabasePool（WAL 多连接并发）；弹幕网关响应单遍解码、mapping 内存缓存；overlay 采样 Timer 频率自适应；Erika idle 帧率档。
- 网络健壮性：429 读取 Retry-After、退避加抖动、鉴权 401 发通知引导重登、用户取消原样透传、MoviePilot 静默重登加看门狗与熔断。

### 工程与质量

- 2026-08-29 全项目 review（161 条）处置完毕：P0–P3 全部收官，覆盖并发、网络、性能、构建与 UI 细节；报告入库 `Reports/review-20260829.md`。
- 发版流水线：tag 构建必过全量测试门禁；Erika 环境准备抽为 composite action；SwiftPM 构建加缓存；`MARKETING_VERSION` 收敛 `App.xcconfig` 单源。
- release 新增 iOS 产物：`OcPlayer-<版本>-ios-unsigned.ipa` 与 `SHA256SUMS-ios.txt`。

### 随 0.1.4 附带但当时说明未展开

以下功能已包含在 0.1.4 的安装包中，当时发布说明过于简略，在此补记：

- Bangumi 全套：OAuth 登录、进度管理、个人主页、收藏列表、番剧日历、播放联动（看完整季自动推进条目状态）。
- MoviePilot 全套：设置页登录、找片下载（搜索 → 选种 → 下载）、订阅管理。
- 播放器章节列表与片头片尾/末 90 秒跳过；弹幕手动搜索选集与 HUD 弹幕菜单。

### 版本

- 版本号 0.1.5。

## [0.1.4] · 2026-08-25 · UI 规范统一与弹幕渲染路线收敛

### 弹幕

- **内核内置弹幕渲染器（Erika DFM+）被禁用**：内核的滑窗重排仍会让在屏弹幕跳轨，本版本起运行时强制走 App 层 overlay（`DanmakuRenderKit`），设置 → 播放内核 中的「用内核渲染弹幕」开关置灰并附原因说明。内核修复后恢复该开关与偏好读取（`PlaybackPreferences.danmakuUseOverlayRenderer` 保留）。

### 界面与交互

- 设计规范统一：状态色、骨架屏、文案、圆角、悬停反馈、键值行展示收敛到同一套样式。
- 高频文案收敛：`UIStrings` 集中常量替代裸字面量。

## [0.1.3] · 2026-08-20 · 弹幕完整链路与播放体验打磨

### 弹幕

- 串起 OcPlay 网关到 Erika 的完整播放链路：已有剧集映射直接复用；首次匹配先用本地文件或带认证头的远程 HTTP Range 数据计算前 16 MiB MD5，再以文件名、哈希、大小和时长一次性匹配；结果与弹幕正文分层缓存，并保留分集时间偏移。
- 播放器 HUD 新增弹幕开关、自动重匹配、手动搜索选集、时间偏移、不透明度、显示区域和顶部 / 底部 / 滚动类型过滤；换片、重试和退出会取消旧任务，并用播放源代次阻止旧弹幕注入新视频。
- 设置页支持编辑 HTTPS 网关地址、以安全输入框保存 API Key 和控制自动加载。未自定义时使用默认网关和内置公共 API Key；显式无效地址才会停用弹幕且不影响视频播放。
- DanmakuKit 增加远程 Range 哈希、匹配编排、缓存格式迁移、请求参数校验和异常弹幕过滤的离线测试。
- 弹幕诊断日志补充安全文件名、大小、时长、匹配模式、哈希是否存在、手动搜索词、Episode ID 和正文数量；不记录完整哈希、媒体 URL、认证头或 API Key。

### 稳定性

- 保护 Erika counted-array 轨道读取：限制填充数量不超过缓冲区容量，并在成功、失败路径释放已填充记录。
- 修复媒体库切换时旧异步请求回写新库状态的竞态；旧请求不能覆盖新数据或提前清除 loading 状态。
- 保证弹幕 fallback ID 避开整批真实 `cid`，并严格校验远程 `206 Content-Range` 的完整性，拒绝截断响应。
- 为 `ServerStore` 的 profile/current ID 复合读改写操作增加统一锁，并补充并发保存回归测试。
- 为字幕副本、播放截图和诊断日志增加启动/每日维护与容量上限；日志同时增加 30 天保留、超大单条保护和旧文件尺寸校验。
- 图片缓存保持 512 MiB 硬上限，设置页新增当前用量和手动清空入口。
- `PlayerScreen`、`DetailView` 拆出独立组件；Jellyfin 客户端版本改为读取 App version/build，弹幕 User-Agent 保持纯 marketing version。
- 从 `AppModel` 抽离 `PlaybackReportingCoordinator`，独立负责 Start / 10 秒心跳 / Stopped 的顺序化与去重；新增 macOS App 测试 target，覆盖后台快照、自然结束与显式退出竞态、重复停止、跨片等待和播放请求身份隔离。
- 明确 Jellyfin 不提供收藏时间；收藏轮播按收藏过滤后使用媒体入库时间倒序，不再描述为“最近收藏”。

### 播放器界面与交互

- 即时播放加载态：loading 覆盖到内核出帧，消除两段式等待；保底 400ms，加载过快不再闪现晃眼；消除出画面白闪。
- 单击播放区切换 HUD，暂停改用空格 / HUD 按钮；点击关闭 HUD 后滑动不再重新打开。
- 加载态隐藏工具栏、取消按钮玻璃化，根治连点取消重来。
- 窗口比例贴合、关闭播放器时窗口先缩再退出、还原同样带弹性动画，不脱节。
- 弹幕开关加 opacity 过渡，弹幕按钮换用 text.alignleft 图标与字幕区分。

### 首页与详情页

- 移除首页轮播图功能。
- 详情页选集改为横向滚动列表，两侧加悬浮箭头（一次滚动 4 集），主按钮按选中集播放；箭头悬停显示。
- 详情页播放旁新增「已看过」按钮，与播放按钮同高胶囊、纯图标样式；继续观看卡角标悬停显示并增加边距。
- 卡片悬停抬升动画更顺滑；首页与横向列表滚动更顺滑；媒体库分页读取与播放体验修正。

### 构建与内核

- Erika 拉取脚本默认解析 GitHub 最新正式版；CI 先解析具体 tag 再建立缓存键，本地构建和打包也会每次检查最新版本并复用同版本完整产物。
- 当前 `v0.1.7` macOS/iOS release 资产已固定 SHA-256；未来未固定的新版本会明确提示校验边界。
- 播放日志统一迁移到 `diagnostics.jsonl`，使用异步串行写入、2 MB 轮转和 3 份保留。
- 设置 → 关于新增独立的开源许可证入口，按依赖图展示 Erika、Jellyfin SDK、SwiftPM 与内核原生组件；发布脚本同步聚合这些组件的许可证文本，缺失时终止打包。

## [0.1.1] · 2026-08-18 · 完善首页海报与播放器界面

### 应用图标与版本

- 新增共享 `AppIcon` 资源集：iOS 使用浅色默认图标和深色外观图标，macOS 使用深色图标并提供 16–1024 px 的完整尺寸。
- macOS / iOS 的 Debug 与 Release 配置均显式使用 `AppIcon`，后续 Xcode 构建会自动编译并写入 App 包。
- 工程版本与 Jellyfin 客户端版本统一更新为 0.1.1；本地打包脚本和 GitHub Release 工作流的默认标签同步为 `v0.1.1`。

### 首页海报与布局

- 轮播横幅宽度改由外层视口真实宽度约束，修复侧栏开合时横向内容宽度泄漏、横幅超出详情列的问题。
- 轮播页码标识从数组下标改为媒体 ID：数据刷新后页码身份保持稳定；冷启动时明确按页首对齐，不再把第一页停在两个页面之间。
- 窗口缩放（live resize）时等布局稳定后无动画重锚当前页，避免用旧页面位置对齐新视口造成错位。
- 修复长标题横幅在窄窗口下左右各被裁掉约 52pt 的问题（边距与约束顺序调整）。
- macOS 窗口最小尺寸设为 960×620，保证英雄区标题边距和操作按钮可读。

### 播放器界面

- 重构播放器 HUD 与本地配置（音量 / 进度 / 倍速等控件布局统一）。
- 新增 P2 HUD 并接入 Liquid Glass 风格。
- 修复音量拖动：拖动过程即时生效，松手不再回弹。

### 播放核心

- 播放地址解析任务支持取消：快速连续切换播放内容时，旧请求不会在新请求之后返回并覆盖播放器；退出、换片、注销时都会取消未完成的解析。
- 系列 / 剧集类条目播放前先解析为具体可播放的剧集（优先「接下来看」，否则取首个未看完的常规剧集），不再把 Series ID 直接送进流地址；续播位置随解析结果联动。

### 验证

- `swift test --package-path Packages/JellyfinKit`：32/32 通过；`swift test --package-path Packages/ErikaKit`：13/13 通过。
- macOS Debug / Release App 构建通过；Release 产物已确认包含 `AppIcon.icns` 与完整 `Assets.car`，App 的 `CFBundleIconName` / `CFBundleIconFile` 均为 `AppIcon`，ad-hoc 签名校验通过。
- iOS target 已解析 `AppIcon` 与浅色 / 深色槽位并进入资源编译阶段；当前机器未安装 iOS Simulator runtime，完整 iOS 构建仍受本机环境限制。

## [0.1.0] · 2026-08-17

### 首页

- 新增轮播：多张英雄图自动切换；设置页新增「轮播使用收藏」开关，可在「最近添加 / 我的收藏」间切换数据来源。
- 修复收藏轮播为空时区域消失的问题：收藏请求失败或收藏全无背景图时按「最近添加」回落，不再整页报错或留空。
- 修复从首页轮播进入详情页时页面背景透明的问题；详情页现在显式使用系统页面底色。

### 修复

- 修复 `JellyfinError.wrap` 错误归类失效：先 `as NSError` 会把 `APIError`（enum）桥接掉，`as? APIError` 永远失败，401/404 全部漏进「其它错误」；改为先判 `APIError` / `JellyfinError`，最后才桥接 `NSError`。
- 图片加载改为「内存解码缓存 + 请求去重」：同一张图并发出现只发一次网络请求（列表快速滚动不重复拉）；任务取消（视图消失 / 换 URL）不再被当成加载失败，换 URL 时旧请求自动作废。
- 保存服务器列表编码失败不再静默吞掉：原来 `set(nil)` 会直接把服务器列表 key 删掉（等于清空已登录服务器），现在失败只记日志、保留旧数据。
- 修复退出播放后立刻再播放时，异步窗口还原可能把新播放窗口误拉回旧帧的问题（还原前校验窗口身份与播放会话）。
- 设置页「关于」的描述同步当前状态：直连策略改为「优先直连直解（DirectPlay），播放前经 PlaybackInfo 选择媒体源；不支持直连的源回退直连流（DirectStream）」（原文案的「码率超限时请求转码」尚未实现）；弹幕改为「暂缓接入」（M3 已暂缓）。
- 修复详情页演员名字 / 角色不显示：演员头像宽高都固定为 108×108（只给宽度时 RemoteImage 占位竖向撑开、文字被挤出可视区），详情请求显式携带 `fields=People,Genres,Overview`（部分服务器版本默认不返回扩展字段）。
- 修复“播放 → 退出播放 → 再次播放”后所有视频都打不开的问题；退出播放时不再把旧源标记为待换片，并直接重建播放引擎，避免旧 presenter 进入不可 reopen 的 closed 状态。
- 修复播放中换片 / 自动连播失败的问题（详情页点另一集、播完自动连播下一集、`onOpenURL` 换片）：换片不再对内核 `close()` 后 `open()`（`close()` 是终态，同一 presenter 不可 reopen，实测抛 `ErikaError "player is closed"`），改为 `stop()` 后丢弃旧引擎重建；播放画面承载视图跟随引擎身份重建（`.id(engine)`），否则新引擎不挂画面、状态事件收不到，换片后 UI 卡在 idle。
- 修复首次连接因网络异常失败后，点击首页重试虽然恢复内容但侧边栏媒体库仍为空的问题；重试和下拉刷新现在会同时重新加载媒体库与首页数据。

### 播放核心

- 接入 `PlaybackInfo` + `DeviceProfile`：播放前先请求服务器媒体源信息，优先选择支持直接播放的 `MediaSource`，并在直连 URL 中带上 `mediaSourceId`；老服务器或 PlaybackInfo 不可用时自动回退到原来的直连 URL。

### 调试

- 增加播放链路文件日志：`~/Library/Logs/OcPlayer/playback.log`，记录引擎创建、open/close/stop/attach/detach、播放状态变化和错误，方便复现“退出后再播放失败”时定位。
- 修复电视剧详情页中系列海报、标题、元数据和播放按钮被 320 pt 横幅裁切的问题。
- 修复分集列表中图片高度随加载状态变化，以及图片和标题在刷新/换季后错位的问题。
- 修复注销后旧会话的首页、媒体库、进度上报、下一集和外挂字幕请求回写新会话的问题。
- 详情页将必要的详情/季/集数据与类似推荐解耦；切季时清空旧集列表并显示加载失败、空列表状态，剧集没有真实集数据时不再播放剧集容器。
- 修复本地视频和手动字幕在 iOS 文件选择器回调结束后失去访问权限的问题；字幕会复制到应用支持目录，视频权限保持到播放结束。
- 修复播放源替换失败后残留当前 URI、音量 0 被当成未保存、字幕字号不持久化等播放状态问题。
- Jellyfin 媒体库浏览改为按 `startIndex` 分页读取全部条目；全剧集请求按季号和集号排序，避免跨季连播顺序错误。
- 自动连播跳过第 0 季（特典/花絮），看完特典不自动跳下一集。
- 首页加载不再因会话切换残留 loading 态；登录后不等首屏数据返回，Quick Connect 轮询流即时结束。
- 网络错误细分：连不上（DNS / 拒绝连接 / 断网）仍提示检查地址，超时 / 连接中断带具体传输错误细节。
- 图片加载失败后，视图再次出现时会重试（之前一次失败永久 404 到退出）。
- 为 iOS 生成的 Info.plist 增加局域网访问说明和 ATS 局域网配置；移除 SwiftPM 锁文件忽略规则，锁定依赖版本。

### Jellyfin 图片数据

- 分集请求显式获取 `Primary` / `Thumb` 图片并按集数排序。
- 分集不再把父剧集的海报 tag 当作自己的图片；`RemoteImage` 在 URL 变化时会清理旧图片状态。

### 验证

- `swift test --package-path Packages/JellyfinKit`
- `swift test --package-path Packages/ErikaKit`
- JellyfinKit 31/31、ErikaKit 13/13 通过（新增「播放生命周期」回归 suite：同源/不同源 `stop` 后重开、`close` 终态锁定、连播换片重建）；macOS Debug App 构建通过。
- macOS Debug App 真实环境人工验证：自动连播下一集（播完 S1E7 → 自动切 S1E8）成功——换片后新引擎重新 attach、状态正常推进到 playing（日志 `playback.log` 实证）；从详情页点另一集与 `onOpenURL` 换片走同一条 `openIfNeeded → open` 路径。
- iOS 模拟器构建因当前机器未安装 iOS Simulator runtime 无法选择 destination；工程配置已写入双端 target。
- macOS Debug App 真实详情页人工验证：系列海报完整显示，分集缩略图与集标题逐行对应。

本轮构建目录均位于 `.local-build/`，不进入版本控制。
