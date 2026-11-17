> 历史记录保留：本文记录初始审查或 `5345e0c` 上的修复轮次。本次 App PR 已按 `66de8eb`（#96）重新整合，最终代码范围和验收以 [INTEGRATION_REPORT.md](INTEGRATION_REPORT.md) 为准；内核升级独立提交。

# App 修复与验证报告

基线 HEAD：`5345e0c`；应用版本 0.2.2。原 REVIEW.md、FIX_PLAN.md、复现源码 .swift.txt 与原 verification-logs.zip 完整保留。本轮修复未提交、未发布。

## 已修复

| 审查项 | 修复结果 | 回归证据 |
|---|---|---|
| P1 #1 MoviePilot 跨服重试 | 每个请求固定服务器地址与配置代次；首发、退避、401 重放、响应返回和 SSE 更新校验会话。服务器/账号的直接修改也作废旧 token。 | 可控退避闸门验证切服后只发送原始请求；迟到旧 token 401 复用已经刷新的 token。 |
| P1 #4 迟到登录覆盖会话 | 新凭据通过 token 与用户信息验证后才在主线程原子提交；失败保留原凭据。登出/后续登录/配置变化可取消旧尝试。UI 的登录状态、用户信息与通知清理均有尝试守卫。 | 登出后迟到登录、旧登录成功/失败遇到新登录、失败改绑保留原会话、旧通知不清新 token。 |
| P1 #2 旧仓储跨会话安装 | 等建库前后比较服务器实例与会话代次，并在等待后复查已创建仓储。 | 确定性建库闸门验证换服；并发等待者复用同一仓储。 |
| P1 #3 最终进度串租户 | 播放开始绑定原租户；退出时同步捕获不可变进度快照，异步落盘沿用原归属。最终快照可以在旧仓储关闭后落盘，普通旧仓储写入仍被拒绝。保留亚秒进度时间戳，避免迟到快照倒退较新状态。 | 同 itemID 的 A/B 进度隔离；shutdown 后最终写回；A→B→A；同一秒内旧快照/旧元数据不覆盖较新进度。 |
| P2 #5 多源字幕不匹配/缓存冲突 | 按播放请求的 mediaSourceID 严格选源；指定源不存在时不回退。字幕身份与缓存路径包含服务器、账号、源、轨道、格式的稳定哈希。旧批次不能开始或结束新批次。原缓存文件保留。 | Jellyfin/Emby 第二源、缺失源、无 ID 首选源，以及跨服务器/源/格式缓存；过期字幕批次回归。 |
| P2 #6 30 秒内续播失效 | 执行所有有限的显式正续播位置，保留就绪等待、播放代次与片尾边界。 | 1/20/29/30/40 秒实际到达替身引擎；0/负值/NaN/Infinity 不定位；既有重开/换片守卫测试通过。 |

详情已看写回保留原视图模型契约，并绑定 attach 时的会话；已通过仓储完成的操作不再重复动态选择当前仓储。回归确认旧详情不能把同 itemID 的已看状态写到新会话。

## 反向回归

未修代码上，MoviePilot 2 个回归用例失败（5 个断言失败），App 3 个回归用例全部失败（5 个断言失败）。原观察式复现保持不变，新增测试改为断言正确行为。建库、登录响应与退避使用可控闸门；最终进度通过返回任务等待落盘，不靠延迟碰窗口。

原始输出：`ocplayer-fix-MoviePilot-red.log`、`ocplayer-fix-App-red.log`，收在 fix-verification-logs.zip。

## 最终验证

AppTests 的计数来自各平台最后一轮 xcresult 的 `get test-results summary`，包含 XCTest 的平台跳过；不是 grep 逐条日志计数。macOS/iOS 是各自分母，不跨平台相加。

| 平台 | 单轮用例总数 / executed（含 skipped） | passed | skipped | failed |
|---|---:|---:|---:|---:|
| macOS 26.6 arm64 | 910 | 891 | 19 | 0 |
| iOS Simulator 26.3.1，iPhone 17 Pro | 915 | 912 | 3 | 0 |

机器可读摘要：fix-macos-tests-summary.json、fix-ios-tests-summary.json。

SwiftPM 各包计数来自最后一轮 XCTest `Executed` 汇总与 Swift Testing `Test run with` 汇总，两种框架均计入。下表每包是独立分母；总计单轮 executed/passed 1345，failed 0。

| 包 | executed | passed | skipped | failed |
|---|---:|---:|---:|---:|
| AppDesignKit | 187 | 187 | 0 | 0 |
| CoreModel | 19 | 19 | 0 | 0 |
| DiagnosticsKit | 95 | 95 | 0 | 0 |
| PlaybackKit | 71 | 71 | 0 | 0 |
| DanmakuKit | 228 | 228 | 0 | 0 |
| DanmakuRenderKit | 12 | 12 | 0 | 0 |
| JellyfinKit | 224 | 224 | 0 | 0 |
| BangumiKit | 89 | 89 | 0 | 0 |
| MetadataKit | 251 | 251 | 0 | 0 |
| MoviePilotKit | 102 | 102 | 0 | 0 |
| ErikaKit | 67 | 67 | 0 | 0 |

ErikaKit 普通包验证明确排除 ErikaRenderTests、ErikaSmokeTests、ErikaOpenFileTests、ErikaHTTPHeaderTests、ErikaLifecycleTests、ErikaMemorySnapshotTests、ErikaReadAheadBehaviorTests；这些被过滤的测试不计入执行数。环境门控的性能探针在普通包测试中的早返回不能视为性能/字幕压力验证，本轮另行启用了压力探针，结果见下方。完整命令和每包汇总见 fix-package-results.json。

双端 arm64 Release 构建（禁用签名）均通过；产物版本及 dSYM UUID 见 fix-release-artifacts.json。macOS Release 与 Debug 测试按顺序执行，避免共享 DerivedData 的构建数据库互锁。完整原始日志、诊断期间的失败构建/旧测试夹具失败及命令记录均收入 fix-verification-logs.zip；失败诊断轮不混入最终通过计数。

## 内核上游核查（按用户后续指示）

本项目仍使用 liberika v0.3.0。启用原有本地性能探针，以 0.25 秒 cue 间隔、6 秒采样重跑，进程收到 signal 6：Metal 纹理宽度 18768 超过 16384。完整 stderr 在 `ocplayer-fix-cjk-stderr.log`，探针输出在 `ocplayer-fix-cjk-probe.log`。

检查了 AimesSoft/liberika 全部 22 个非 PR issue（open/closed），并进一步查了当前 main、发布 tag 与相关文件提交历史。没有重复创建 issue：上游已经通过 [c99c248](https://github.com/AimesSoft/liberika/commit/c99c2481dbca2e0eaf59acc6c23523cacefcfc15) 修复同类越限崩溃，包含按设备上限分行/分页、裁剪、分块及回归测试。GitHub compare 确认该提交是 [v0.3.3](https://github.com/AimesSoft/liberika/releases/tag/v0.3.3) 的祖先，tag 源码也包含修复；新提同一崩溃 issue 没有必要。

依照“先处理 App，上游已有则等待”的范围，本轮未修改本地 liberika 仓库或项目内核版本。等待下一步升级验收；上游修复存在不等于本项目当前 v0.3.0 已消除崩溃。上游原始 JSON 与源码核查证据一并保留在日志压缩包中。

## 尚未完成的发布验收

- 将项目升级到包含修复的内核版本，再复跑同一密集字幕探针及真实问题片源。
- 真实 Jellyfin/Emby 多版本媒体验证字幕/换源、真实 MoviePilot 改绑，以及真机 30 秒以内后台故障恢复。

本轮 App 自动化门禁通过，当前内核的已复现 abort 仍阻塞发版；未打包 DMG/IPA、签名或发布。
