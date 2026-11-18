# OcPlayer macOS 合仓验收 — 2026-11-18

本轮已覆盖的合仓布局、macOS 自动化、真机 GPU／播放、窗口交互及最终包载荷验收通过。原始候选复现了弹幕布局崩溃和外挂字幕无法打开两个实际问题，修复后重新构建并回归；另外更新了与钉点内核不符的预读测试，并补充本地 XML 弹幕的真实 Metal 合成回归。所有已复现失败均已解决。

结论适用于本机 Apple Silicon、SDR 合成媒体和本地服务器 fixture。系统深浅色切换、HDR／Dolby Vision、外接屏及真实服务账户没有取得实测证据，不能据此宣称这些场景通过。

## 源码与合仓状态

| 项目 | 本轮实际值 |
| --- | --- |
| 验收基线 HEAD | `720e4add068050f5677070a656a3e8b28eb9dd51` |
| 本地验收分支 | `codex/macos-monorepo-validation`，修复和报告以本地 index 差异保留 |
| NAS／GitHub 候选分支 | 开始及交付前查询均为 `720e4add`；最终证据 `gitea-refs-final.txt`、`github-refs-final.txt` |
| 两端 main | 查询时均为 `888ccdd8`，本轮没有执行远端切换或发行 |
| 已通过 CI 的源码 | `c4f53462115f52df47023e629e8766e3ea841ee6`，run [44161047381](https://github.com/1824239290/OcPlayer/actions/runs/44161047381) 的十个必需 job 成功；本轮实际查询保存为 `ci-run.json` |
| 初始 Apple／Core tree | 分别为 `fe58a7a45ee762e3adffdfe5c0f9bc57500298bc`、`50d9c2f1017b1ce126add60854009db007ac69e2`；与 CI 提交相同，`diff-from-ci.patch` 为空 |
| 应用／Erika 钉点 | `0.3.0`／liberika `v0.3.6`；版本与 SHA256 钉点保持原值 |
| 本轮修复 patch | `macos-fixes.patch`，SHA256 `98d98a5d3e657c9667ab3f4dd3c0a161a8357f11fe3407855a71601f9b08a4b5`，含代码、回归、provenance 与审计；报告在该 patch 生成后新增 |
| Swift 迁移守卫 | 冻结快照 706 份不变；当前 index 699 份保持原 blob，7 份有精确前后 blob 的授权修复，唯一公共绑定 23 份不变 |

原工作区 `/Users/jumusu/Documents/project/OcPlayer` 的历史检出及既有未跟踪文档保留。此次在隔离 worktree 工作。Windows 交接中尚未提交的关闭回调修复没有进入远端候选；本机仅核对其与 Apple／Core 无关，不将交接的 Windows 真机结果当作本机复测。

## 环境与依赖

Apple M1 MacBook Air，16 GB，arm64；macOS 26.6（25G72）；Xcode 27.1（27A9275）；Swift 6.4；Rust／Cargo 1.99.1；Python 3.15.2。内置 Retina LCD，系统报告 2560×1600、Metal 4。部署目标 macOS 26.0。初始可用空间约 187 GiB，构建后仍有足够空间。详见 `environment.txt`。

Bootstrap、arm64 v0.3.6 下载及哈希核对通过。iOS ZIP 缓存仅在 SHA256 与钉点一致后复用，收据为 `erika-ios-cache-reuse.json`。后续增量构建／打包设置 `SKIP_ERIKA_FETCH=1`，使用已经验过的同一 Vendor。

## 发现与修复

1. **NaN 轨高导致实际宿主崩溃。** 首轮普通 AppTests 为失败，系统产生 SIGTRAP。结果将中断标在 `SubtitlePreferenceTests.testStaleSubtitleBatchCannotEndNewBatchEvenForSameSource()`，实际崩溃栈在 `DanmakuView.recalculateFloatingTracks()` 的浮点数转 Int。偏好差分测试保留 NaN 样本，随后播放器初始化弹幕覆盖层时触发。浮动、顶部、底部轨道现在共用有限／正数／Int 范围校验。新增两个几何回归覆盖 NaN、无穷、零、负值、极小轨高、零尺寸初始化及恢复。DanmakuRenderKit 从 12 项增至 14 项，全部通过。原 `normal-first-summary.json`、首轮 `.xcresult`、`OcPlayer-2026-11-18-151229.ips` 保留。29 次 getter 的偏好实库断言及 NativeCastFacts corpus 没有删减。

2. **v0.3.6 预读测试合同过时，且服务器 fixture 水位算错。** 首轮 ErikaKit 两个预读测试有四条失败；旧断言要求两个重叠请求流，而钉点已使用一个持久流。根据 v0.3.6 tag `59c7a0f91d26fbdfb9e0cf2010c624447c3e623a` 的源码，改为验证初始 `bytes=0-4194303` 与 `bytes=4194304-` 连续、不重叠，并允许 seek 取消在途流后补齐前向窗口。将 fixture 中重复加 start 的水位修正为绝对 offset。小预算回退需要重取头部、大预算回退不重取头部的对照及真实 seek 位置断言保留。原 `erika-real-mac.log` 和 upstream 源码快照保留；针对性与未过滤全量复跑通过。

3. **外挂字幕按钮不呈现 NSOpenPanel。** 在独立 Core Debug app 与首个未经修改的 Release ZIP 载荷均复现；字幕字号等其他按钮正常，字幕导入状态置位后没有面板。将 RootView 的媒体 fileImporter 放到独立背景呈现节点后，播放器字幕 importer 正常工作。真实选择中文空格路径 SRT，画面显示外部字幕；Cmd+O 媒体面板继续正常。最终重新打包的未经修改载荷也完成同样导入。证据 `release-subtitle-import-ax.txt`、`subtitle-fix-import-ax.txt`、`subtitle-fix-external.jpg`、`release-final-subtitle-import-ax.txt`。

4. **补充本地 XML 弹幕 GPU 回归。** 新用例实际载入三条滚动／顶部／底部评论并打 Metal render tick。最终计数 `playing=41 frames / 718 items`，seek 后 `90 / 1861`；关闭显示后帧数保持 90，渲染失败 0；暂停位置不前进。该用例和 ErikaKit 未过滤全量均通过。App 的覆盖层同时由真实 NSView／CoreText 位图、碰撞／时间线／seek／spawn 回归覆盖。

所有 Swift 修复已写入 `follow-up-repairs.json`，没有改冻结 validationCommit 或原 source manifest。`APPLE-SWIFT-OWNERSHIP.md` 已同步当前审计数量。

## 构建与自动化

每阶段完整 stdout／stderr、退出码与时间保存在证据目录；`stages.tsv` 没有未结束阶段。下表列最终有效结果。

| 入口／阶段 | 退出码 | 结果 |
| --- | ---: | --- |
| `python3 scripts/verify-monorepo.py --migration`（layout-final） | 0 | 布局、冻结快照、当前 index 精确 Swift blob 均通过 |
| `python3 -B -m unittest discover -s scripts/tests -v` | 0 | 47 项：35 通过、12 Windows PowerShell 条件跳过；Mac 的真实 Xcode 测试 framework 签名回归已执行 |
| `apps/apple/Scripts/bootstrap.sh`／`fetch-erika.sh v0.3.6` | 0 | 同一钉点依赖与哈希通过 |
| Apple 脚本 unittest | 0 | 3 项通过 |
| `scripts/build-macos.sh debug` | 0 | 初始及 RootView 修复后实际 Debug 构建通过 |
| `scripts/test-apple-app.sh macos "platform=macOS" …`（最终） | 0 | 1027 项：1004 通过、23 条件跳过、0 失败、无 runtime warning |
| `scripts/verify-macos-core.sh …` | 0 | 全入口执行至最末公共合同；Rust 217 项、SDK 41 项、传输／领域合同及 Core-enabled Swift 包通过 |
| 最终实库宿主 `xcodebuild test-without-building`，Core=1、截图导出开启 | 0 | 1027 项：1009 通过、18 个 iOS 条件跳过、0 失败、无 runtime warning |
| ErikaKit 真机 `swift test`，无 CI suite 过滤 | 0 | 最终 28 XCTest + 66 Swift Testing，14 suites，0 失败 |
| `ERIKA_PERF_PROBE=1`、90 秒视频与密集 ASS | 0 | 显式执行 env 门控探针，总用例耗时 115.958 秒 |
| 共享 Apple 源码 generic arm64 iOS simulator Debug build（最终） | 0 | RootView／DanmakuView 的共享修改编译通过；本轮没有将此写作 iOS 真机或完整 AppTests 结果 |
| `scripts/package-macos.sh`（最终） | 0 | Release、ZIP、DMG、dSYM、许可证、校验和通过 |

普通 AppTests 按正式三参数入口构建实库、build-for-testing、嵌入／重签宿主，再 test-without-building。最终 Core 测试复用此含真实 dylib 的最终宿主，环境明确设置 `TEST_RUNNER_OCP_CORE_ENABLED=1` 与实库路径；源码中的两个 RustCoreActivationTests 及每轮 29 getter 实际通过。

完整 Core 入口的首轮 AppTests 为 1008 通过／19 跳过；它曾记录一次 QoS 优先级反转 runtime warning。最终宿主 Core 回归开启弹幕截图导出后为 1009／18，runtimeWarnings 为空。原警告保留，没有掩盖为首次就零警告。

### SwiftPM 包（分别保留两种模式）

| 包 | 普通模式 XCTest／Swift Testing 总数 | 普通条件跳过 | Core 实库模式 |
| --- | ---: | ---: | --- |
| AppDesignKit | 194 + 0 = 194 | 0 | 没有额外领域 Core 替换入口 |
| CoreModel | 19 + 0 = 19 | 0 | 没有额外领域 Core 替换入口 |
| DiagnosticsKit | 97 + 0 = 97 | 0 | 97 / 0（总数 / 跳过） |
| PlaybackKit | 100 + 2 = 102 | 2 | 102 / 0（总数 / 跳过） |
| DanmakuKit | 276 + 0 = 276 | 44 | 276 / 0（总数 / 跳过） |
| DanmakuRenderKit | 14 + 0 = 14 | 0 | 没有额外领域 Core 替换入口 |
| JellyfinKit | 288 + 0 = 288 | 15 | 288 / 0（总数 / 跳过） |
| BangumiKit | 33 + 89 = 122 | 24 | 122 / 0（总数 / 跳过） |
| MetadataKit | 303 + 34 = 337 | 36 | 337 / 0（总数 / 跳过） |
| MoviePilotKit | 114 + 20 = 134 | 30 | 134 / 0（总数 / 跳过） |

所有包均零失败。普通模式 151 条 Core 集成条件跳过在完整 Core-enabled 七个领域包中均实际执行通过；逐条测试名称、原文件行号和跳过理由见 `all-skips-final.json` 的 `swiftPM`。Erika 的性能 probe 在普通全量中由 env 门控直接返回，本轮另显式打开并完成 90 秒采样，不能只凭全量的绿色标记推断采样运行。

## Core 三种状态及实际职责

| 状态 | 已取得的证据 |
| --- | --- |
| 关闭 | 普通宿主全局 Core=0，领域原生路径及注入 fixture 回归通过；普通偏好差分独立临时启用实库，没有削弱 29 getter |
| 启用且库可加载 | SDK 41、七个领域包全部 Core 用例、两个 activation、Native URLSession fidelity 9 项、服务器／仓储／元数据／Bangumi／MoviePilot／弹幕／播放等 C ABI 合同通过；真实窗口 Core 自检 snapshot 有 surface、playing、rate、position、硬解／音频计数 |
| 缺库／ABI 不兼容 | SDK 的 explicit-missing、ABI 版本／必需导出拒绝 fixture 实际通过；未使用“指向不存在路径”推断搜索路径全都缺库，也未删除正式 bundle 中库 |

各领域仍按 [职责合同](APPLE-SWIFT-OWNERSHIP.md) 保留原生 UI／设备／凭据存储及注入依赖路径。启用不等于无条件替换所有依赖，失败不一律原生重放。完整传输、登录／relogin、仓储／进度／旧请求合同检查执行者和重复副作用；最末公共命令合同 6 项通过，生产清单严格为 372 条。`macos-embed.log` 的 deep／strict 验签通过。普通最终 Release 包与 Core 嵌入 Debug 结果分别记载，本轮没有另行声称已验证 Core-enabled 发行包。

## 真机窗口、媒体与交互

合成视频为 `media/中文 空格 合仓测试.mp4`，120 秒、64,369,000 字节、H.264 1280×720 30 fps，两个 AAC 48 kHz 单声道（440／880 Hz），内嵌 zho mov_text。外挂 `media/外挂字幕 测试.srt` 包含中文字幕与 Latin。`media-info.json`、`media/SHA256SUMS.txt` 保留媒体信息和哈希。GPU probe 另生成 100 秒视频与密集 ASS，实际采样 90 秒。

| 检查 | 实际观察及证据 |
| --- | --- |
| 初启／连接 | 独立 app 初启及本地 Jellyfin synthetic 用户连接／登录成功，首页、图标、工具栏／滚动可见；`gui-onboarding.png`、`gui-home.png` |
| 浏览／搜索／排序 | 首页 rail、电影／剧集库、最近添加排序、无匹配搜索空态及取消恢复，电影详情／返回；`gui-search-empty.txt`、`gui-detail.png` |
| 分季分集 | fixture 最终一季两集，最终未经修改的 Release 显示“第 1 季”，第二集选择与 HTTP 播放成功；`release-final-series-ax.txt` |
| 真实画面与音频路径 | 本地中文空格路径和 HTTP fixture 均实际播放；ErikaRenderTests 解码／present／音频推送及硬解计数增长。Core 窗口自检末态 decoded/hardware 627、rendered 1143、audio 1027，render/audio failures=0；`gui-core-selftest-stats.log` |
| 播放控制 | 暂停／恢复、前后 10 秒（暂停时比较位置）、1.5 倍速、静音／音量 1→0.9、两个音轨选择均在实际 UI 观察；fullscreen 原生进入／退出已核对；Core 自检含窗口 resize；最终 package fullscreen 退出有标准全屏幕窗口按钮 |
| 字幕 | mov_text 实际中文字幕、SRT 导入／显示、关闭字幕／切回内嵌／选择外挂、字号 100→110%；最终包直接导入。删除轨道的持久化／并发清理由 SubtitleRemovalTests／ExternalSubtitleConcurrencyTests 自动化覆盖，没有额外 GUI 删除操作 |
| 弹幕 | 选择弹幕 sheet 正常呈现（无匹配空态）；本地 XML 内核 GPU／暂停／seek／显示关闭的实测计数见新回归；App 覆盖层 NSView／CoreText 渲染及时间线／spawn 已回归，实际对照图导出在 `danmaku-render-snapshots/` |
| 错误／清理 | 直连 fixture 404，显示具体 404 错误并允许重试；关闭错误恢复详情，正常退出 0；`missing-media-error-ax.txt` |
| 进度／退出／重启 | 初次 Debug 关闭后继续播放；最终 Release 第二集暂停于 1:01，关闭后 51%，退出 0；新进程恢复至 1:02，播放中退出 0。`release-final-detail-resume-ax.txt`、`release-restart-resumed-ax.txt` 和对应 exit-code |
| 生命周期 | Core 独立窗口关闭、Core 播放中 Cmd+Q、首个原包及最终原包两次退出码均 0；已检查进程状态，不仅依赖结果 JSON。自检通道的 exit(0) 单独作为渲染证据，不能代替上述真实退出 |

fixture 曾把按 parentId 查询季列表回成电影／剧集，第一版季标签因此错误；修复 fixture 并为最终剧集使用新 IDs 避开旧缓存后，最终包季／集结果正确。v1／v2／v3 服务器脚本和请求日志都保留，不把模拟数据错误记作产品缺陷。

早期两个改名 GUI 副本曾共用 bundle ID，电脑控制工具可能重新打开／定位另一副本。识别后仅停止验收进程、改为唯一 ID，并重新验证关键项目。`gui-identity-collision.json` 和这些清理的 143 退出码保留；它们属于测试进程终止，不当作产品正常退出。最终包使用 ZIP 解出的原 ID、原内容，没有改名／重签来冒充包内载荷。

### 90 秒持续渲染

| 指标 | 结果 |
| --- | ---: |
| 解码／硬解帧 | 3000 / 3000 |
| 软件解码帧 | 0 |
| presented／字幕 overlay | 10801 / 3000 |
| `.failed` 事件 | 0 |
| CPU 核数 p50 / p95 / max | 0.302 / 0.335 / 0.347 |
| 物理内存峰值 | 93.4 MB |
| tick p50 / p95 / p99 / max | 1867 / 4168 / 8353 / 86902 µs |

这段 probe 是视频＋密集 ASS，无音轨；音频由有 AAC／tone 的其他真机渲染与窗口检查覆盖。tick 包含呈现等待，不解释为纯 CPU 工作时间。stderr 有系统 PingFangUI 字体无法打开的 libass 告警，fallback 后实际中文画面正常；原日志保留，并不宣称零告警或已修复系统字体资源。

## 最终 Release 载荷

所有最终文件位于 `packages-final/`；早先缺少 RootView 修复的首版保存在 `packages/`，只用于历史复现，不作为最终交付候选。以下包仍标 dirty，因为构建时基线为 720e4add 加本轮可审阅 patch。

| 文件 | SHA256 |
| --- | --- |
| `OcPlayer-v0.3.0-b805-720e4add-dirty-macOS-arm64.zip` | `5c16ad85054cdbf8d44aeb2aec3642c1f34c974b8aeb041a03d19ace2497a77d` |
| `OcPlayer-v0.3.0-b805-720e4add-dirty-macOS-arm64.dmg` | `de345281a26ee40ab4446337309afd6268c4ac619fe5b0e6c0dfb218fca7c56b` |
| `OcPlayer-v0.3.0-b805-720e4add-dirty-macOS-arm64.dSYM.zip` | `a9c75eb2c8b5d06dada429a3f2984400b473461876c42ee71a1e8bd8c6b373cd` |

最终 app 架构 arm64；app／dSYM UUID 同为 `B3DC2575-F41F-3B01-96AD-1BBC80B96117`。ZIP 与只读挂载 DMG 的 40 个普通文件逐字节一致，含 29 份第三方许可／相关材料。`package-final-payload-equivalence.json` 保存清单和可执行文件哈希。deep／strict 验签与 SHA256SUMS 均通过，DMG 已卸载。实际启动后载荷仍逐字节等于原 ZIP，可执行文件前后 SHA256 一致。

最终真实执行路径：

```text
/Users/jumusu/.codex/worktrees/macos-monorepo-validation/OcPlayer/artifacts/verification/macos-handoff-20261118T065850Z/package-final-payload/OcPlayer.app/Contents/MacOS/OcPlayer
```

两次最终启动完成 HTTP 视频、字幕面板／外挂 SRT、分集、续播与退出。签名为本机 ad-hoc；本轮没有执行 Developer ID 公证、安装覆盖、远端 main 切换或正式发布。

## 条件跳过与未实测

以下为最终普通 AppTests 的全部 23 条。前 18 条在 Core 模式仍为 iOS 条件跳过；截图导出在最终 Core 模式实际执行，四条 Core 要求项也实际执行。完整模式数据见 `app-test-skips-final.json`。

| 测试 | 普通模式原始跳过理由 |
| --- | --- |
| `PlaybackSourceFailoverTests/testOldFailureCannotRestoreHistoryAfterNewUserPlayResetsIt()` | Shared request invalidation requires Core |
| `RustCoreActivationTests/testAppTestHostLoadsRequestedRustLibrary()` | Run with OCP_CORE_ENABLED=1 and OCP_CORE_LIBRARY_PATH to verify native integration |
| `RustCoreActivationTests/testCoreDoesNotReplaceInjectedInMemoryServer()` | Run with OCP_CORE_ENABLED=1 and OCP_CORE_LIBRARY_PATH to verify native integration |
| `LibraryGridLayoutTests/testCompactCardMetaIsTwoLinesCenteredInColumn()` | 紧凑宽度版式只在 iOS 上存在 |
| `LibraryGridLayoutTests/testCompactLibraryWallIsThreeColumnsOnPhone()` | 紧凑宽度版式只在 iOS 上存在 |
| `LibraryGridLayoutTests/testCompactSkeletonCardMatchesRealCardGeometry()` | 紧凑宽度版式只在 iOS 上存在 |
| `LibraryGridLayoutTests/testRegularWidthWallKeepsSingleLineMetaAndFixedCardWidth()` | 紧凑宽度版式只在 iOS 上存在 |
| `PlaybackControllerOpenTests/testSharedEngineEventsUpdateControllerSnapshotAndRetainMutedVolume()` | Shared engine integration requires Core |
| `SettingsLayoutTests/testBrandRowIconsAreMonochrome()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testCardEdgesSitAtInjectedContentLeading()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testDarkCardBoundaryRendersOnKnownPageBase()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testDetectorsRejectPageWithoutGlassCard()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testGlassCardMetricsMatchDownloadPageGlass()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testLightCardBoundaryRendersOnKnownPageBase()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testRowMetricsMatchReferenceRhythmOnIOS()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testRowPitchMatchesReferenceRhythm()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testSeparatorStopsAtLabelLeading()` | 紧凑宽度版式只在 iOS 上存在 |
| `SettingsLayoutTests/testTMDbAttributionRendersAtPageBottom()` | 紧凑宽度版式只在 iOS 上存在 |
| `OverlayDanmakuCellRenderTests/testWriteBeforeAfterSnapshotWhenRequested()` | 未设置 OCPLAYER_RENDER_SNAPSHOT_DIR，跳过对照图导出 |
| `HomeLayoutTests/testGapBetweenRailsStaysTight()` | 紧凑宽度版式只在 iOS 上存在 |
| `HomeLayoutTests/testHeaderToCardGapIsTight()` | 紧凑宽度版式只在 iOS 上存在 |
| `HomeLayoutTests/testLatestRailRendersLandscapeCardAtLatestWidth()` | 紧凑宽度版式只在 iOS 上存在 |
| `HomeLayoutTests/testOtherRailsKeepStillCardWidth()` | 紧凑宽度版式只在 iOS 上存在 |

根测试的 12 条跳过均要求 Windows PowerShell：

| 测试 | 原因 |
| --- | --- |
| `test_packaging_accepts_official_v14_crt_folder_versions (test_windows_runtime.WindowsRuntimeTests.test_packaging_accepts_official_v14_crt_folder_versions)` | Requires Windows PowerShell |
| `test_packaging_rejects_debug_or_non_v14_runtime (test_windows_runtime.WindowsRuntimeTests.test_packaging_rejects_debug_or_non_v14_runtime)` | Requires Windows PowerShell |
| `test_packaging_selects_newest_official_release_crt (test_windows_runtime.WindowsRuntimeTests.test_packaging_selects_newest_official_release_crt)` | Requires Windows PowerShell |
| `test_build_defaults_use_this_repository (test_windows_wrappers.WindowsWrapperTests.test_build_defaults_use_this_repository)` | Requires Windows PowerShell |
| `test_build_paths_resolve_before_changing_directory (test_windows_wrappers.WindowsWrapperTests.test_build_paths_resolve_before_changing_directory)` | Requires Windows PowerShell |
| `test_package_output_and_inputs_preserve_caller_location (test_windows_wrappers.WindowsWrapperTests.test_package_output_and_inputs_preserve_caller_location)` | Requires Windows PowerShell |
| `test_prepare_only_is_forwarded_to_the_pinned_kernel_checkout (test_windows_wrappers.WindowsWrapperTests.test_prepare_only_is_forwarded_to_the_pinned_kernel_checkout)` | Requires Windows PowerShell |
| `test_prepare_paths_preserve_caller_location (test_windows_wrappers.WindowsWrapperTests.test_prepare_paths_preserve_caller_location)` | Requires Windows PowerShell |
| `test_start_local_media_path_preserves_caller_location (test_windows_wrappers.WindowsWrapperTests.test_start_local_media_path_preserves_caller_location)` | Requires Windows PowerShell |
| `test_start_media_url_is_not_reinterpreted_as_a_path (test_windows_wrappers.WindowsWrapperTests.test_start_media_url_is_not_reinterpreted_as_a_path)` | Requires Windows PowerShell |
| `test_start_paths_preserve_caller_location (test_windows_wrappers.WindowsWrapperTests.test_start_paths_preserve_caller_location)` | Requires Windows PowerShell |
| `test_verification_output_preserves_caller_location (test_windows_wrappers.WindowsWrapperTests.test_verification_output_preserves_caller_location)` | Requires Windows PowerShell |

SwiftPM 的 151 条普通 Core 条件跳过按包分别为 Playback 2、Danmaku 44、Jellyfin 15、Bangumi 24、Metadata 36、MoviePilot 30，逐条原始理由保存在 `all-skips-final.json`。完整 Core 入口没有这些包跳过。

未实测范围：

- HDR10／Dolby Vision 实际片源、元数据输出、色彩／tone mapping；当前仅有 SDR 合成媒体和内置显示器。
- 外接显示器、跨屏缩放、外部音频设备，原生 Intel／Rosetta 分发。
- OS 全局浅色→深色→浅色切换后生命周期。应用当前没有独立三态主题选择器，跟随系统；本轮实际系统为浅色，播放器自身深色 HUD 已显示。传入 AppleInterfaceStyle Dark 的试验未得到真实深色外观，所以 `gui-dark.png` 不作为通过证据。
- 真正 Jellyfin／Emby／Bangumi／MoviePilot 账号或网络部署。GUI 采用 synthetic Jellyfin，其他请求／账户行为为本地合同 fixture；没有真实用户凭据交互。
- 真实远程片源的长时间网络波动压力。预读／header／回退预算有本地 HTTP 实测，90 秒资源采样为本地媒体。

## 证据与清理

证据根目录：`/Users/jumusu/.codex/worktrees/macos-monorepo-validation/OcPlayer/artifacts/verification/macos-handoff-20261118T065850Z`。完整日志、原始崩溃、结果包、媒体、截图、首轮与最终包、修复 patch 均保留；长边受限 JPEG 预览只用于查看，没有覆盖原图。汇总为 `validation-summary.json`，逐条跳过为 `all-skips-final.json`，关键原始证据校验清单为 `EVIDENCE-SHA256SUMS.txt`。

GUI 存储通过 `OCPLAYER_ISOLATED_STORAGE=1` 进入 `OcPlayerAutomation`。实测 Foundation 的 temporaryDirectory 仍为系统 Darwin 临时目录，TMPDIR 没有为各次 GUI 生成独立存储，故本轮测试有意复用 synthetic 会话；不能将 TMPDIR 当作隔离成立的唯一证据。原始真实 app UserDefaults 在运行原 ID 包之前备份，结束后清除测试额外添加的 fixture cache-identity 键并恢复完整域，plist 内容逐项相等，收据 `preferences-backup/restore-verification.json`。该偏好备份属于本机私有数据，不纳入公开证据清单。

所有 OcPlayer 验收进程结束；本地 fixture 收到 SIGINT 后退出 130（预期清理）；DMG 已全部卸载。真实应用偏好已恢复，本轮产物不覆盖 `/Applications/OcPlayer.app`。下一步合仓应携带本轮修复，裸 720e4add 仍保留本轮发现的两个实际问题。
