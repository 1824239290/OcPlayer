# 氛围背景覆盖清单与验收

「氛围背景图」= 页面底部那张**模糊 + 雾化**的 backdrop（`BackdropAmbienceView`）。
本文件回答两个问题：**哪些界面应该有**、**怎么客观验证它有**。

配套的验收台：`Scripts/verify-ambience.sh`（覆盖契约的唯一事实源是它内置的
`PAGES` 表）+ `Scripts/ambience-probe.swift`（判据实现）。本文件的表格是给人和
代码评审看的同一份清单。

---

## 一、两条机制：为什么两个平台的覆盖方式不一样

| | 机制 | 结果 |
| --- | --- | --- |
| **macOS** | `AppShellView` 根节点 `.background { windowAmbienceLayer }`，层里**常驻** `AmbientBackdropCarousel`；导航栈宿主透明，垫在后面的层能透到屏幕 | **任何**没画底的页面都免费得到背景；有自己主体图的页面用 `windowAmbience(_:)` 声明覆盖它 |
| **iOS** | UIKit 宿主**不透明**（`WindowAmbience.reachesScreen == false`，栈后面垫层到不了屏幕），push 落地后被盖页会被移出窗口 | **每个页面必须自己垫**。没人垫 → 页面落在系统纯色底上（夜间=黑、日间=白） |

结论：**macOS 的覆盖是"结构性"的，iOS 的覆盖是"逐页登记"的**——所以缺口全部在 iOS，
而补法的正解是把挂载点从"N 个页面"收敛到"1 个路由出口 + 少数呈现页"（见 §四）。

---

## 二、覆盖契约（与 `Scripts/verify-ambience.sh --list` 同源）

`gate` 说明启动通道：`section` = 现成的 `OCPLAYER_START_SECTION`；
`route` = 需要 Debug 深链 `OCPLAYER_START_ROUTE`（**尚未实现**，属实施方案 Phase 4）；
`excluded` = 设计上不做。

### macOS（全会话覆盖）

| 页面 | gate | 期望 |
| --- | --- | --- |
| 首页 / MoviePilot / Bangumi / 设置（四个分区根页） | section | 有背景 |
| 媒体库网格页、设置子页、每日放送、详情页（push 进来的） | route | 有背景 |
| 搜索 | excluded | macOS 的搜索在首页工具栏里，没有独立页面 |

### iOS（已补齐：全部 required 页面有背景）

| 页面 | gate | 期望 | 状态（2026-10-13） |
| --- | --- | --- | --- |
| 首页 / MoviePilot / Bangumi / 设置（Tab 根页） | section | 有背景 | ✅ `pageAmbience` |
| 搜索 Tab 根页 | route | 有背景 | ✅ 补（原先整页纯色，而 Tab 栏玻璃底下能透出氛围图） |
| 媒体库网格页 / Bangumi 个人 / 收藏列表 / 条目详情 / 每日放送 | route | 有背景 | ✅ `appRouteView` 的 `.routeAmbience(route)` 一处覆盖 |
| 设置 10 个子页 | route | 有背景 | ✅ 同上（path 路由，无需逐页登记；2026-10-22 承载变更见下） |
| 管理服务器 / 开源许可证 | route | 有背景 | ✅ 呈现式页各自挂 `pageAmbience`；管理服务器已改玻璃卡片流，开源许可证保留系统 `List` 但**行底显式清空**（`listRowBackground(.clear)`，iOS grouped 行底是系统实色） |
| 详情页 / 资源搜索页 / 下载管理页 | route | 有背景 | ✅ 自有主体图（`ownsArt`） |
| 引导页（未登录） | excluded | — | 会话未建立，没有图可用 |
| 播放器 | excluded | — | 画面本身即内容 |
| sheet / 弹窗 / 菜单 | excluded | — | 系统材质浮动层，底下垫图看不见 |

**2026-10-22 设置页换了承载、挂载点没变**：设置 Tab 根页、10 个设置子页、管理服务器与开源许可证详情页
从 `Form` 改成 `ScrollView` + 玻璃卡片流（`SettingsGlassPage`），但氛围底色仍由原来的三处给——Tab 根页
`pageAmbience`、设置子页走 `appRouteView` 的 `.routeAmbience(route)`、两个呈现式页各自挂 `pageAmbience`。
所以上表这几行的 `gate` / 期望值不变，`Scripts/verify-ambience.sh --pages ios.settings` 的判据与期望值同样不变。

---

## 三、图的来源（口径）

1. **会话池**（默认）：首页轮播当前那张——全库随机 8 张 backdrop、12 秒换一张、
   800 宽 URL + 512 解码。所有"不以某个条目为主体"的页面都用它（设置、搜索、
   媒体库、Bangumi 各页、MoviePilot 各页）。好处：push 时背景**天然连续**
   （同 URL、内存缓存命中、`RemoteImage` 首帧即出），零新请求、零闪变。
2. **页面自有主体图**：详情页用条目 backdrop、资源搜索页用海报。
   这类页面的 macOS 实现是 `windowAmbience(_:)` 声明（覆盖整窗层）。
3. **取不到图时**回退 `Color.pageBackground` 纯色，氛围层整体不渲染——
   **"没有图可用"不是缺陷**，验收脚本据此设了前置闸门（见 §五）。

---

## 四、挂载点（新增页面时改哪里）

| 挂载点 | 覆盖 | 现状 |
| --- | --- | --- |
| `appRouteView` 的 `.routeAmbience(route)` | 媒体库 / Bangumi 个人 / 收藏列表 / 条目详情 / 每日放送 / **10 个设置子页** | ✅ 一处覆盖六类路由 |
| 5 个 Tab 根页（`AppShell.compactTabs`） | 首页（轮播组件）/ Bangumi / MoviePilot / 设置 / 搜索 | ✅ 后四个走 `pageAmbience` |
| `navigationDestination(isPresented:)` 调用点 | 管理服务器 / 开源许可证 / 下载管理 / 资源搜索 | ✅ 四处各自挂着 |
| `DetailView` | 详情页（预热 + 兜底淡入 + 未就绪声明 nil） | ✅ 走 `pageAmbience(ownsArt: true)` |
| 设置页（**2026-10-22 承载变更**） | 设置 Tab 根页 + 10 个子页 + 管理服务器 + 开源许可证详情页 | ✅ **挂载点与上表完全一致**：Tab 根页 `pageAmbience` / 子页 `.routeAmbience(route)` / 两个呈现式页各自挂；`Form` → `ScrollView` + 玻璃卡片流只换内容承载，不动这一层 |

**卡换成玻璃后，采样位置要按新卡缘复核**：设置页的卡现在是整块玻璃（浅色下等效不透明度 0.60–0.65），
「卡内 vs 卡外」这类采样若落在卡上，色度会被玻璃压掉——验收台的判据本身不改（见 §五），但如果把采样区
调进/调出卡缘，回归时按新卡缘重新核对一遍期望；设置页当前的内容左右留白（`contentLeading`）没变，
`--pages ios.settings` 仍以留白区为主。

**新增页面时的规则**：① 凡是进 `Route` 的页面由 `.routeAmbience` **自动覆盖**，不用登记；
② 呈现式页面（`isPresented`）必须单独挂 `pageAmbience`；③ 根部是状态视图
（空态/失败态/骨架）的页面必须走 `PageFillingState`（见 §六）；④ 在
`Scripts/verify-ambience.sh` 的 `PAGES` 表加一行，`--list` 就会把它算进契约。

**详情页为什么在路由出口让路**：它的整窗声明在底图未就绪时发的是 nil（"本页暂无氛围"），
外层若再声明一次就会把它盖掉、背景消失——所以 `RouteAmbienceModifier` 对 `.detail` 直通。

## 五、验收怎么跑

```bash
# 1. 看契约（不跑 App）
Scripts/verify-ambience.sh --list

# 2. 校验工具链与环境（判据自检 + App 路径 + 模拟器）
Scripts/verify-ambience.sh --dry-run

# 3. 实跑（macOS；需要 Debug 构建 + 已登录会话 + 屏幕录制权限）
Scripts/clean.sh && SKIP_ERIKA_FETCH=1 Scripts/build-macos.sh debug
Scripts/verify-ambience.sh

# 4. iOS 模拟器（无头，不需要 Simulator.app）
Scripts/clean.sh
xcodebuild -project OcPlayer.xcodeproj -scheme OcPlayer-iOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .local-build/current/DerivedData build
Scripts/verify-ambience.sh --platform ios --device "iPhone 17 Pro"

# 5. 复核模式：不启动 App，直接判一批已截好的图（<页面id>.png/.jpg）
Scripts/verify-ambience.sh --from-image ~/shots --pages ios.search,ios.library
```

产物在 `--out`（默认 `/tmp/ocplayer-ambience-<时间戳>`）：逐页截图 `<id>.png`、
原始指标 `<id>.probe.txt`、人读的汇总 `report.txt`、可 diff 的 `summary.tsv`。
改前改后各留一份 `summary.tsv` 就能直接看出哪一页从「缺背景」变成「有背景」。

### 判据（`Scripts/ambience-probe.swift`）

氛围图是**彩色照片**，纯色页面底是**中性色**——所以取内容左右留白，三者一起看：

| 指标 | 氛围图（实测） | 系统纯色底 | 文字/控件 |
| --- | --- | --- | --- |
| 色度中位数 | 5–32 | **0** | 0–4 |
| 亮度方差 `lum_std` | 2.8–8.4 | **0.00** | 45–72 |
| 平均梯度（双向） | **0.26–0.28** | 0.00 | **7.2–7.9** |

判定顺序：① 有彩色 → 图；② 亮度几乎不变（`lum_std < 1`）→ 纯色底；③ 有变化但
**平缓**（梯度 < 1.0）→ 模糊的氛围图；④ 有变化且**锐利** → 文字/控件，本区域测不了。

**为什么三个都要**：色度单独不够（浅色模式下被白雾压过的氛围图色度只有 4–5，与纯色底
分不开）；方差也不够（模糊图 2.8–8.4 与文字 45–72 都非零，第一版把前者误判成
"区域被内容占据"、报告显示"判不了"）；**梯度**才把它们分开——差一个量级。
梯度必须**双向**扫描：灵动岛黑块横向完全均匀（0.01），只看横向会把系统 UI 当成"图"。

**整页判定 = 多区域投票**：`image` 票多于 `flat` 票算有背景；**平票判 flat**
（保守——把"没验到"说成"验到了"才会让缺口溜过去）；全区域 `content` 则报"判不了"。

退出码：`0` 达标 / `1` 有页面缺背景 / `2` 前置无效 / `3` 环境与用法 / `4` 有页面判不了。

### 两个环境陷阱（都是"环境坏了伪装成被测对象坏了"）

1. **锁屏 / 屏保**：`screencapture` 拿不到窗口内容（整屏截图纯黑、窗口直截直接失败），
   于是每一页都被判"缺背景"——实测跑出过"9 页全判缺背景"的假结论，代码一行没改。
   现在跑前查 `CGSSessionScreenIsLocked` **直接拒绝**，截图后再抽检全黑
   （`--blank-check`）。iOS 模拟器不受影响。
2. **固定 `sleep` 会截到启动骨架屏**：冷启要恢复会话 + 探活服务器地址（每个候选 2s 超时）
   + 两次两段式 push（各 0.45s），慢轮次超过固定等待——实测截到过首页骨架屏，而那时
   判定仍照跑。现在改成等"会话就绪（氛围池已装载）+ 深链落地标记"出现再截；
   **深链超时记为失败、不判定**（那时截到的大概率是首页，而首页有背景，照判会假通过）。

### 前置闸门

诊断日志里必须有「氛围池已装载」（`diagnostics-*.jsonl`）——没有图可用时逐页判定没有
信息量，脚本拒绝给结论（exit 2）。iOS 的日志在模拟器容器里（`xcrun simctl
get_app_container <udid> dev.jumusu.OcPlayer data` 下的 `Library/Logs/OcPlayer`）。

### 已知局限（刻意保留的诚实边界）

* **左右留白假设**：判据假设页面内容有内边距、贴边那几像素是背景。全出血内容
  （播放器、letterbox 视频）会让留白是黑的而报 `flat`——播放器已在 `excluded` 里。
* **灰调照片**：中位色度可能落在 4–6 的边界带。报告会打出原始色度，边界值靠人判断；
  必要时用 `--threshold` 调档。
* **不是像素级比对**：它回答"这块有没有图"，不回答"图对不对、够不够好看"。
  视觉终审仍然要人看报告里的截图。

---

## 六、实现时不要踩的坑（全部是本仓历史判例）

| 坑 | 判例 | 约束 |
| --- | --- | --- |
| 裸根级状态视图把尺寸链塌掉 → 顶栏/导航栏玻璃下没图、露出系统纯白 | MoviePilot 门控页、Bangumi 登录页、媒体库页（`26626de`） | 根级空态/失败态一律走 `PageFillingState`（ScrollView 载体） |
| `.drawingGroup()` 把 `ignoresSafeArea` 截断 → 图出不了内容区、到不了侧栏玻璃底下 | iPad 资源页（`987f3bc`） | iOS 页面层不加 `drawingGroup`（只有 macOS 全窗层可以） |
| fill 溢出参与布局 → 撑大根布局、内容顶出屏幕 | macOS 侧栏时代实测两回 | 一律 `.background {}`（布局隔离）挂载，不做 ZStack 兄弟 |
| 被盖页面漏出（透明页面叠透明页面） | `84adb97` / `91ccd26` | macOS 已有 `coveredPageHidden` / `coveredByPresented`；新增挂载点要回归这两条 |
| macOS 全屏时顶栏是不透明硬底，图被拦腰截断 | `c498924` | 已有 `FullscreenTitlebarFade`，氛围层与衔接层都必须放在动画作用域之外 |
| 冷启动直奔非首页 Tab 时氛围池为空 | `fb36f14`（那次是会话内不再重试） | 池子所有权要从"首页那个视图"上移（实施方案 Phase 1） |

---

## 七、当前状态（2026-10-13）

| 平台 | 结果 |
| --- | --- |
| macOS | **8/8 required 有背景**（含深链进来的媒体库 / 设置子页 / 每日放送 / 详情页） |
| iPhone 17 Pro | **11/11 有背景** |
| iPad Pro 13" (M5) | **11/11 有背景** |

改前基线（同一套判据）：iOS **6 页缺背景 + 1 页判不了**，macOS 0 缺。
**反向验证**：临时短路 `routeAmbience` 的挂载点 → 相关页面立刻判缺背景（exit 1），
还原后复跑有背景（exit 0）。

**这份清单怎么用**：每补完一处就 `Scripts/verify-ambience.sh --pages <id>` 单独验一页；
全量跑通后把 `report.txt` / `summary.tsv` 与截图留档，作为下次改 UI 的回归基线。
`summary.tsv` 是机器可读的逐页结论，改前改后各留一份就能直接 diff。

**未做**：Emby 服务器侧未逐页复核（判据与平台无关，但会话只连了 Jellyfin）；
深色模式未单独跑一轮（`xcrun simctl ui <udid> appearance dark`）。
