# 发版准备（2026-11-06，版本号待定）

双端 Release 打包与资产校验通过，发布说明草稿和最终冒烟清单已准备。尚未发布；真实服务器、iOS 真机和真实音频中断验收未完成。当前版本号只沿用仓库中的 0.2.3，不代表已作最终版本决定。

## 准备基线

- 最新合并 main：`053b9a6521992923174f059bf189aff16e2fb8c0`；树对象 `82b9f8499b5ac7db105b0757f04411495d772176`。
- 本次准备分支：`codex/release-preparation`，从该 main 创建。打包时工作树干净，产物没有 dirty 标记。
- 内核：官方 liberika v0.3.4，提交 `a62e45fe991db11c17eeefd033eccd654d15f617`。本机先前生成目录的标记仍为 v0.3.0，已通过仓库脚本重新生成 v0.3.4；两份官方下载归档经固定 SHA-256 校验，旧下载归档与历史验收资料保留。
- 依赖：严格使用现有 App `Package.resolved`，禁止自动更新及使用锁文件外版本。GRDB 7.11.1、Jellyfin SDK 3.3.0、NIO 2.101.3、Collections 1.6.0；打包后锁文件逐字节不变。677 份已跟踪源码、配置、工程和脚本哈希均未变化。

## 构建与实际资产

使用 Xcode 27.1（27A9275），分别执行生产 `Scripts/package-macos.sh` / `Scripts/package-ios.sh`，关闭设备签名，macOS 由脚本做 ad-hoc 签名。构建根目录独立，既有 dist 产物未覆盖。

本次暂定产物为 **0.2.3 / Build 674 / 053b9a6**。Build 是该 main 的提交计数，正式发布工作流另有构建号来源。版本号确定后须重新生成对应版本的资产，不能仅改文件名。

产物在仓库根目录 `dist/release-preparation-20261106/`：

- macOS：App ZIP、DMG、dSYM ZIP 与 `SHA256SUMS.txt`。
- iOS：unsigned IPA、dSYM ZIP 与 `SHA256SUMS-ios.txt`。

验证结果：

| 检查 | macOS | iOS |
| --- | --- | --- |
| 实际 Release 构建 / 打包退出码 | 0 / 0 | 0 / 0 |
| 资产 SHA-256 | 三个资产全部匹配 | 两个资产全部匹配 |
| 分发包与符号 ZIP CRC | 通过 | 通过 |
| 实际 Info.plist 版本 / Build / GitCommit | 0.2.3 / 674 / 053b9a6 | 0.2.3 / 674 / 053b9a6 |
| 许可证文件与内核标记 | 29 份 / v0.3.4 | 29 份 / v0.3.4 |
| 随包依赖锁与源锁一致 | 通过 | 通过 |
| 可执行文件 / DWARF UUID（arm64） | 一致 | 一致 |
| DMG 校验、只读挂载、Applications 链接、挂载 App 签名 | 全部通过，已卸载 | 不适用 |

MPL 文本固定 SHA-256 通过。UUID 与各资产完整哈希见 `artifact-verification.json`。ad-hoc 签名校验不代表 Apple 公证；iOS 产物仍需重签安装。

## 已有回归与本轮冒烟

该 main 的 [GitHub CI](https://github.com/1824239290/OcPlayer/actions/runs/42217640939) 三个 job 均成功：macOS App、iOS 模拟器 App、SwiftPM。完整 CI 输出与 head/job 快照已归档。本轮没有重复执行全量 App / SwiftPM 测试，也没有将旧分支上的全量结果记成这次重新执行。CI 的 ErikaKit 仍按项目既有配置过滤七组依赖图形环境的测试；本地完整 v0.3.4 内核渲染与字幕探针沿用未变二进制的[升级验收](../2026-11-06-kernel-upgrade/UPGRADE_REPORT.md)。

从本次实际 macOS 分发 ZIP 解出 App，并通过正式打开文件面板选择合成 H.264 + AAC 测试片源。CUA 可访问性观察确认片源进度推进、回退 10 秒后继续播放、在 0:10 / 0:20 时暂停按钮变为播放按钮、关闭动作后播放控件移除。系统关于面板显示 `OcPlayer 版本0.2.3 (674)`。这是 AX 状态验证，未据此宣称画质、声音、网络片源或关闭后工具栏完整恢复均已验收；观察摘要见 `macos-ui-smoke.json`。

真实 iPhone 的基本设备信息曾可读取，但随后应用访问返回 CoreDeviceError 4016，无法取得所需设备状态。因此本轮未签名安装、未执行 iOS 真机/来电/Siri 验收，也没有把配对记录等同于真机通过。[SMOKE_CHECKLIST.md](SMOKE_CHECKLIST.md) 保留后续逐项判据。

## 文案与版本决定

[RELEASE_NOTES.md](RELEASE_NOTES.md) 按用户可见变化整理了草稿，暂不填写发布版本和日期。CHANGELOG 中残留的“密集 CJK 字幕崩溃尚未修复”已改为说明 v0.3.4 修复与真实片源验收边界；原 CHANGELOG 快照保存在本轮证据包，历史报告未改写。

相对公开 v0.2.2，本次包含详情页布局、候选源回退、镜像设置、启动动画及一批稳定性修复，已超出单一补丁修复。版本决定应据这个完整范围讨论，而不是只据最后 #99 的两处修复。当前 `Config/App.xcconfig` 的 0.2.3 保持不变，Unreleased 尚未归入正式发布节。

版本号确定后完成最终版本重打包、真实场景冒烟、归并 CHANGELOG 与发布说明，再进入 tag / 发布流程。本轮没有提交、推送、创建 PR、创建 tag 或发布 release。

## 可复核证据

`verification-logs.zip` 保存完整双端构建/打包输出、CI 输出、内核校验、锁文件、源码哈希、原 CHANGELOG、UUID/DMG 校验输出、验证脚本和 UI 摘要。真实设备的完整私有信息仅保留在本机 `.local-build/release-preparation-20261106/evidence/`，没有纳入待提交报告包。两端本次生成的源 App 与中间产物保留在 `.local-build/release-preparation-20261106/`，供版本确定后增量重新打包使用。
