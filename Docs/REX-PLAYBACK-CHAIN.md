# Rex 播放链路拆解 × OcPlayer 对照：能学什么、按什么顺序学

> 材料：`~/Documents/project/rex_analysis`（Rex v1.0.2 arm64 脱壳逆向，16 份模块蓝图 11,904 行 + 全量类型字段表）。
> 本侧材料：`rex_analysis/out/ocplayer_chain_map.md`（对当前 HEAD 的逐行测绘）、`rex_analysis/out/player_ui_digest.md`（Rex 播放 UI 侧事实清单）。
> 结论先行：**Rex 真正的强项不是播放器 UI，而是把"选流—开流—失败后怎么办"做成会话内部的一等状态机。我们的链路把这三件事分给了浏览层、控制器和用户**。

---

## 0. 一页结论

| # | 学什么 | 我们的现状 | 价值 | 代价 |
|---|---|---|---|---|
| L1 | **源级多候选 + 失败自动换源** | PlaybackInfo 的多个 MediaSource 选一个就丢 | ★★★★★ | 中（1–2 天） |
| L2 | **失败分类**（决定重试/换源/重新登录/静默） | `setupError: String?` 一句话，全部糊在一起 | ★★★★★（L1 的前置） | 小（半天） |
| L3 | **线路偏好持久化**（记住用户选过的源） | 每次按 directPlay 启发式重选 | ★★★★ | 小（半天） |
| L4 | **下一集预解析**（资源级，不做 IO 级） | 只有元数据窗口查询，无流预解析 | ★★★★ | 小（半天） |
| L5 | **open 阶段收进单一状态机** | 五套代次分散在三层，正确性靠注释与评审 | ★★★（长期收益最大） | 大（3–5 天，可分步） |
| L6 | **跳过片段的自动/倒计时模式** | 只有"常驻按钮"，无自动跳、无倒计时 | ★★★（体验） | 小（1 天） |
| L7 | **起播规格 HUD + 会话级诊断快照** | 数据都拿到了（`latestOutputSnapshot`/`kernelDiagnosticsFields`），没有出口 | ★★（感知强） | 小（半天） |

**不学**：执行许可仲裁（Permit/Probe/Evaluation）、四个并行内核实现、44 个 Provider 槽、68 case 命令枚举、字节预算 IO 层、AirPlay 换内核 —— 理由见 §5。
（注意区分：**"四内核"这个词要拆成两件事**——"配置驱动的多模式"这个形状我们已经学到 80%；"四个并行实现"物理上做不了。详见 §5.1。）

---

## 1. Rex 的播放链路长什么样

### 1.1 全链路时序（含证据）

```
点播放
 └─ PlaybackSession.start()                     ← 会话拥有唯一状态机
      phase: idle → resolving → preparing → ready → playing
      ├─ resourceProvider / resourceResolver    ← 候选资源集合（不是单个 URI）
      │    └─ RexAggregatedPlaybackResourceProvider
      │         · orderedSnapshots / sourceOrder / inputsByProviderID
      │         · failedCandidateIDs / completedSourceIDs / resolving / isProviderDiscoveryFinal
      │         · generation（聚合代次，防旧源快照覆盖新会话）
      ├─ resourcePreferenceProvider             ← 选哪一条：用户钉住的 > 上次确认过的 > 启发式
      │    · explicitResourceID / resumeSourceHint / recordsConfirmedPlayback
      ├─ executionRouter → PlaybackExecutionPermit
      │    · 真正 load/seek 前要"申请许可"，permit 只能消费一次（wasConsumed / didExecute）
      └─ engine.load gen= → install.begin → install.end → engine.ready gen= duration=
      ↓ 失败
 └─ PlaybackEngineFailure(category, message, isRetryable, stopsAutomaticRecovery, authorizationDeniedHosts)
      ├─ authorizationDenied  → 停自动恢复，上报 onPlaybackAccessDenied
      ├─ isRetryable          → PlaybackResourceRecoveryPolicy 节流重开同一资源
      │                          maximumRefreshAttemptsPerResource / refreshAttemptWindow
      │                          / maximumCurrentRequestReplayAttempts / stopsAfterRefreshExhaustion
      ├─ 候选里还有别的        → 换下一条（alternateRequests）
      └─ 内核级失败            → 回退上次可用内核（仅 2.0/实验档）
```

证据：`out/blueprint/09_playback_core.md` §0 / §1.10 / §2.5 / §2.6；类型字段见 `out/fieldnames.txt`：
`PlaybackResource{id, request, requiresResolution, preferenceSourceID, preferenceProviderID, alternateRequests, requestIdentifiers, displayName, quality, sourceName, expiresAt, transport, enginePreference, cacheByteLimit, presentation}`、
`PlaybackResourceRecoveryPolicy{maximumRefreshAttemptsPerResource, refreshAttemptWindow, maximumCurrentRequestReplayAttempts, stopsAfterRefreshExhaustion}`、
`RexAggregatedPlaybackResourceProvider{…, failedCandidateIDs, generation, sourceLeases, orderedSnapshots, isProviderDiscoveryFinal}`、
`RexPlaybackResourcePreferenceProvider{preferenceKey, legacyPreferenceKeys, explicitResourceID, entryProviderID, resumeSourceHint, store, recordsConfirmedPlayback}`、
`PinnedPlaybackResourcePreference{selectedID, sourceID}` / `PreparedPlaybackResourcePreference{selectedID, revision}`。

**这段是整个逆向里最值得抄的部分**：`alternateRequests` 是候选集合，`failedCandidateIDs` 是失败账本，`revision` 是偏好代次，`ResourceRecoveryPolicy` 是重试闸门。四样合起来，"这条片子打不开"从一次性的失败变成一次有预算、有顺序、有记忆的搜索。

### 1.2 状态相位：10 个，谁都能读

`PlaybackPhase`：`failed / idle / resolving / preparing / ready / playing / paused / buffering / ended / closed`（09 §1.1-A）。

关键差别不在数量，在于 **`resolving` 和 `preparing` 是两个不同相位**：前者"还没有源"，后者"源定了、内核在开"。我们只有一个 `opening`，把这两件事压成了一段不可观测的黑盒——这正是 loading 层要写 90s 兜底轮询（`AppModel+Playback.swift:251-316`）的根因。

### 1.3 双向契约：命令进、快照出

- **进**：`PlaybackCommand` 68 case（09 §1.2 1:1 还原，tag 函数 `0x102760020` → reducer `0x10282a1f8`，跳转表 48 项 → 38 handler，见 `15_p0_followups.md` P0-3）。UI 只翻译手势，不做业务判断。
- **出**：唯一出口 `onStateChanged`，载荷是**快照**不是事件流：3 个主快照（`PlaybackStatusBarState` 11 字段 / `PlaybackSystemSnapshot` 11 / `PlaybackStartMediaSpec` 11）+ 12 个子快照（DanmuState 24、SubtitleState 24、ExternalPlaybackState 9…）。高频状态靠 `stateNotificationBatchDepth + batchedStateOrigin` 合并后才发一次。
- 引擎侧 24 个事件（`PlaybackEngineEvent`）只进会话，UI 永远看不到。

我们的对应物：`PlayerState`（`@MainActor @Observable`）逐事件折叠 + `PlayerTimeline` 100ms 节流 + 缓冲双迟滞（300ms/500ms）。**这件事我们已经做对了大半**——Rex 的 batchDepth 解决的是"一次用户操作引发 N 处状态变化"，我们有 `@Observable` 的字段级依赖跟踪，等价性够。差距只在"UI 拿不到一个合并后的值对象"，这属于 L5 的副产品，不急。

### 1.4 内核抽象：1 个协议 + 32 个能力协议 + 44 个 Provider 槽

- `PlaybackEngine` 只有 **9 个见证槽**（renderingView / onEvent / 状态对象 / load / play / pause / seek / rate / teardown）。
- 其余能力拆成 32 个窄协议（Seek / SeekPreview / Subtitle / SecondarySubtitle / Translation / PiP / Disc / Prewarming / URLRefresh / ExecutionOwner…），全由同一个 `KSPlayerPlaybackEngine` 实现。
- 会话侧 `PlaybackCapabilities` 有 **44 个 Optional 槽**；某槽为 nil = 能力不存在，UI 隐入口、命令回 unavailable。
- **"四内核"是同一个类的四种配置**（`KSPlayerPlaybackConfiguration` 27 字段：`enablesProAVPlayer`/`prefersSampleBufferPlayback`/`convertsDolbyVision7To81`…），不是四份代码。

对我们的意义：我们已经是"1 协议 + static capability + 默认空实现"（`PlaybackEngine.swift:29-270`，`supportsBackgroundAudio`/`supportsKernelDanmaku`/`supportsSubtitleStyle`），**形状已经对了，不需要抄 44 槽**。Rex 之所以要槽，是因为它四种模式的能力差集很大。

### 1.5 预加载：三层，闸门是字节和覆盖度，不是秒数

| 层 | 类型 | 做什么 |
|---|---|---|
| 策略 | `RexPlaybackPreloadPolicyProvider`（33 字段） | host 规则匹配（`BackendPlaybackPreloadRule{host, cacheSize, preCacheSize, detailPreCacheSize}`）+ 服务器能力探测（`MediaServerPreloadCapability{nextItemBytes, detailBytes, cacheLimitBytes, validUntil…}`，头 `X-PreloadLimit-Bytes`）+ 网络/蜂窝/seek 稳定性门控 |
| 协调 | `PlaybackNextItemPreloadCoordinator`（23 字段） | 状态机 `idle → waiting_current_cache → waiting_contiguous_coverage → next_item_available`，分叉 `engine_token_invalid / next_item_unavailable / cancelled_cache_coverage_lost`；`completedPrewarmTokens` 防二次采用，`failedPrewarmRequestIDs` 防重复失败 |
| 执行 | KSPlayer `PreLoadIOContext` 家族 + `installResource(_:prewarmed:generation:)` | IO 级预读 + `layer.create.prewarmed` 秒切 |

预算收敛（09 §4.2 第 4 步，`[推断]`）：
`targetByteCount = min(rule.preCacheSize, capability.nextItemBytes, capability.cacheLimitBytes, policy.maximumTargetByteCount)`，硬上限 **100 MiB**（`0x6400000`，`0x1007fb5ec`）。

**可抄的是前两层，第三层抄不了**：liberika 的 C API 只有 `http_read_ahead_bytes` / `http_back_buffer_bytes`（`crates/erika_capi/include/erika.h:57-70`），没有"第二个 IOContext / 预热句柄"的口子。

---

## 2. 逐段对照表

| 段 | Rex | OcPlayer（当前 HEAD） | 判定 |
|---|---|---|---|
| 选流 | 会话内候选集合 + 偏好 + 聚合代次 | `info.preferredSource` 取一条，其余丢弃（`AppModel+Playback.swift:118`、`PlaybackInfo.swift:136-143`），`PlaybackRequest.uri` 单值（`PlaybackRequest.swift:9`） | **差距 L1** |
| 选流记忆 | `Pinned`/`Prepared` 偏好 + `revision` + `recordsConfirmedPlayback` | 无。每次重算 `preferredIndex` | **差距 L3** |
| 状态机 | 10 相位，会话独占 | `PlaybackState` 8 值（`idle/opening/ready/playing/paused/stopped/closed/error`），open 阶段没有单一所有者 | **差距 L5** |
| 失败语义 | `PlaybackEngineFailure{category, isRetryable, stopsAutomaticRecovery, authorizationDeniedHosts}` | `setupError: String?` + `failedRequestID`（`PlaybackController.swift:97-101`），内核 `failed(code:message:)` 的 code「只进日志，不参与任何逻辑判断」（`PlaybackTypes.swift:64-67`） | **差距 L2** |
| 失败后动作 | 分类→节流重开 / 换源 / 换内核 / 停自动恢复 | `resetEngine()` + 一句话 + 等用户点重试（`PlaybackController.swift:944-971`） | **差距 L1+L2** |
| open 看门狗 | `preparation_deadline` 检查 | 60s，**按扣除挂起的真实运行时长**，未到点补睡差额（`:1002-1061`） | **我们更强** |
| 卡死看门狗 | 未在报告中找到等价物 | 2s 轮询 / 5s 判定 / `recovered=true` 补账（`:1226-1279`） | **我们更强** |
| 首帧撤 loading | `hasRenderedFirstFrame` 协议强制 | 首帧 + 400ms 保底 + 90s 与看门狗对齐（`AppModel+Playback.swift:251-316`） | **我们更强** |
| 挂起往返 | `setBackgroundAudioOnly` 档位 | `beginSystemSuspension/endSystemSuspension` + 内核仅音频档 + 回前台静默重建 | **我们更强** |
| 上报 | `progressTask` / `remoteProgressTask` 两条 | 心跳 1s / 进度 10s / 串行化（Start 等 Stopped）+ 真超时 5s（`PlaybackReportingCoordinator.swift`） | **我们更强** |
| 错误折叠 | `ResourceRefreshPolicy` 同类 | 片尾陈旧 EIO 窄口径折叠（`PlayerState.swift:260-345`） | 持平 |
| 状态回流 | 15 类快照 + 批量深度 | `@Observable` 逐字段 + `PlayerTimeline` 100ms + 缓冲双迟滞 | 持平（我们不必改） |
| 命令面 | 68 case 枚举 + 跳转表 | 直接方法调用 | **不必抄**（见 §5） |
| 预加载 | 三层 + 字节预算 | 只有内核级 `readAheadBytes`/`backBufferBytes` 档位（`PlaybackPreferences.swift:240-266`），无 next-item 预解析 | **差距 L4** |
| 跳过 | 6 来源 + automatic/manual/custom + 提前 N 秒提醒 + 倒计时可取消 | 6 来源按 rank 合并（`PlaybackChapter.swift:48-73`，含 `learned` 学习源）+ 常驻按钮，**无自动跳、无倒计时**（`PlayerHUDActions.swift:1004-1042`） | **差距 L6**（我们来源侧更强） |
| 起播规格 | `PlayerStartSpecHUDView` + `seenStartSpecToken` 防重复 | 无 UI；数据在 `latestOutputSnapshot`/`kernelDiagnosticsFields()` | **差距 L7** |
| 能力自报 | 44 Provider 槽 | static capability + 默认空实现，已正确 | 持平 |

---

## 3. 七个可学点，按性价比排序

### L1 · 源级多候选 + 失败自动换源（最高价值）

**Rex 做法**：`PlaybackResource.alternateRequests` 让一次请求携带整组候选；聚合 Provider 保留 `orderedSnapshots` 全序；失败进 `failedCandidateIDs`；`selectResource` 是会话命令，播放中可切。

**我们的落点**：

1. `PlaybackRequest` 增加 `alternates: [PlaybackSourceCandidate]`（`uri` 保持"当前首选"语义，不动现有调用方）。候选由 `PlaybackInfo.mediaSources` 映射：每条 source 生成 `directPlay`（`/Videos/{id}/stream?Static=true&mediaSourceId=X`）与 `transcode`（`/Videos/{id}/stream?...&VideoCodec=h264` 由服务端协商）两种形态，按 `MediaSourceSelection` 同款规则排序。
2. `PlaybackController` 维护 `failedCandidates: [PlaybackCandidateID: FailureCategory]` + `candidateAttempts`，`finishOpenFailure` 里：可换 → 换下一条重开（复用 `open(_:securityScopedURL:request:)`，它已经会给新引擎身份并作废旧 token）；不可换/耗尽 → 现有 `setupError` 路径不变。
3. 播放器菜单加"线路"列表（`sessionContext.mediaSourceID` 已有，展示层是现成的）。手动切换 = 带新候选重开一次。

**代价**：JellyfinKit 映射（~80 行）+ 控制器换源分支（~120 行）+ HUD 线路面板（~120 行）。**不碰内核**。

**验收**：断网/给一个不可达的 mediaSourceID，播放在 2 次以内自动落到下一条，`PlaybackEvent` 里出现 `open.start/open.done` 成对且 `ok=false→true`；用户手动选的线路下次同条目自动预选。

---

### L2 · 失败分类（L1 的前置，必须一起做）

**Rex 做法**：`PlaybackEngineFailure.category` + `isRetryable` + `stopsAutomaticRecovery` + `authorizationDeniedHosts`。

**我们的落点**：

```swift
// Packages/PlaybackKit/Sources/PlaybackKit/PlaybackTypes.swift
public enum PlaybackFailureCategory: String, Sendable {
    case network      // DNS / 连接 / 超时 — 可换源、可换地址重试
    case format       // 容器/编码不支持 — 可换源（转码），不可原地重试
    case auth         // 401/403 — 触发重新登录，不换源
    case resourceGone // 404/410 / 片源过期 — 换源
    case aborted      // 用户取消 / 让位 — 静默
    case server       // 5xx — 节流后重试同一源
    case unknown
}
```

判定点收敛在 `PlaybackController.open` 的错误出口 + 看门狗（看门狗现在是硬编码文案 `:1038`，改成 `.network`）。`setupError` 保留字符串给 UI，但旁边多一个 `failureCategory` 给逻辑用。

**代价**：半天。**收益**：L1/L4 的所有分支判断都依赖它；同时让诊断日志能按类别聚合（现在的 `open.done` 只有 `error: String`）。

**验收**：`PlayerState` 的片尾折叠、`sourceOpenFailed` 上报、`retryLast` 三条路径都能按键值判断而不是字符串匹配。

---

### L3 · 线路偏好持久化

**Rex 做法**：`RexPlaybackResourcePreferenceProvider{preferenceKey, explicitResourceID, resumeSourceHint, recordsConfirmedPlayback}` + `PinnedPlaybackResourcePreference{selectedID, sourceID}` + `PreparedPlaybackResourcePreference{selectedID, revision}`。三层含义：①用户显式选的 ②这次会话预选好的（带 revision 防串）③实际播满多久才算"确认"。

**我们的落点**：`PlaybackPreferences` 加一组按 `(serverID, itemID)` 存的 `preferredMediaSourceID`，`openPlayback` 选源时优先读它，用户手动切换时写回。`recordsConfirmedPlayback` 这一层先不做（我们用"选了就记"即可）。

**代价**：半天。**验收**：多版本条目第二次播放直接用上次的源，不需要用户再选。

---

### L4 · 下一集预解析（资源级，不做 IO 级）

**Rex 做法**：见 §1.5 前两层。**我们只做第一层**：在播过 ~80% 时后台跑下一集的 `resolvePlayableItem → playbackInfo → streamURL → 弹幕搜索 → 章节`，把结果挂进一个带 `requestID` 代次的值对象。

**我们的落点**：`AppModel+Playback.swift` 已有 `nextEpisodeWindow = 6` 的元数据窗口查询（`:853-886`），把它扩展成 `NextEpisodePreparation`：
- 触发点：`timeline.progress >= 0.8`（无片尾章节时）；有片尾章节时用章节起点前 `creditsLeadTime`。
- 失效条件：`requestID` 变了 / 用户 seek 到 < 50% / 网络切蜂窝。
- 采用：连播触发时直接 `presentPlayback(prepared)`，跳过 1–2 个 RTT + 弹幕匹配等待。

**不要做**：`http_read_ahead_bytes` 已在 open 时定死（`ErikaPresenter.swift:60-64`），IO 级预热没有口子；不要自己 hack IOContext。

**代价**：半天。**验收**：连播时 `open.start → open.done` 的 `elapsed_ms` 明显下降，弹幕不再"进播放器后 2 秒才出"。

---

### L5 · open 阶段收进单一状态机（长期收益最大）

**Rex 做法**：`resolving` 与 `preparing` 分开，会话独占全部相位；引擎只暴露 9 个槽；执行前要拿 `PlaybackExecutionPermit`，permit 一次性消费（`wasConsumed`/`didExecute`），失败后 `PlaybackExecutionEvaluation.attemptedFreeEvaluation` 决定能否不重新授权地重试。

**我们的现状**（`ocplayer_chain_map.md` §4 / §12）：`sourceGeneration` + `expectedRequestID` + `PlaybackOpenAttempt` + `PlayerState.consumptionGeneration` + `ActivePlaybackIdentity` **五套代次分属三层**，配合后台并发队列、2+4 槽位计数、看门狗放弃额度、"僵尸引擎"判据。这些注释写得很清楚，但正确性靠评审，不靠结构。

**我们该抄的是形状，不是许可机制**：

```swift
// PlaybackKit 里新增一个纯值状态机（可单测、无副作用）
public enum PlaybackOpeningPhase: Sendable, Equatable {
    case idle
    case resolving(requestID: UUID)          // 还没有源：候选解析中
    case preparing(requestID: UUID, generation: UInt64, candidate: Int)
    case ready(requestID: UUID, generation: UInt64)
    case failed(requestID: UUID, category: PlaybackFailureCategory)
    case cancelled(requestID: UUID)
}
```

控制器只维护这一个 `phase`，五套代次里至少 `expectedRequestID`/`sourceGeneration`/`attempt` 的判定收敛成一个 `transition(to:event:)`。**不要一次重构完**：先加 `phase` 作为**只读派生物**（由现有字段算出），跑一周对账；对得上再把判定搬进去。

**代价**：分三步，每步 1–2 天。**验收**：给状态机写表驱动测试（Rex 的 48 项跳转表就是可测的），覆盖"open 在飞期间换片/取消/看门狗/挂起恢复"四种交叉。

---

### L6 · 跳过片段的自动/倒计时模式

**Rex 做法**：`skip.mode ∈ {automatic, manual, custom, disabled}`；`skip.prompt=提前 N 秒提醒`，文案 `prompt.before=%lld 秒前 / prompt.after=%lld 秒后`；UI 是**双卡**（跳过卡 + 取消倒计时卡），`progressWidthConstraint` 驱动倒计时进度条；`cancelledSkipSegmentIDs` 记住用户取消过的片段，`presentationGeneration` 防倒计时卡重渲染串帧。

**我们的现状**：6 个来源 + rank 合并（含 `learned` 学习源，这一点我们比 Rex 细）；但只有常驻按钮，`skippedIDs` 是**跳过之后**才去重，**用户不想跳时按钮会挂满整段**，也没有自动跳。

**我们的落点**：`ChapterSession` 加 `declinedIDs: Set<String>`（用户点"取消"后本会话不再弹该段）+ 一个 `SkipCountdown` 值对象（`deadline` / `remaining` / `generation`）。`PlayerSkipPromptView` 变成双卡：主卡 + 取消卡，倒计时到点自动 `performSkip()`。

**代价**：1 天。**验收**：设置里选"自动跳过 + 提前 5 秒提醒"，进片头 5 秒时出卡并可取消，取消后本集不再弹、下一集恢复。

---

### L7 · 起播规格 HUD + 会话级诊断快照

**Rex 做法**：`PlayerStartSpecHUDView`（左上角 pill：分辨率/动态范围/编码/音频），`seenStartSpecToken` 防重复弹，`startSpecDisplayDuration` 秒后隐藏，外放时用 displayLink 轮询规格。

**我们的现状**：`latestOutputEncoding` / `latestOutputSnapshot` / `latestStats` / `kernelDiagnosticsFields()` 全都在（`PlaybackEngine.swift:49-68`），**只是没有出口**——数据在内存里转一圈就丢了。

**落点**：`PlayerScreen` 顶栏加一个 pill，显示 `videoParams` + `latestOutputSnapshot`（面格式/回退原因/有效 headroom）+ 首帧耗时（`open.done.elapsed_ms` 已有）。回退原因那一栏是排障神器：现在"源是 HDR 却出 SDR"只能靠读日志。

**代价**：半天。**验收**：HDR 源起播时能直接看到"出的是 EDR 还是 SDR、为什么回退"。

---

## 4. 我们已经比 Rex 好的地方（别学反了）

| 项 | 我们的实现 | Rex 的报告里 |
|---|---|---|
| open 看门狗 | 60s 按**真实运行时长**（扣挂起），未到点补睡差额 | 只有 `preparation_deadline` 检查 |
| 卡死检测 | 2s 轮询 / 5s 判定 / 恢复补账（`stall` 事件成对） | 未见等价物 |
| loading 撤除 | 首帧 + 400ms 保底 + 90s 兜底，且有"30s 回归"的教训记录 | `hasRenderedFirstFrame` |
| 上报 | 串行化 + 真超时 + 暂停只报一次 | 两条 task，未见串行化 |
| 系统挂起 | 内核仅音频档 + 回前台静默重建 | `setBackgroundAudioOnly` 档位 |
| 跳过来源 | 6 源 + rank + **行为学习**（`learned`） | 6 源 + 用户拖动排序 |
| 片尾陈旧 IO 折叠 | 窄口径（片尾 2s + `av_read_frame` + `(-5)`），有回归用例 | `ResourceRefreshPolicy` 同类 |

**结论**：我们缺的不是"防线"，是"选流与失败后的策略层"。Rex 那套防线的细粒度反而不如我们。

---

## 5. 明确不学的

| 不学 | 理由 |
|---|---|
| **执行许可仲裁**（Permit/Probe/Evaluation/Context） | 那是**付费授权**的产物：`rex-paid-router:b36ef8e1…`、`PlaybackAccessDenial(message, requiresUpgrade)`、`PlaybackExecutionAccess{signed/unrestricted/legacy}`（09 §2.5）。我们没有付费墙。抄过来就是给一次 `open` 加两层没用的间接。**注意：这跟"四内核"是两件事**，见 §5.1。 |
| **44 个 Provider 槽** | 四内核的能力差集大才需要槽；我们的 static capability + 默认空实现已经能表达"不支持 = 安全空操作"，且注释里已经记了 `any` 静态派发的坑。 |
| **68 case 命令枚举** | 收益是"可录制/可回放/可延迟派发"。我们目前没有这个需求，而引入枚举会要求把 `PlaybackController` 现有 60+ 公开方法全部改签名——纯迁移成本，没有新能力。**等 L5 的状态机落地后再评估**，那时命令面才有落点。 |
| **字节预算的 IO 预加载层**（`X-PreloadLimit-Bytes` + `PreLoadIOContext`） | liberika 的 C API 只有 `http_read_ahead_bytes`/`http_back_buffer_bytes`，没有预热句柄或第二个 IOContext（`erika_capi/include/erika.h:57-70`）。**做 L4 的资源级预解析就够了**。 |
| **AirPlay 换内核 + 字幕旁路 HTTP 服务** | 需要"本地内核 + 系统播放器"双栈（`airPlayReplacedLocalCore`）。我们只有 Erika，没有第二条渲染路径。 |
| **队列分组选集**（`queueGroups`） | 我们的"连播 + 下一集"模型已覆盖；Rex 的 queueGroups 面向"多部合集一次解析"。 |
| **音频会话限流队列**（32 次/60s） | Rex 是因为换内核/换 AirPlay 会频繁碰 `AVAudioSession`；我们单内核 + 挂起往返已处理。 |

### 5.1 单独特论：四内核能不能学

**先看清它是什么。** 09 §2.1/§2.3 的结论：全库只有**一个** `PlaybackEngine` 实现类（`KSPlayerPlaybackEngine`，32 个协议一致性），四个"内核"是同一个类的四种运行模式，由 `KSPlayerPlaybackConfiguration` 27 字段切换（`enablesProAVPlayer` / `prefersSampleBufferPlayback` / `forcesMetalRendering` / `convertsDolbyVision7To81` / `defaultEnginePreference` …）。**"四内核"是设置页的四档文案，不是四份代码。**

所以这个问题要拆成两问：

| 问 | 答 | 依据 |
|---|---|---|
| ①「配置驱动的多模式」这个工程形状能学吗？ | **已经在学，且骨架比 Rex 干净** | `PlaybackEngineDescriptor` 6 字段 + `PlaybackEngineRegistry`（register / selected / `selectionIsStale` 静默回退）+ `PlaybackEngineAssembly` 唯一装配点（"加一个内核 = 加一行 register"）；`PlaybackKernelSection.swift:8-9` 注释明确写：`available.count > 1` 时**自动变选择器，不用改 UI**。Rex 的能力差要 44 个 Optional 槽表达，我们靠 static capability + 默认空实现。 |
| ②「四个并行实现」能做吗？ | **物理上做不了，且做出来是重复劳动** | 见下 |

**②的两条硬阻塞：**

1. **Erika 的多后端选择权不在宿主手里。** liberika 内部确实有多后端——`RendererBackendPreference{PlatformNative, FlutterTexture, WgpuFallback, Auto}`（`core.rs:83`）、`DecoderBackend{Software, Cuda, Vaapi, VideoToolbox, D3d11va, MediaCodec, AvCodec}`（`ffmpeg.rs:885`）、`AppleDecodeBackend{VideoToolbox, Software}`（`apple.rs:17`）——但 **C API 只给"看"，不给"选"**：创建配置 `ErikaPresenterConfig` 只有 4 个字段（`output_mode` / `edr_headroom` / `luma_upscaler` / `video_alpha_mode`，`erika.h:296-301`）；后端信息只以**只读**形式出现两处——`ErikaUpscalerStatus.active_backend`（`erika.h:351`）与 `erika_presenter_get_diagnostics_json` 的 "decoder and hardware-decode path"（`erika.h:986-995`）。**没有任何字段能选解码/渲染后端**，运行时由探测 + 内部回退决定。想在 Erika 里做"内核 1.0 / 2.0"这种后端档位，**必须改 liberika 加 C API 字段**，成本会转移到每次升级。
2. **ProAVPlayer 那条路是纯重复。** 它 = `DemuxerIO` + `RemuxerIOAction` + `ConversionToM3U8` + `LocalHLSServer`，27 个函数，本质是自己写 remux→本地 HLS→AVPlayer 的管线（09 §3）。我们的 Erika 已经是 FFmpeg 全格式 + 精确 seek，把这条路的收益（兼容性）先占了；再写一遍只换来"原生 DV/Atmos 直通"。

**那"第二个内核"还值不值得加？值得，但只值得一个，理由不是"兜底"。**
"格式兜底"不成立——Erika 是 FFmpeg，覆盖面本来就比 AVPlayer 广。真正的增量只有 **AVPlayer 能给的系统级能力**：PiP（我们完全没有，`ocplayer_chain_map.md` §7「PiP 未见」）、AirPlay 原生（**这正是 Rex 换内核最真实的动机**，`airPlayReplacedLocalCore`）、FairPlay DRM、系统 EDR 处理。

**如果加，怎么不背 Rex 的账？** 三条：

1. 第二个内核**不做成用户可选档位**，由 L2 的错误分类**自动触发**（`.format` / `.resourceGone` 且首选已失败 → 换 AVPlayer 重开一次）。用户不需要知道有两个内核——Rex 的四档选择器带来的是"实验内核不支持 AI 字幕"这类必须写进用户文档的能力差说明。
2. 能力差走 static capability（`supportsKernelDanmaku` / `supportsSubtitleStyle` / `supportsBackgroundAudio` 已到位），**不加 Optional 槽**。
3. 不做 remux 管线。`AVPlayerEngine` 只要 `makeSurfaceView()` 返回 `AVPlayerLayer` 的 representable、`hasRenderedFirstFrame` 用首帧观察者 —— **`PlaybackKit` 一行都不用改**，协议早就允许。

**结论**：现在不做四个。做两件准备，让"将来加一个"变成一天的事——L2 错误分类（所有自动回退的开关）+ L1 多候选（回退的落点）。这两件本来就在 §6 的第 1、2 步里。

---

## 6. 落地顺序

```
第 1 步（1 天）   L2 错误分类 + L3 线路偏好（两者都不碰 open 主流程，风险最低）
                    └─ 产出：PlaybackFailureCategory、preferredMediaSourceID
第 2 步（2 天）   L1 多候选 + 自动换源 + HUD 线路面板
                    └─ 依赖第 1 步的分类；不碰内核
第 3 步（1 天）   L7 起播规格 HUD（顺手把 open 耗时/回退原因可视化，为第 4 步提供观测）
第 4 步（1 天）   L6 跳过倒计时 + 取消语义
第 5 步（2 天）   L4 下一集预解析（资源级）
第 6 步（分 3 次） L5 open 状态机：先只读派生 → 对账 → 搬判定
```

前两步就能把"这条片子打不开"从"用户点重试"变成"自己换一条"——这是这次逆向里性价比最高的一件事。

---

## 7. 复核入口

想自己验证本文件的每条断言：

```bash
# Rex 侧
cd ~/Documents/project/rex_analysis
sed -n '383,442p' out/blueprint/09_playback_core.md     # 资源解析/刷新/授权 + 事件
sed -n '589,710p' out/blueprint/09_playback_core.md     # 执行仲裁 + 自动回退
sed -n '813,975p' out/blueprint/09_playback_core.md     # 预加载全链
grep -n 'PlaybackResourceRecoveryPolicy\|alternateRequests' out/fieldnames.txt

# 本侧
cd ~/Documents/project/OcPlayer
sed -n '113,130p' App/Shared/AppModel+Playback.swift     # 单源选流
sed -n '944,971p' App/Shared/Features/Player/PlaybackController.swift   # 无分类的失败路径
sed -n '136,143p' Packages/JellyfinKit/Sources/JellyfinKit/PlaybackInfo.swift  # preferredSource
sed -n '240,266p' App/Shared/Features/Player/PlaybackPreferences.swift # 预读/回退档位
```

---

## 8. 多内核兜底：怎么改（落地清单）

> 对应桌面那份清单 §5「后续路线（内核层）」的第 1 条 + 第 3 条。目标：让"换内核"成为一次**自动降级**，不是设置页里的第四个选项。

### 8.1 先纠正前提：多内核兜底是三件套，不是"再加一个内核"

```
用户感知到"它换了个内核救回来了"
        ↑
   ① 触发条件：错误分类（L2）      ← 没有它，不知道什么时候该换
   ② 回退落点：源级候选（L1）      ← 没有它，换个内核还是同一个死 URL
   ③ 执行者：内核链 + open 重开    ← 本节新增
```

只做 ③（写 AVPlayer 适配器）而不做 ①②，兜底永远触发不了——因为现在 `finishOpenFailure` 拿到的只有一句 `String`，它分不清"这个 URL 死了"和"这个内核解不了"，两种都会被无差别处理成"报错等人点重试"。

**所以顺序仍然是 ③ 的前置是 ①，① 的前置是能拿到分类信号——而这一点在 Erika 上有个硬限制，见下。**

### 8.2 触发条件的真实来源（这是本节最容易被想当然的地方）

想按"错误类别"决定换不换内核，先得知道内核报什么。查过 C API：**`ErikaStatus` 只有 6 个值**（`erika_capi/include/erika.h:176-181`）：

```
Ok=0  NullPointer=1  InvalidUtf8=2  PlayerError=3  Panic=4  NoEvent=5
```

也就是说**所有播放失败在状态码层面都是同一个 `PlayerError`**，分不出网络/格式/鉴权。可用的分类信号只有两条：

| 信号 | 位置 | 覆盖 |
|---|---|---|
| 错误文本前缀 | `crates/erika/src/core.rs:40-53` 的 `PlayerError` 变体：`source error: …` / `playback error: …` / `renderer error: …` / `renderer backpressure: …` | 粗分「源层 / 播放层 / 渲染层」 |
| 文本里的 HTTP 状态码 | `source.rs:3025` 的用例证明 404 这类码会出现在 `source error:` 文本里 | 鉴权(401/403) / 消失(404/410) |

于是分类只能这样落（`PlaybackKit` 新增，放 `PlaybackTypes.swift`）：

```swift
public enum PlaybackFailureCategory: String, Sendable, Hashable {
    case network        // source error 且无 HTTP 码：连接/DNS/超时/断流
    case auth           // source error 且文本含 401/403
    case resourceGone   // source error 且文本含 404/410
    case format         // playback error：解封装后的问题 —— ★换内核有效
    case renderer       // renderer error / backpressure —— ★换内核最有效
    case aborted        // 用户取消 / 让位
    case capacity       // 打开槽位已满（不是"源"的问题）
    case unknown
}

extension PlaybackFailureCategory {
    /// 换源能救的（同一个内核再试一条 URL）
    public var mayRetryWithAnotherSource: Bool {
        switch self {
        case .network, .resourceGone, .format, .unknown: true
        case .auth, .renderer, .aborted, .capacity: false
        }
    }
    /// 换内核能救的（同一个 URL 换个解码/渲染栈）
    public var mayRetryWithAnotherEngine: Bool {
        switch self {
        case .format, .renderer, .unknown: true
        case .network, .auth, .resourceGone, .aborted, .capacity: false
        }
    }
}
```

分类函数放在 `ErikaKit`（只有它知道自己的错误文本约定）：

```swift
// Packages/ErikaKit/Sources/ErikaKit/ErikaEngine.swift
// `ErikaError.message` 是 `String?`（`ErikaPresenter.swift:9`），空时一律 .unknown。
public static func category(for error: Error) -> PlaybackFailureCategory {
    guard let erika = error as? ErikaError,
          let text = erika.message?.lowercased()
    else { return .unknown }
    if text.hasPrefix("source error") {
        if text.contains("401") || text.contains("403") { return .auth }
        if text.contains("404") || text.contains("410") { return .resourceGone }
        return .network
    }
    if text.hasPrefix("playback error") { return .format }
    if text.hasPrefix("renderer error") || text.hasPrefix("renderer backpressure") { return .renderer }
    return .unknown
}
```

**关键取舍：把"分类"定义成"这个失败该往哪条路重试"，而不是"错误有多严重"。** `.format` / `.renderer` 才是换内核的信号——网络和鉴权换什么内核都一样死。

> ⚠️ 这里留一个不稳定点：前缀匹配依赖 liberika 的 `Display` 实现。升级内核时若改了措辞，分类会静默退化成 `.unknown`（`.unknown` 两条路都放行，所以是"退化成多试一次"而不是"退化成不兜底"）。**这是有意选的失败方向**。要更稳就得让 liberika 在 C API 里给出 category 码，那是另一件事。

### 8.3 改动清单（6 个文件，按依赖顺序）

#### 改动 1 · `PlaybackEngineRegistry`：从"一个选择"到"有序候选链"

现在只有 `selected`（返回第一个兜底）和 `makeSelected()`。加三样，**不改现有语义**：

```swift
// Packages/PlaybackKit/Sources/PlaybackKit/PlaybackEngineRegistry.swift

/// 兜底顺序：用户选的排第一，其余按注册顺序。不包含已试过的。
public static func candidates(excluding tried: Set<String> = []) -> [PlaybackEngineDescriptor] {
    let all = entries.map(\.descriptor).filter { !tried.contains($0.id) }
    guard let preferred = selected?.id, let idx = all.firstIndex(where: { $0.id == preferred })
    else { return all }
    return [all[idx]] + all[..<idx] + all[(idx + 1)...]
}

/// 按 id 造引擎（兜底要指定内核，不能用 makeSelected）。
public static func make(_ id: String) throws -> any PlaybackEngine { … }
public static func descriptor(_ id: String) -> PlaybackEngineDescriptor? { … }
```

#### 改动 2 · `PlaybackEngineDescriptor`：加两个能力位

兜底候选不能"全都能"，得让描述符自己说清能接什么源。**别在控制器里写 `if id == "avplayer"`**：

```swift
public struct PlaybackEngineSourceSupport: OptionSet, Sendable {
    public let rawValue: Int
    public static let http      = Self(rawValue: 1 << 0)
    public static let localFile = Self(rawValue: 1 << 1)
    public static let remoteSMB = Self(rawValue: 1 << 2)
    public static let all: Self  = [.http, .localFile, .remoteSMB]
}

// PlaybackEngineDescriptor 新增（都有默认值，Erika 一行都不用改）
public let sourceSupport: PlaybackEngineSourceSupport   // 默认 .all
public let isFallbackOnly: Bool                        // 默认 false；true = 不进设置页选择器
```

`isFallbackOnly` 是为 AVPlayer 准备的：它能当兜底，但不该让用户以为可以当主内核（PiP 有了，弹幕/字幕样式全没了）。**同时要在 `PlaybackKernelSection.swift:62` 的 `available` 里过滤掉 `isFallbackOnly`**，否则加了第二个内核，设置页会自动多出一个选择项（`available.count > 1` 就走选择器分支）。

#### 改动 3 · `PlaybackController`：一份"本次请求试过哪些内核"的账

```swift
// PlaybackController.swift
/// 本次请求已经试过、暂时跳过的内核。**按请求生命周期清空**（prepareForPresentation 里）。
private var triedKernelIDs: Set<String> = []
/// 本次请求已换过几次内核。上限 1：两个内核互推会变成死循环。
private var kernelSwitchCount = 0
private static let maximumKernelSwitchesPerRequest = 1
```

`prepareForPresentation(_:)`（`:516`）末尾加两行清账；`prepareEngine()`（`:458`）改成按候选链取：

```swift
func prepareEngine() -> (any PlaybackEngine)? {
    if let engine { return engine }
    // 弹幕路线必须按**实际要用的内核**解析，不能按 registry.selected
    let candidate = PlaybackEngineRegistry.candidates(excluding: triedKernelIDs).first
    usesOverlayDanmakuRenderer = Self.resolveOverlayDanmakuRoute(for: candidate)
    do {
        let engine = try candidate.map { try PlaybackEngineRegistry.make($0.id) }
            ?? PlaybackEngineRegistry.makeSelected()
        …
    }
}
```

**`resolveOverlayDanmakuRoute()` 必须加参数**（`:229-234`）。这是现有实现里的一个潜在错位：它读 `PlaybackEngineRegistry.selected`，而不是"实际创建的那台引擎"。单内核时两者恒等，**一加兜底内核就会分叉**——从 Erika 退到 AVPlayer 后，路线还停在"内核渲染弹幕"，而 AVPlayer 根本没有弹幕渲染器 → 弹幕静默消失。现有测试 `testDanmakuRouteIsForcedToOverlayWhenKernelCannotRenderIt` 守的是"按 registry 选择"这条路径，兜底路径要在它旁边补一条。

#### 改动 4 · `finishOpenFailure`：从终态改成决策点

这是唯一需要动 open 主流程的地方，而且**必须插在正确的位置**（现有顺序见 `:944-971`）：

```
open 失败回调 →
  clearOpeningState(attempt:)            ← 先摘看门狗，别让它和新 attempt 打架
  guard sourceGeneration == generation   ← 代次守卫不能动
  ┌─ ★决策点（新增，在 releaseScope / resetEngine / setupError 之前）
  │   if category.mayRetryWithAnotherEngine,
  │      kernelSwitchCount < 1,
  │      let next = 候选链里的下一个 {
  │       释放本次 scope
  │       triedKernelIDs.insert(当前内核 id)
  │       kernelSwitchCount += 1
  │       记一条 open.done(ok=false, fallback_to=next.id)   ← 埋点，别省
  │       open(request: request)                            ← 复用重开语义
  │       return                                             ← 不写 setupError
  │   }
  └─ 原有终态：releaseScope → 清 expectedRequestID → ++generation → resetEngine → setupError
```

**为什么复用 `open(request:)` 而不是自己再派一次 open**：它已经承担了"重开换新引擎身份"的全部语义——`isReopeningCurrentRequest` 为真时自增 `sourceGeneration`、取消旧 attempt、作废旧 token（`:622-636`）。自己写一份必然会漏其中一条，那正是"僵尸播放会话"那类偶发 bug 的来源（`:770-788` 的注释就是为这件事写的）。

**两个必须注意的时序细节：**

1. **不要在同一个主 actor tick 里重开。** `finishOpenFailure` 的调用点外面套着 `defer { Self.settleOpenSlot(attempt) }`（`:872`）。此刻槽位还没归还，直接 `open()` 会因为 `activeOpenAttempts < 2` 的闸门被算进下一次计数，两个请求并发失败时就会撞上"任务已满"。正确做法是 `Task { @MainActor in … }` 让出一拍，等槽位先销账。
2. **scope lease 要放掉再重拿。** `open(PlaybackSource…)` 会重新 `startAccessingSecurityScopedResource()`（`:810-817`），旧 lease 不还就是泄漏。所以决策点里先 `attempt?.scopeLease?.releaseOnce()`，`finishOpenFailure` 原有的 `releaseScope` 参数在兜底分支传 `false`。

#### 改动 5 · 弹幕/字幕/截图的降级要与路线同源

兜底到 AVPlayer 之后：`supportsKernelDanmaku = false` → overlay 路线自动成立（改动 3 保证）；`supportsSubtitleStyle = false` → 设置页提示"当前内核不支持"（已有 `PlaybackEngine.swift:161-168` 的默认实现兜住）；`captureFrameRGBA` 必须实现（截图按钮否则报错）。

`applyDanmakuPrefs`（`:1090`）在 AVPlayer 上是纯空操作（协议默认实现），**不用改**，但要确认它的 `throws` 在兜底内核上不会把 open 收尾打断——现有代码已经 `catch` 并降级成 warning（`:855-860`），安全。

#### 改动 6 · 用户可见的降级提示

兜底成功后必须说一句，否则用户只知道"弹幕没了/字幕样式变了"：

```swift
// PlaybackController
private(set) var degradedToEngine: PlaybackEngineDescriptor?
```

`PlayerScreen` 顶栏 pill：`已切换到 <displayName>（兼容模式）`，可点开看原因（`PlaybackFailureCategory` 的中文说明）。`seenStartSpecToken` 那种"只弹一次"的令牌模式可以直接借（Rex 的 `PlayerStartSpecHUDView` 就是这么做的）。

### 8.4 AVPlayer 适配器：协议落地清单

协议一共 24 个无默认实现的成员（`PlaybackEngine.swift:29-192`），按"必写/可用默认"分：

| 必写（无默认） | 说明 |
|---|---|
| `static descriptor` | `id: "avplayer"`、`isFallbackOnly: true`、`supportsKernelDanmaku: false` |
| `events` | `AsyncStream<PlayerEvent>`，用 KVO（`AVPlayerItem.status` / `AVPlayer.timeControlStatus`）转事件 |
| `latestMediaTime` / `latestStats` / `latestOutputEncoding` / `latestOutputSnapshot` | 见下面坑 ②③ |
| `hasRenderedFirstFrame` | **坑 ②** |
| `debugStatsLine` / `kernelDiagnosticsFields()` | 可给空/零 |
| `makeSurfaceView` | `AVPlayerLayer` 的 `NSViewRepresentable`/`UIViewRepresentable`，双端 |
| `open` / `play` / `pause` / `stop` / `seek` / `setRate` / `setVolume` | 直接映射 |
| `tracks` / `selectAudioTrack` / `selectSubtitleTrack` | `AVMediaSelectionGroup` |
| `addExternalSubtitle` / `removeSubtitleTrack` / `setSubtitleScale` / `captureFrameRGBA` | 见坑 ④⑤ |

**可全用默认（一行不写）**：`supportsKernelDanmaku` 及 7 个弹幕方法、`supportsSubtitleStyle` + `setSubtitleStyle`、`setLumaUpscaler`/`lumaUpscalerState`、`openWasInterrupted`、`setBackgroundAudioOnly`（**但 `supportsBackgroundAudio` 建议报 true**，AVPlayer 天然支持）。

`NoDanmakuEngine`（`AppTests/PlaybackEngineSelectionTests.swift:114`）已经证明了"新适配器的成本"——45 行就能满足协议，兜底内核同理。

**五个已知坑（按踩到的概率排序）：**

1. **自定义请求头**。Jellyfin 流要 `Authorization`，而 `AVURLAsset` 只能靠 `AVURLAssetHTTPHeaderFieldsKey`（非公开键）。**更稳的路是改走 `?api_key=` 查询参数**——Jellyfin 的 `/Videos/{id}/stream` 支持它。这需要在 `PlaybackSource` 之外给候选源单独带一个"AVPlayer 专用 URL 形态"，也就是 L1 的候选结构里要允许同一逻辑源有多个 URL 变体。
2. **`hasRenderedFirstFrame` 不会自己变真**。协议默认实现是 `latestStats.renderedVideoFrames >= 1`（`PlaybackEngine.swift:250-252`），而 AVPlayer 不报解码计数。必须在渲染路径上自己数（`AVPlayerItemVideoOutput.hasNewPixelBuffer(forItemTime:)` 轮询或 `AVPlayerLayer` 的 `isReadyForDisplay` KVO），否则 **loading 覆盖层永远不撤**——这个坑协议注释里已经写死过一次（`PlaybackEngine.swift:86-91`）。
3. **`latestMediaTime` 的读频**。弹幕 overlay 以 30Hz 读它，`AVPlayer.currentTime()` 虽线程安全但会拿播放器锁；要在专用队列上缓存成原子值，别在渲染线程直读。
4. **外挂字幕**。AVPlayer 挂 `.srt`/`.ass` 需要 `AVMutableComposition`，成本远超兜底内核该承担的范围。**兜底内核就明确不支持外挂字幕**（`addExternalSubtitle` 抛错、`TrackInfo.canRemove=false`），内封字幕走 `AVMediaSelectionGroup` 即可。
5. **HDR / DV**。这恰恰是加它的理由（Erika 的 Metal 管线走不到原生 DV 直通），但 `AVPlayerItem` 的 HDR 输出需要 `AVPlayerItem.videoComposition` 为空 + 正确 `preferredPeakBitRate`/`preferredMaximumResolution`，且模拟器上表现与真机不同——验收必须真机。

### 8.5 不做什么

| 不做 | 理由 |
|---|---|
| 让用户手动选兜底内核 | 这就是 Rex 的四档选择器的代价：每个档位的能力差要写进用户文档（"实验内核不支持 AI 字幕"）。我们让分类自动触发，用户不需要知道有两个内核。 |
| 内核之间**来回**回退 | `maximumKernelSwitchesPerRequest = 1`。两个内核互推会变成无限循环，而且第二次换回必然还是同一个错。 |
| 记住"这个条目要用 AVPlayer"跨会话 | 先不做。要做的话抄 Rex 的 `RexPlaybackResourcePreferenceProvider.recordsConfirmedPlayback` 形状（按 host + codec + item 记录），别自己发明 key。 |
| 在兜底内核上补齐弹幕/字幕样式/截图全功能 | 兜底的定位是"能出画出声"，不是"第二个完整体验"。功能对齐是无底洞。 |
| 用兜底掩盖真正的源问题 | `.network` / `.auth` 不换内核。鉴权失败换内核只会把一次可诊断的 401 变成一句"兼容模式也不行"。 |

### 8.6 验收（在写 AVPlayer 之前就能跑）

先不碰 AVFoundation，用测试替身把逻辑钉死——现有 `GatedFakeEngine`（`AppTests/PlaybackControllerOpenTests.swift:15`）就是模板：

1. **主内核报 `.format` → 自动换到兜底内核并 open 成功**：注册两个替身（第一个 `failOpen(ErikaError(source:))`），断言 `openCalls.count == 1`（第二个引擎）、`setupError == nil`、`degradedToEngine?.id == 兜底`。
2. **`.auth` 不换内核**：断言第二个引擎 `openCalls.isEmpty`、`setupError != nil`。
3. **换内核上限 1**：两个替身都失败 → 断言只切一次，最终落 `setupError`，且 `kernelSwitchCount == 1`。
4. **看门狗超时也走兜底**：`openWatchdogTimeout` 注入 50ms，断言分类是 `.network`、**不**换内核。
5. **弹幕路线跟随实际内核**：主内核 `supportsKernelDanmaku=true`、兜底 `false`，兜底成功后断言 `danmakuPayloadFormat == .overlay`。
6. **槽位不被兜底撑爆**：连续两次兜底，断言 `activeOpenAttemptsForTesting <= 2`、`abandonedOpenAttemptsForTesting == 0`。
7. **代次**：兜底期间旧引擎的迟到事件不得改状态（沿用现有 open 测试的让位用例形状）。

### 8.7 结论：先做哪一步

```
第 1 步  8.2 分类          PlaybackKit + ErikaKit，~2h，不碰 open 主流程
第 2 步  8.3 改动 1/2/3    注册表候选链 + 描述符能力位 + prepareEngine，~3h
第 3 步  8.3 改动 4        finishOpenFailure 决策点，~3h ← 最容易写错的一处
第 4 步  8.6 七个用例，~3h  ← 到这一步为止，多内核兜底已经能用测试替身完整证明
第 5 步  AVPlayer 适配器，~3–5 天（含真机 HDR/PiP 验收）
```

**前四步加起来一天多，且不依赖 AVFoundation。** 做完之后，"加一个兜底内核"就只剩第 5 步那一件事；反过来先写 AVPlayer，则会得到一个没有触发条件、也没有回退落点的孤儿适配器。

---

## 9. 专章：多内核兜底能不能让 PiP 支持起来

### 9.1 直接回答：不能

三条独立的原因，任何一条都会挡住：

**① PiP 不是兜底能带来的东西，是常态功能。**
§8 的兜底只在 `open` 失败且分类为 `.format` / `.renderer` 时触发一次。绝大多数播放 Erika 都能开，所以绝大多数时候**根本不会切到 AVPlayer**——用户按 PiP 按钮时还在 Erika 上，照样没反应。用"失败兜底"去满足"每次播放都要有"的功能，是拿错工具。

**② 就算强制切过去，PiP 需要的控制面在代码里完全不存在。**
全仓 grep：`AVPictureInPictureController` / `AVPictureInPicture` **0 处**；`PlaybackEngine` 协议里**没有任何 PiP 成员**（`PlaybackEngine.swift:29-192`，24 个必写成员逐个看过，没有 PiP）。所以不是"换个内核就有"，而是"换内核 + 新造一层功能 + 两个平台各写一遍 UI"。

**③ Erika 的输出在物理上接不进 PiP。**
`AVPictureInPictureController` 的内容源只接受两种：`AVPlayerLayer` 或 `AVSampleBufferDisplayLayer`（`ContentSource(playerLayer:)` / `ContentSource(sampleBufferDisplayLayer:)`）。Erika 在 Apple 上只有一条路——宿主给一个 `CAMetalLayer` 指针：

```
// erika_capi/include/erika.h:820-829
/* Surface and presentation. attach_metal_layer for macOS/iOS (CAMetalLayer*), …
 * The renderer backend (native Metal, native D3D11, or wgpu) is chosen by
 * presenter config, not the attach call. */
ErikaStatus erika_presenter_attach_metal_layer(handle, uint64_t raw_layer, w, h, scale);
```

`CAMetalLayer` **不是** PiP 可接受的 content source。而 C API 里没有任何 `CVPixelBuffer` / `IOSurface` 的出口（grep `pixel_buffer` / `CVPixelBuffer` / `IOSurface` / `AVSampleBuffer`：0 命中）。唯一的出帧接口是离屏同步截图 `erika_presenter_capture_frame_rgba`（`erika.h:995-1004`），拿它逐帧喂 PiP 等于每秒 memcpy 几百 MB，不可行。

**顺带说清一件事：后台继续出声，我们现在就有。** `UIBackgroundModes: audio` 已声明（`Config/Info.plist`），`ErikaAudioSession` 设 `.playback` / `.moviePlayback`（`ErikaAudioSession.swift:30`），Erika 还有 `audio_only_tick` 后台档。缺的**只是那个视频小窗**。

### 9.2 真要做 PiP，只有三条路

| 路 | 做法 | 代价 | 能得到什么 | 会失去什么 |
|---|---|---|---|---|
| **A. 显式"系统播放器"模式**（推荐） | 新增「用系统播放器打开」入口 → AVPlayer 适配器 + `AVPlayerLayer` → `AVPictureInPictureController` | 适配器 3–5 天 + PiP 面 1–2 天 | **iOS/macOS 双端真 PiP**、系统控件、跨 App | 弹幕（AVPlayer 无渲染器）、字幕样式、ASS 特效、部分容器需服务端转码 |
| **B. Erika 出帧 → `AVSampleBufferDisplayLayer`** | 让 liberika 把解码帧以 `IOSurface` 零拷贝交出来，宿主包成 `CMSampleBuffer` 喂 `AVSampleBufferDisplayLayer` 并接 PiP | **上游改造**，且 GUI 与 PiP 两套渲染路径要同步（danmaku/字幕得在两侧都成立） | 真 PiP **且**保住弹幕/字幕/Erika 全格式 | 工程量最大，且 Erika 的 Metal 合成器要拆成"出帧"与"上屏"两段。**⚠️ 修正：这就是 Rex 实际走的路**（见 §10），所以不是纸上方案，但仍卡在 Erika 无 CVPixelBuffer 出口 |
| **C. 平台差异化伪 PiP** | macOS：`NSWindow` 无边框置顶悬浮窗（真·浮窗，1 天）；iOS：**做不到**（系统不允许 App 窗口覆盖其他 App），只能做 App 内小窗 | 1 天（仅 macOS） | macOS 上体验接近 PiP | iOS 上等于没做 |

**关键判断**：iOS 上除了 A 和 B **没有第三条路**——这不是工程量问题，是系统限制。所以如果 PiP 是硬需求，答案一定是 A 或 B。

### 9.3 先说 A 的四个前提（都是现在没有的）

1. **协议要加 PiP 面**（`PlaybackKit`，任何内核都接不上是因为这里根本没有入口）：

```swift
// PlaybackEngine.swift
static var supportsPictureInPicture: Bool { get }        // 默认 false
func startPictureInPicture() throws                      // 默认空操作
func stopPictureInPicture() throws                       // 默认空操作
// PlayerEvent 加一个 case
case pictureInPictureChanged(isActive: Bool)             // 默认内核永不发
```

2. **适配器侧**：`AVPictureInPictureController(contentSource: .init(playerLayer: layer))` + delegate 两个回调（`didStart` / `restoreUserInterfaceForPictureInPictureStopWithCompletionHandler` → 回 App 后要把 layer 重新挂回视图）。`canStartPictureInPictureAutomaticallyFromInline = true` 才能做到"上滑回桌面自动进 PiP"。
3. **鉴权形态要改**：AVPlayer 设自定义请求头只能靠非公开键 `AVURLAssetHTTPHeaderFieldsKey`。**正路是给 AVPlayer 候选源用 `?api_key=` 查询参数**（Jellyfin `/Videos/{id}/stream` 支持）。这反过来要求 §8 的候选结构里，同一个逻辑源要能带**多个 URL 变体**（给不同内核用），而不是一个 `uri`。
4. **内容边界要提前说清**：AVPlayer 播不了 MKV 里的 HEVC + ASS 字幕这类组合。这时候要让 Jellyfin 服务端转码成 HLS-fMP4（`supportsTranscoding` 已在 `PlaybackInfo` 里），否则用户点了"系统播放器"直接黑屏——比没有 PiP 更糟。

### 9.4 §8 那套骨架能复用多少：约 80%，缺两块

| 已可复用 | 说明 |
|---|---|
| 注册表候选链（§8.3 改动 1） | 显式切换和自动兜底都走 `PlaybackEngineRegistry.make(_:)` |
| 描述符能力位（改动 2） | `isFallbackOnly` 此时应设为 **false**——PiP 模式要能被用户显式选到 |
| 重开语义（改动 4 的 `open(request:)` 复用） | 同一套"换引擎身份 + 作废旧 token" |
| `degradedToEngine` 提示位（改动 6） | 显式切换复用它显示当前在哪个内核 |

| 必须新补 | 为什么 |
|---|---|
| **PiP 协议面 + 控制面**（§9.3 第 1、2 条） | 兜底场景完全不需要 PiP，所以 §8 一个字都没写 |
| **带位置续播的切换** | 兜底时位置通常在起点，`open` 完直接播就行；**显式切换是"播到 20 分钟后切"**，必须在 open 成功后 `seek` 到原位置，否则用户点一下 PiP 就回到片头 |

### 9.5 结论与建议顺序

```
如果把 PiP 当"顺手能有"     → 别做。A 路要 4–7 天，且会牺牲弹幕/字幕样式。
如果 PiP 是硬需求           → 走 A：先 AVPlayer 适配器，再 PiP 面；入口是「用系统播放器打开」，
                               不是故障兜底。§8 的兜底可以顺带复用同一套切换机制（省约 1 天）。
如果只关心 macOS            → 先花 1 天做 C 路的悬浮窗，成本最低；iOS 另议。
如果既要 PiP 又要弹幕       → 只有 B 路，且必须先推动 liberika 暴露 IOSurface 出帧接口，
                               这是上游变更，不是 App 侧能绕过的。
```

**一句话**：多内核兜底解决的是"这条源打不开"，PiP 解决的是"我要一边看一边干别的"。**两个问题不重叠**——兜底做完，PiP 的进度仍然是 0。

---

## 10. Rex 的 PiP 到底怎么实现的（含对 §9 的修正）

> §9 说"B 路（sample buffer）要上游改造、工程量最大"。查完类表后要修正一句：**B 路就是 Rex 走的路**，它不是一条理论路径，而是 KSPlayer 已经实现好的第三条播放门面。

### 10.1 答案：Rex 自己不实现 PiP，KSPlayer 用两套 content source 实现

`AVPictureInPictureController` 只接受两种内容源，KSPlayer 两条都做了：

| 内容源 | 谁提供 | 类证据 |
|---|---|---|
| `.init(playerLayer:)` | AVPlayer 模式（系统内核 / ProAVPlayer） | `KSComplexPlayerLayer : KSPlayerLayer` 且一致性表写明 **`AVPictureInPictureControllerDelegate`**，9 个方法（`classes.csv:137`，`0x10297D03C`） |
| `.init(sampleBufferDisplayLayer:)` | FFmpeg 模式（ME）与 SampleBuffer 模式 | `KSMEPlayer : NSObject` 与 `KSSampleBufferPlayer : NSObject`，两者一致性表都写明 **`AVPictureInPictureSampleBufferPlaybackDelegate`**（`classes.csv:138` `0x102A42590`、`:143` `0x102A7FF98`） |

PiP 控制器本身是 **`KSPictureInPictureController : AVPictureInPictureController`**，只有一个方法 `initWithContentSource:`（`classes.csv:140`，`0x10296EA5C`）——即"包一层，把 contentSource 的选择权交给上层"。

**Rex 自己只写了 4 个方法**：`RexKSComplexPlayerLayer : KSComplexPlayerLayer`（私有类，`classes.csv:1435`，`0x1028DC910`）只重写 `pictureInPictureControllerDidStartPictureInPicture:` / `DidStopPictureInPicture:` / `dealloc` / `.cxx_destruct`，字段 `onPictureInPicturePhaseChanged`（`fieldnames.txt:351`）。也就是**只把 PiP 生命周期事件转成会话相位**，剩下的全在 KSPlayer。

> 结论：Rex 的 PiP 能力是"继承来的"，不是"设计出来的"。这解释了为什么它能在四内核架构里都有 PiP——因为三套门面（`KSAVPlayer` / `KSMEPlayer` / `KSSampleBufferPlayer`，`14_leftovers_thirdparty.md:821`）各自都能给 PiP 一个合法内容源。

### 10.2 FFmpeg 内核那条（`KSMEPlayer`）——这才是关键

`KSMEPlayer` 是 FFmpeg + Metal 播放器，它要接 PiP，必须走 sample buffer 路。证据链：

```
KSMEPlayer 实现 AVPictureInPictureSampleBufferPlaybackDelegate 的 6 个回调：
  pictureInPictureController:setPlaying:
  pictureInPictureControllerTimeRangeForPlayback:
  pictureInPictureControllerIsPlaybackPaused:
  pictureInPictureController:didTransitionToRenderSize:
  pictureInPictureController:skipByInterval:completionHandler:
  pictureInPictureControllerShouldProhibitBackgroundAudioPlayback:
```
（`classes.csv:138`）

这 6 个正是 **PiP 窗口里的播放/暂停/快进/拖进度条**由谁来响应——系统把用户在 PiP 小窗的操作回调给播放器。同时：

- 显示层：`SampleBufferPlayView : UIView`（`classes.csv:185`，`0x102A46DAC`）+ `AVSampleBufferDisplayView : UIView`（KSPlayerP 私有，`classes.csv:213`，`0x102AD08D0`）
- 配置开关：`KSOptions.isSampleBufferPassthrough` / `isSampleBufferVideoPassthroughDisabled` / `isSampleBufferAudioPassthroughDisabled` / `forceDisableDisplayLayer`（`fieldnames.txt:3211`）
- 会话配置：`KSPlayerPlaybackConfiguration.prefersSampleBufferPlayback`（09 §2.3，27 字段之一）
- 独立门面：`KSSampleBufferPlayer`（专用 sample buffer 播放器，13 个方法，`0x102A7FF98`）
- 恢复探针：`[BGRECOVERY]` / `scheduleForegroundRecoveryProbe` / `[KSSB_AUDIO_RELOAD]`（09 §5.1，`0x102a5eb38` 一带）

**所以 FFmpeg → CVPixelBuffer → CMSampleBuffer → AVSampleBufferDisplayLayer → PiP 是一条被产品验证过的路**，不是纸上方案。

### 10.3 能力门控：四层，缺一层就报不同的话

| 层 | 载体 | 证据 |
|---|---|---|
| 用户设置 | `PlaybackPictureInPictureConfiguration{isEnabled, allowsAutomaticStart}` | `fieldnames.txt:5725` |
| 引擎上报可用性 | `PlaybackPictureInPictureAvailability{unavailable, available}` + 事件 `pictureInPictureAvailabilityChanged` | `fieldnames.txt:5837`、`:5822` |
| 系统就绪 | `objc:isPictureInPictureSupported`、`setCanStartPictureInPictureAutomaticallyFromInline:`、`setDelegate:`；`KSOptions.canStartPictureInPictureAutomaticallyFromInline` | `04_player.md:341`、`fieldnames.txt:3211` |
| 每次尝试 | 命令 `startPictureInPicture` → 5 相状态机 | 见 §10.4 |

**四种失败各有一句用户文案**（`out/strings/zh_AppPlayback.json`）：

| 键 | 文案 | 对应哪层 |
|---|---|---|
| `…the.current.engine.could.not.create.a.picture.in.picture` | 当前内核未能创建画中画控制器。 | 控制器创建失败（内核层） |
| `…picture.in.picture.is.unavailable.for.the.current.player` | 当前播放器不支持画中画。 | availability = unavailable |
| `…picture.in.picture.is.not.ready.try.again.after.video` | 系统尚未准备好画中画，请在画面开始播放后重试。 | 系统未就绪（首帧前） |
| `…picture.in.picture.did.not.finish.starting` | 画中画启动未完成。 | `.starting` 超时 → `.failed` |

这是"四层门控 → 四句精确文案"的典范：用户永远不会只看到一句"失败了"。

### 10.4 状态机：5 相 + 回前台对账

- 相位：`PlaybackPictureInPicturePhase{failed, inactive, starting, active, stopping}`（`fieldnames.txt:5838`）
- 快照：`PlaybackPictureInPictureState{availability, phase}`（`:5726`），随大快照 `PlaybackViewState.pictureInPicture` 一起批量推给 UI（`:5807`）
- 引擎字段：`pictureInPictureIsEnabled`、`allowsAutomaticPictureInPictureStart`、`pictureInPictureTransitionTask`（正在进行的相位迁移，防止连点）、`lastEmittedPictureInPicturePhase`（去重复发）、**`foregroundReconciliationTask`**（回前台对账——PiP 里可能在别处被停掉，回前台必须核对真实状态而不是信缓存）（`09_playback_core.md:534`、`fieldnames.txt:5890`）
- 协议：`PlaybackPictureInPictureControlling` **6 个见证槽**（`0x1028b45e8` / `0x1028d6088` / `0x1028cb3f0` / `0x1028d4470` / `0x1028b0c24`，`09_playback_core.md:508`）
- 命令面：`PlaybackCommand` 第 54/55 条 `startPictureInPicture` / `stopPictureInPicture`（`09 §1.2`）
- **走外部执行生命周期**：PiP 与 AirPlay / 外接屏同属 `PlaybackExternalExecutionLifecycle`（`04_player.md:81`）——因为它会把画面搬到 App 之外，需要和执行仲裁对齐。

### 10.5 后台与 UI 的细节（这几条最容易被漏）

| 细节 | 证据 | 为什么重要 |
|---|---|---|
| `enterBackgroundTask` + `pictureInPictureWasActiveInBackground` + `isPictureInPictureStarting` | `fieldnames.txt:3209` | 切后台瞬间要 `beginBackgroundTask` 争取时间让 PiP 起来，否则进程被挂起、PiP 窗口空转 |
| `isPictureInPictureStoped`（原拼写如此） | 同上 | 显式记"用户主动停过"，避免前台对账时又自动拉起来 |
| `PipPlayerView{playerLayer,_alignment,block,_focusableView,_isMuted}` | `fieldnames.txt:3329` | **restore 用的接管视图**：点 PiP 的"回到 App"时，系统要求立刻给出可接管的 layer（`restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:`），这个 struct 就是干这个 |
| `DanmakuContainerView.isPictureInPicturePresentation` | `fieldnames.txt:3116` | **弹幕知道自己在 PiP 里**——PiP 小窗太小、车道不够，要换渲染策略或直接不画 |
| `RexPlaybackContinuationActivity{…, isPictureInPictureActive}` | `fieldnames.txt:3664` | 灵动岛 / Live Activity 显示"正在画中画播放" |
| `PlayerButtonType.pictureInPicture` + `showsPictureInPictureButton` | `fieldnames.txt:3388`、`5930` | PiP 是**可自定义按钮布局**的一员（primary / more / hidden 三分） |
| `onPictureInPictureActiveChanged` + `reportedPictureInPictureActive` | `fieldnames.txt:5964` | 与 `reportedPlaybackPlaying` 同一套"上报去重"模式：只在变化时通知宿主 |
| 设置 `background.pip=自动开启画中画` | `07_settings.md:539`、`:759` | 文案"系统设置中开启自动画中画后…"说明它依赖系统开关，不是纯 App 侧 |

### 10.6 对我们意味着什么：B 路从"理论"变成"已验证"，但仍卡在 Erika 的出口

| | Rex / KSPlayer | 我们 |
|---|---|---|
| sample buffer 播放门面 | 有（`KSSampleBufferPlayer`，13 方法） | **没有** |
| FFmpeg 解码帧 → CVPixelBuffer | 有（`KSMEPlayer` 内部） | Erika 只有 `attach_metal_layer`，C API **零** `CVPixelBuffer`/`IOSurface`/`CVImageBuffer` 符号（`erika.h` 全文 grep 确认） |
| PiP 控制器封装 | `KSPictureInPictureController` 现成 | 得自己写 |
| 四层门控 + 5 相状态机 | 现成 | 得自己写 |
| PiP 内交互（播放/快进/拖进度） | 6 个 delegate 回调现成 | 得自己写（但只有在 sample buffer 路上才需要） |

**关键差异不是"我们写得慢"，是"Rex 拥有源码"。** KSPlayer 是深度 fork（DV P7 双流、本地 ASR、ISO AVIO、背压恢复全是他们自己加的，`14 §…`），PiP 只是其中一个副产品。我们的 Erika 是 vendored 二进制，要加 sample buffer 出口 = 改 `~/Documents/project/liberika` 并重新出 xcframework。

所以 §9 的三条路要按新证据重排优先级：

```
若接受"PiP 时没有弹幕/字幕样式" → A 路（AVPlayer 适配器 + playerLayer content source）
                                    1 周内可交付，PiP 全额功能（系统控件/跨 App/后台）
若坚持"PiP 时保留弹幕"          → B 路，且目标明确为：
                                    ① liberika 加一帧式出口（CVPixelBuffer / IOSurface）
                                    ② 我们写 SampleBufferPlayer 等价物 + 6 个 PiP 回调
                                    ③ 弹幕在 PiP 画布上重排（DanmakuContainerView 的等价物）
                                    这是 3–4 周，且要维护 liberika 分支
```

**一句话**：Rex 的 PiP 不是"多内核架构带来的"，是"KSPlayer 自带 sample buffer 播放门面 + 四层能力门控 + 5 相状态机"带来的；多内核只提供了"至少有一个内核能给 PiP 合法内容源"这一条。我们要复制它，缺的是**内容源**，不是**内核数量**。
