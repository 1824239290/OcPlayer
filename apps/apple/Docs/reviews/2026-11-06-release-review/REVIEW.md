> 历史记录保留：本文记录初始审查或 `5345e0c` 上的修复轮次。本次 App PR 已按 `66de8eb`（#96）重新整合，最终代码范围和验收以 [INTEGRATION_REPORT.md](INTEGRATION_REPORT.md) 为准；内核升级独立提交。

# OcPlayer 发版前审查（2026-11-06）

审查基线：`5345e0c`，`MARKETING_VERSION = 0.2.2`。开始审查时工作区干净。此次只审查与验证，没有修复生产代码。

结论：发现 **4 个 P1、2 个 P2**。建议先处理 P1 再发版。已有测试通过并不能证明这些时序安全：本次补充的 5 个离线复现用例均观察到了错误行为。

## 1. [P1] MoviePilot 重试把旧 token 发往新服务器

位置：`Packages/MoviePilotKit/Sources/MoviePilotKit/MoviePilotAPIClient.swift:408–417`，相关 `makeURLRequest:482–485`。

触发：A 服务器的请求收到 503 或超时，处于退避等待时，用户通过设置切换 MoviePilot 到 B 服务器。`send` 保留 A 的 `currentToken`，但每次 `sendOnce` 都从可变 store 重新读取 baseURL；普通请求没有凭证代次校验。即使中间执行 `signOut()` 推进了代次也不能阻止重试。

结果：第二次请求使用 **B 的地址 + A 的 Bearer token**。这是实际凭据跨服务器发送，不只是旧界面数据。相同结构也影响登录请求的重试：地址发生变化时，已捕获的旧用户名和密码可能随重试送到新地址。

验证：`testReproducesOldTokenSentToNewHostAfterSwitch` 使用 URLProtocol，第一请求返回 503，登出并改绑新地址、设置新 token，仍观察到新地址收到旧 token。仅使用合成凭据和 `.invalid` 域名，没有真实网络请求。

修复方向：为整个请求绑定不可变的 origin、凭证代次和 token；每次等待后、重试前、401 重放前校验会话，变化即取消。不要只修 URL 拼接而保留跨会话重放。

## 2. [P1] 建库等待后的旧仓储可覆盖新服务器仓储

位置：`App/Shared/Features/Settings/MetadataCoordinator.swift:89–95`。

触发：冷启动或首次建库期间，A 的 `currentRepository()` 在 `waitUntilReady()` 挂起；用户切到 B，`setActiveServer` 清空 repository。A 的等待结束后仍用 await 之前捕获的 server 建库，并写回共享 repository。方法没有重新核对服务器身份、取消状态，也没有复查期间是否已创建仓储。

结果：之后 B 的请求可拿到 A 的仓储，读取或操作 A 的媒体。上层 `sessionGeneration` 的响应守卫不能修复这一点：B 的新请求本身已经取得错误仓储。多个冷启动调用者同时等待还会创建多个仓储，破坏同键单飞。

验证：`testReproducesOldRepositoryInstalledAfterSwitchDuringSetup` 在实际 MetadataCoordinator 建库等待期间切 A→B；建库完成后通过当前仓储刷新首页，返回的是 **A-library**。

修复方向：等待前记录会话身份，等待后验证仍是同一实例；复查已创建的 repository，保证创建唯一性。过期调用应返回 nil 或取消，不能把旧仓储重新安装。

## 3. [P1] 切服务器时旧播放进度写入新租户

位置：`App/Shared/AppModel+Playback.swift:990–996`，相关 `MetadataCoordinator.recordPlaybackProgress:195–202`。

触发：`stopPlaybackForSessionChange()` 调用 `finishReporting()`，后者创建一个尚未执行的 Task，只捕获协调器、itemID、播放位置。切服务器流程随后同步更换 `app.server`；等 Task 执行时，协调器通过 `currentRepository()` 选择的是新服务器。

结果：A 的进度落到 B 的缓存；两台服务器存在相同条目 ID 时，B 的观看状态被错误覆盖。没有相同 ID 时，A 的最后进度也会丢失。此问题位于本地缓存写回，服务端 Stopped 上报使用原 reporter，不应把它描述成服务端也被串写。

验证：`testReproducesProgressWrittenToNewTenant` 给 A、B 预置相同 ID 的不同媒体，A 播到 60 秒后调用 finishReporting 并立即切 B；SQLite 中 B 的条目变成 60 秒，而 A 没得到进度。

修复方向：把写回绑定原仓储或明确的 TenantID。需要同时协调旧仓储的 shutdown 时机，让合法的最终快照完成；只加代次守卫并丢弃旧写入会继续丢失 A 的最后进度。

## 4. [P1] MoviePilot 迟到的手动登录响应可撤销登出或覆盖新凭据

位置：`Packages/MoviePilotKit/Sources/MoviePilotKit/MoviePilotAPIClient.swift:228–242`；协调器的失败回滚位于 `App/Shared/Features/MoviePilot/MoviePilotCoordinator.swift:87–94`。

触发：手动 login 在 token 或用户信息请求上挂起，此时登出，或在另一窗口/后续登录流程改绑凭据。虽然入口推进 authGeneration，但 login 没有保存和核对该代次，两个 await 结束后的写 token、清 token 都无条件执行；协调器的失败回滚也没有对应的尝试身份校验。

结果：旧登录成功可以把旧 token 重新保存，使已登出的会话复活；旧登录失败或回滚也可能清除/覆盖较新的会话。actor 的串行执行只覆盖两次 await 之间，不能防止这些交错。

验证：`testReproducesLoginRestoringTokenAfterSignOut` 将登录响应卡在信号量上，先执行 signOut 并确认 token 已清空，再放行；login 仍成功并保存旧 token。

修复方向：手动登录和协调器回滚都要绑定各自的尝试代次、origin 与凭证快照，只有当前尝试能提交或回滚。

## 5. [P2] 多媒体源的外挂字幕固定取第一份，和视频源不一致

位置：`Packages/JellyfinKit/Sources/JellyfinKit/ExternalSubtitles.swift:61–63`；Emby 同类问题在 `EmbyServer.swift:571–575`。App 调用位于 `AppModel+Playback.swift:1142` 附近。

触发：第一份 MediaSource 不可直放，PlaybackInfo 选择后面的源，或首源打开失败自动切到备用源。外挂字幕接口只有 itemID，Jellyfin 固定取 `mediaSources.first`，Emby 也使用 `firstMediaSource`，没有接收本次 request 的 mediaSourceID。

结果：新源可能挂上旧版本字幕、时间轴不一致，或新源有字幕但界面显示没有字幕。字幕的 URL 虽带 mediaSourceID，却是第一份的 ID，并非正在播放的那份。下载文件名还只含 itemID/index，没有源身份。

验证：静态核对 PlaybackInfo 选源、L1 自动换源、字幕列举与下载路径；本次没有用真实多版本服务器做端到端验证。

修复方向：把当前 sessionContext.mediaSourceID 传入字幕列举，严格选对应源；字幕身份与缓存路径包含租户和媒体源。

## 6. [P2] 后台恢复的前 30 秒续播位置仍被打开流程忽略

位置：`App/Shared/Features/Player/PlaybackController.swift:695–705`；调用在 `AppModel+Playback.swift:806–835` 的后台故障恢复。

触发：视频播放到 1–29 秒，后台往返使内核进入错误态，需要自动重建。恢复代码按精确位置创建 request，但 `openPreparedRequest` 只有 resume ≥ 30 才创建 seek 任务。

结果：恢复从 0 秒重新播放，和后台恢复「保留精确位置」的实现意图不一致；调用方明确传入的短续播点也会被丢弃。

验证：`testReproducesIgnoredResumeUnderThirtySeconds` 使用替身引擎对比 request：20 秒时没有 resumeTask，40 秒时有。不是只验证上层的决策枚举。

修复方向：把是否采用短续播点的产品判断留在请求构造入口；内核打开流程执行所有合法的显式续播位置，或添加明确的精确恢复策略。

## 验证记录

完整原始日志保留在 `/tmp/ocplayer-review-*.log`，并完整归档为本目录的 `verification-logs.zip`（包含构建/包测试/AppTests/定向复现的完整输出）；此处的复现源码以 `.swift.txt` 保存，避免被自动纳入发布目标。它们断言的是本次观察到的错误行为，**通过表示复现成功，不能当成修复后的回归测试**。修复时应反转对应断言。

- macOS 原有 AppTests：902 项，883 passed / 19 skipped / 0 failed（来源：xcresulttool test-results summary，完整 JSON 见 macos-tests-summary.json）。
- 11 个 SwiftPM 包：通过。ErikaKit 按 CI 清单跳过依赖 presenter/GPU 的套件；没有执行真实远程片源测试。
- MoviePilot 定向复现：2/2 观察到错误行为。
- App 定向复现：3/3 观察到错误行为。
- iOS 真机目标 Release（arm64、未签名）：构建通过；产物版本 0.2.2，部署目标 iOS 26，audio 后台能力、局域网说明与 dSYM 均存在。
- iOS 模拟器 AppTests：910 项，907 passed / 3 skipped / 0 failed（含 3 项 App 定向复现，来源：xcresulttool test-results summary，完整 JSON 见 ios-tests-summary.json）。
- macOS Release（arm64、未签名）：构建通过；产物版本 0.2.2，dSYM 存在；两端 executable 与各自 dSYM 的 UUID 均一致（dwarfdump --uuid）。

## 既有内核风险

`Docs/DEVELOPMENT.md:71` 已记录 liberika v0.3.0 在高密度 CJK 字幕下，glyph atlas 超过 Metal 纹理限制可导致进程 abort。当前仍钉 v0.3.0；本次未重跑该场景，因此不把它计为新发现。发版前仍应确认上游修复或用问题片源验证；Swift 层的普通错误徽章不能接住进程 abort。

本次没有打包 DMG/IPA、签名重签或发布，也没有修改播放内核。真实 Jellyfin/Emby/MoviePilot、真机后台恢复、HDR/杜比和高密度字幕的端到端行为仍需要设备/片源验收。

构建工具：Xcode 27.1 (27A9275)。原有 macOS AppTests 与 iOS AppTests 的用例数口径不同：iOS 那轮包含新加入的 3 项复现，且存在平台条件跳过；未将两端计数相加冒充唯一用例数。临时测试源已经移出正式测试目录，仅保留在本报告目录。

## 2026-11-06 修复状态补记

本轮 4 个 P1、2 个 P2 的 App 修复与回归已完成。最终双端 AppTests、11 包与双端 Release 验证通过；原始审查证据保留。具体改动、计数口径与完整日志见 [FIX_REPORT.md](FIX_REPORT.md)。当前 v0.3.0 的密集字幕 abort 已重现；上游 v0.3.3 已包含对应修复，本轮按范围未升级，发布验收仍待完成。
