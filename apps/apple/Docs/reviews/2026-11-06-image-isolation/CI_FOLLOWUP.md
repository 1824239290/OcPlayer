# iOS 标签栏回归等待修正（2026-11-06）

App PR #97 的首轮新增图片隔离 CI（head `7c2c0ab823298ccdffa5d9f509fa11eac28eae73`）中，macOS 与 SwiftPM 成功，iOS 失败。原始运行：[42202882510](https://github.com/1824239290/OcPlayer/actions/runs/42202882510)。没有通过重跑旧提交消除这次失败。

唯一失败是已有的 `TabSearchIntegrationTests.testProductionTabBarSurvivesDetailReturnAndSearchSelection`：从设置切回保留详情栈的首页，固定等待 300ms 后，`isTabBarHidden` 仍为 false，原断言期望 iPhone 上为 true。该轮 iOS 为 932 executed / 928 passed / 3 skipped / 1 failed（完整 XCTest 汇总；没有 Swift Testing）。CI 使用 Xcode 26.6 / iOS 26.4.1；本机可用运行时不同，不能声称在本机重现了同一个时序。

测试改为等待实际选中的 Tab、挂载窗口、导航栈深度、Tab/导航转场结束和标签栏显示状态同时满足，并连续确认两次，最多等待 3 秒。保留原显示/隐藏断言；导航栈或隐藏状态一直错误仍会超时失败。只修改测试同步方式，没有更改生产导航逻辑，也没有新增跳过。原始 CI 只提供固定时刻的错误状态，不能据此把生产逻辑判定为永久错误；新的 CI 会继续检验转场完成后的真实状态。

| 来源、分母 | unique | executed | passed | skipped | failed |
|---|---:|---:|---:|---:|---:|
| 本地 iOS 标签栏用例，`-test-iterations 5`，XCTest 完整输出 | 1 | 5 | 5 | 0 | 0 |
| 本地组合候选 iOS 全量，xcresult summary | 932 | 932 | 929 | 3 | 0 |

本机 iPhone 17 Pro 模拟器 xcresult 记录 OS 26.3.1。五次运行不计为五个独立用例，也不与全量相加。此次后续变更仅影响 iOS 测试源码；生产图片修复、内核和已验证打包代码均未改变，因此此前双端实际产物记录仍对应其原生产代码提交。

完整失败 CI 日志、对应 PR 门禁快照、本地五次日志及 xcresult 摘要、本地全量日志及摘要、测试源码快照见 `ci-tab-state-verification.zip`；包内 SHA-256 manifest 可复核。此前 `verification-logs.zip` 保持原样，保留早期完整验证证据。此文提交时，新提交的 GitHub CI 尚待运行，不将本地通过记作 CI 通过。
