# 发版继续审查（2026-11-06）

本轮新增确认两处 P2，建议修复后再发布 0.2.3。未修改生产代码、正式测试、内核、依赖锁；未提交、推送或发布。原始图片、代码和历史报告完整保留。

本地检出为 App 分支 `bf2714e5a055b2dbebb9da0f2a03d53c8bd78cf4`，其内核为 v0.3.0；已合并 main 为 `6c2c98f5e288f238f75bac0fa7a1973c5acbebdd`，内核为 v0.3.4。下面涉及的三份源码在两个基线中 SHA-256 完全相同，见 `main-source-validation.json`；本轮故障不依赖内核差异。

## [P2] MoviePilot 换服时丢失新订阅加载，并显示旧取消错误

位置：`App/Shared/Features/MoviePilot/MoviePilotHomeView.swift:774–784`，特别是第 775 行。换服任务入口在第 277 行，重置函数在第 816 行。

服务器 A 的订阅请求仍在等待时，成功改绑 B。保活页面的 `.task(id: moviepilot.boundServerID)` 取消 A 任务并启动 B；`resetServerScopedState()` 清空订阅和错误，却没有清除 `isLoadingSubscribes` 或推进订阅请求代次。B 的 `loadSubscribes()` 因旧任务仍置位而立即返回。A 随后被 API 的取消/配置修订检查拒绝，旧 `catch` 将取消错误写入 B 页面，然后才清除加载标记。B 的任务已经结束，绑定 ID 也不再变化，因此不会补发加载。

受控复现输出：期望 B 列表 `[2]`、无错误；实际列表 `[]`、错误 `CancellationError()`，请求记录只有 `["A"]`。请求在途换服的场景失败；旧请求结束后再换服与手动重试两项对照均通过。这里不是 A 数据泄漏到 B，包内修订检查已经挡住旧数据；问题在 UI 加载所有权与收尾。

建议为订阅加载加入绑定/请求代次，换服立即作废旧加载并允许 B 发请求；成功、失败及加载收尾都只由当前代次写入，取消不展示为错误。仅在重置时写 `isLoadingSubscribes=false` 不足以防止 A 收尾清掉 B 的加载状态。

## [P2] 系统暂停命令未清除音频中断的恢复意图

位置：`App/Shared/Features/Player/PlaybackController.swift:420–422`。

来电等音频中断先通过 `PlaybackAudioInterruptions` 将播放暂停，同时记下 `interrupted=true`。此时系统发送 `pauseCommand`（例如远程控制明确要求暂停），控制器因为当前已是 `.paused` 而提前返回，未经过 `togglePlayPause()` 中的 `noteUserIntent()`。中断结束通知包含 `.shouldResume` 时，仍按旧意图调用 play，覆盖用户的暂停要求。命令中心还会对此命令返回 `.success`。

在现有 iPhone 17 Pro / iOS 26.3.1 模拟器运行独立探针：人工投递真实 AVAudioSession 通知，驱动原 `PlaybackAudioInterruptions` 类及抽取的生产远程暂停闭包。没有用户操作时正常恢复通过；明确清除意图后保持暂停通过；发送生产暂停回调后期望暂停且恢复次数 0，实际 playing=true、恢复次数 1，失败。

建议先记录明确暂停意图，再按当前状态决定是否需要调用引擎 pause；已暂停时应清除恢复意图并保持暂停，不能调用 toggle 将其变成播放。补覆盖自动中断、显式暂停、普通播放中暂停的对照。

## 证据与适用边界

`make-probes.py` 从当前生产源码抽取 MoviePilot 的加载、重置及绑定任务体，放入持有同一组状态的 MainActor 宿主；网络替身保留等待窗口及取消/配置代次检查，用来确定性控制时序。AudioCore 仅去掉未使用的 PlaybackKit import；AudioProbe 使用实际 AVFoundation 类型和通知，远程闭包只将宿主状态路径 `self.state.state` 适配为 `self.state`。源文件哈希、完整生成源码及编译/执行输出均保存。

| 分母：独立探针场景，非 XCTest/全量 App 用例 | unique | executed | passed | skipped | failed |
|---|---:|---:|---:|---:|---:|
| macOS MoviePilot 源码抽取宿主 | 3 | 3 | 2 | 0 | 1 |
| iOS 模拟器音频中断宿主 | 3 | 3 | 2 | 0 | 1 |

计数来源为 `moviepilot-probe.log` 与 `audio-probe.log` 的完整逐场景输出。进程退出 0 只表示探针跑完，FAIL 才是场景判据，不能据退出码报通过。生成器初次重复写入闭包捕获列表造成的编译错误也保留在 `audio-build-initial-error.log`，属于探针开发错误，不计作产品场景失败。

这些探针验证源码逻辑，未进行真实 MoviePilot 改绑或真实来电/Siri 控制验收；也没有重跑全量 App/包测试或双端打包。不能将独立宿主结果描述成正式 App 全量测试结果。`run-probes.sh` 可在当前源码和已有 arm64 模拟器上复跑，构建只落 `.local-build` 并逐轮清理，无需安装依赖。

本轮还检查配置导入/导出、更新入口、直链/本地文件打开、播放生命周期和发版版本/门禁。未将上一轮已修复问题重新列为新增发现，也不把当前 App 分支与历史 v0.3.4 组合打包报告当成同一产物。

## CI 状态

GitHub 查询确认 #97、#98 均已 MERGED，各自 macOS、iOS、SwiftPM 三项检查均成功，见 `pr97-ci.json`、`pr98-ci.json`。合并 main 的运行是 [42209871118](https://github.com/1824239290/OcPlayer/actions/runs/42209871118)，最新状态以 `main-ci-final.json` 为准；PR 全绿不能覆盖本轮新增场景，也不能替代合并提交的检查。

编译产物完成后清理，完整原始输出和源码保存在此目录，原 Vendor 输入及 dist 产物保留。
