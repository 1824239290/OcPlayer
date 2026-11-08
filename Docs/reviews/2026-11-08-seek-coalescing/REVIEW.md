# 重复 scrub seek review

范围：此前未提交的 PlaybackController、SeekCoalescer、PlaybackKit 测试与引擎替身。内核升级文件已包含在 PR #101，不重复纳入本 PR。分支基于 main `93dd6e3`。

同一落点在 300 ms 内重复提交时只调用一次内核，也只记录一次观看中断和用户跳转样本。不同落点、跨窗口提交和新会话继续放行。此修复减少重复 seek 对在途读取的干扰；不声称根治内核所有 seek 取消或读取错误。

## Review 修正

- 中间发生快进、章节、远程或自动跳过后，必须清除 scrub 基准，否则窗口内拖回原落点会被误吞。统一在非 scrub 的 recordSeek 路径重置。
- 首次内核 seek 抛错后重置基准，允许同落点重试。
- 有限 Double 乘以 1000 仍可能溢出 Int64；改用可失败的精确转换，异常值放行且不改变基准。控制器拒绝非有限的拖动比例。
- 保持合并状态和注入时钟为 @ObservationIgnored，避免无意义的 SwiftUI 更新；新 PlayerState 代际重置基准。

原有策略与引擎替身用例之外，新增直接调用 PlaybackController 的回归，覆盖重复提交的内核调用和 onUserSeek 计数、快进后拖回、新会话、失败重试与非有限比例。策略另外覆盖有限超大数值。

## 验证

PlaybackKit 全量通过：XCTest 93 项，Swift Testing 2 项，失败 0。macOS 实际控制器套件 25 项全部通过，包含新增 5 项回归。iOS Release 构建及开发签名通过。macOS Release 构建与签名检查通过。新会话测试首次运行因复用已取消的事件流超时；改用新引擎模拟真实代际后套件全量通过，首次失败与重跑日志均保留。


## 本地安装验收

手机（iPhone 17）、平板（iPad mini 5）和本机 Mac 均覆盖安装成功，版本 0.3.0 / Build 2026110819。两端安装产物的可执行文件包含 v0.3.6；安装来源是修复后的源码加本地内核升级（已存在的 PR #101），GitCommit 为 `f167e25-dirty`。本 PR 本身只提交 seek 改动与 review 记录。

Mac 与 iPad 启动成功，并核对运行进程。手机安装后的应用列表确认新构建号；启动检查因手机锁屏被系统拒绝，尚未进行手机播放验收。原 Mac App 完整保存在 `.local-build/installed-backup-20261108.*`，应用数据未删除。

构建、测试（包括首次夹具超时）、安装与启动的原始日志和结构化输出保留在 `.local-build/kernel-upgrade-v0.3.6/*20261108*`。此轮不包含三端实际片源播放回归；PR 全量双端测试交由 CI 执行。
