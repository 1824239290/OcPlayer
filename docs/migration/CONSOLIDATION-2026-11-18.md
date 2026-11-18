# 合仓收尾接收记录（2026-11-18）

macOS 与 Windows 追加修复均已接收并合入最终候选，完整必需 CI 已通过。GitHub 与 Gitea 的 main 统一快进到包含两边修复和本收尾记录的提交；收尾文档没有改变已验收的生产源码树。

## 已落入 Git 的内容

- `da66543f8c6154d26affe0a24e9d06c0f3f3a767`：macOS 两个实际问题修复、预读测试合同更新、本地 XML 弹幕 GPU 回归、provenance、Swift 精确 blob 审计及完整验收报告。实际测试输入为 `720e4add` 加此提交的代码差异，证据没有改标为测试时尚不存在的提交。
- 本次文档收尾：原始 Windows 报告、Windows 长路径克隆及已有仓库配置说明、执行记录和本文件。
- 两份平台报告描述各自执行时的状态，后续 Git 变化以执行记录和具体提交为准。原始图片、日志、媒体、安装包和报告均保留。

Mac 修复提交的 Apple tree 为 `7ca694ed3a49d1b0956a583b75070ba27730ff6a`；Core tree 为 `50d9c2f1017b1ce126add60854009db007ac69e2`，Windows tree 为 `7488d81b8468730df4e9a5b9aa7eaf0fc8474ac0`，后两者仍与 `720e4add` 相同。

## Windows 原始修复的接收

用户提供的原文件为 `WINDOWS-VALIDATION-2026-11-18.md`，本仓库副本 SHA256 为 `3cefd9b2b6236e4c888723ab40f43cb101d27786432c984dd96ef94e9102ac6a`。该报告的 Windows 本机结果由 Windows 执行方提供，接收端没有重新执行 Windows 测试，也没有接收到原始日志或 MSI。

报告指定的修复文件为 `apps/windows/src/OcPlayer.Windows/MainWindow.xaml.cs`：

| 校验 | Windows 实测修复 | Mac 接收前文件 |
| --- | --- | --- |
| Git blob | `5cb6050bf34060b106373afe5b352970d6c9114b` | `30bd050d78742d01fa6d924b1d12b6c73498f203` |
| SHA256 | `64c0b29303dce6226e52833426e816af4ba43d8bf0e73e7cfa97ae228e91000a` | `d64a293a0b27e7292b6dd114c3af9f335a8a86759238bfbf0413dcc1ee8d5611` |

首次接收报告时查询 GitHub 和 Gitea 的全部分支，`codex/monorepo-migration` 都仍为 `720e4add068050f5677070a656a3e8b28eb9dd51`，`main` 都仍为 `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`。当时本地 Git object 数据库不存在 Windows 指定的 blob，可读的本地交接目录中也没有对应 patch。

随后用户提供已同步到两端的 `codex/windows-window-close-fix`，提交 `c946a0ccec255a79844b4e6a2c922663dc7fb97c`。接收端确认其唯一父提交为 `720e4add`，仅修改 `MainWindow.xaml.cs`，提交中的 Git blob 正是 `5cb6050bf34060b106373afe5b352970d6c9114b`。Git 保存的 LF 内容 SHA256 为 `7edf756ab4a600de72b9bdc445fc6558c889b8464e6ccafb14259a3e84aba0d8`，逐行还原 Windows CRLF 后为报告中的 `64c0b293...e91000a`；差异完全来自换行符，没有重新编写修复。

合并提交 `e7c1582d857b1e6bb4a147066434e4fd9c59fd99` 保留 Mac 与 Windows 两边历史，无冲突。Apple 和 Core tree 保持上述 Mac 修复提交的值，Windows tree 为 `ac4d01823480b71696df2580a8462e68e5cdecce`，与 Windows 实测修复提交一致。原始报告与此前接收收据保留为历史证据。

## 组合候选的本机复验

迁移守卫通过：冻结快照 706 份不变，当前 699 份保持原 blob，7 份精确审计修复，公共绑定 23 份唯一。根脚本测试首次补跑发现审计测试仍硬编码两份修复，测试更新为核对本轮七个具体文件，原冻结提交与非法变更拒绝用例不变。macOS 报告已明确其原根测试发生于新增审计前。

完整接收与检查证据位于 `artifacts/verification/consolidation-20261118T095735Z`。首次根测试失败保留为 `root-tests-combined.log`，修复后的复跑另存；Windows 已提交修复保存为 `windows-committed-repair.patch`。

## 最终候选验收

1. 候选包含 Mac 修复与 Windows 已实测的精确修复，冻结迁移快照、公共绑定唯一性和两端独立 liberika 钉点均保留。
2. 实际源码候选 `91017b0c2caf8a526b967e29011a8b8ba82fb9ec` 的 [Actions 44281243934](https://github.com/1824239290/OcPlayer/actions/runs/44281243934) 第二次执行整体成功，十个必需 job 均通过。此前 `c4f5346` 的 CI 继续保留为历史证据。
3. 两端候选已同步，随后按用户授权快进两端 main。最终对象 ID 和原工作区检查另存本机收据；后续说明提交仅修改 Markdown，生产源码树与上述验收提交一致。

首轮 iOS 在构建测试用 Rust 库前无法解析 `index.crates.io`，依赖下载失败；这轮 AppTests 尚未执行。保留首轮失败与汇总门禁拒绝记录，在同一源码 SHA 上仅补跑失败项，iOS AppTests 和汇总随后成功；没有修改源代码、切换依赖镜像或删除用例。其余八个成功 job 的证据复用同一源码输入。

| 必需检查 | 最终结果 |
| --- | --- |
| Repository layout | 通过；冻结 706 份 Swift，当前 699 份原 blob、7 份精确审计修复，公共绑定 23 份唯一 |
| Rust Core | 格式检查与 217 项 Rust 测试通过 |
| 普通 macOS / iOS simulator AppTests | 两端通过，NativeCastFacts 实库偏好差分实际执行 |
| SwiftPM package tests | 通过；完整本机 Erika GPU／预读覆盖另见 Mac 报告 |
| Apple Core-enabled parity | SDK 41；AppTests 1027 项中 1008 通过、19 条件跳过、0 失败；传输合同 9、最末公共合同 6 通过；372 条清单严格等于生产 routing，Core 嵌入严格验签通过 |
| Apple package (macos / ios) | ZIP、DMG、IPA 与两份 dSYM 均通过；下载文件校验和复验通过 |
| Windows Core, app and MSI | 原生／WinUI 构建、自包含 MSI、存储 124、服务器 351 通过；真实 SDK 31 检查／3 合同；ABI 218 项中 216 通过、2 个独立 Apple probe 按平台跳过 |
| Monorepo checks | 通过，所有必需平台与候选打包均为 success |

云端 Core 测试记录一条 QoS 优先级反转运行时告警，失败数为零；原始结果包保留，未描述为零告警。19 条条件跳过包括 18 条 iOS 布局用例和未设置截图导出环境的 1 条用例。本机最终单独 Core 回归开启截图导出后的 1009／18 和零 runtime warning 仍仅归属于 Mac 报告中的那次执行。

## 候选产物复验

下载归档的 SHA256 与 GitHub artifact digest 一致。Mac ZIP／DMG 的 40 个普通文件逐字节相同，deep／strict 验签通过；app／dSYM UUID 均为 `1ABD9AC2-1D30-3869-BE64-310875A09440`，架构 arm64，DMG 已卸载。Windows MSI 的哈希与 release.json 相同，receipt 指向 `91017b0` 和固定 v0.3.7 / `a4f829999fe8df0c35561fe1bdf0f5ad0df0c3a5`，CRT 为 `14.51.36247.0`。

| 文件 | SHA256 |
| --- | --- |
| `OcPlayer-v0.3.0-b558-91017b0-macOS-arm64.zip` | `18f47c3e25ec736afecb7f064e4e624debc72357da7fae7c0308d049bafa85af` |
| `OcPlayer-v0.3.0-b558-91017b0-macOS-arm64.dmg` | `ab43dcff6d2aacff1842405abaecbe59ad1cab576e94d1223a6008f678e157a7` |
| `OcPlayer-v0.3.0-b558-91017b0-macOS-arm64.dSYM.zip` | `08d7fccbaa7e6e071aeeb4539dd3b24867cdc1937ce596a415a97824fa447a1a` |
| `OcPlayer-v0.3.0-b558-91017b0-ios-unsigned.ipa` | `7583f72734803e775f2bb25cf873ee983b30f51ebd30d5483707a7a2abc73db8` |
| `OcPlayer-v0.3.0-b558-91017b0-ios-unsigned.dSYM.zip` | `e1040f12ea74837c9a78998bd626323e8f23468c6d85d804d5804743290f916e` |
| `OcPlayer-1.0.0-x64.msi` | `167b6d75df0c7f5142cd598e654b78ef4bdc29ba929483479746bf46178b1f2a` |

完整 CI 结果、失败及补跑日志、原始 `.xcresult`、下载归档、产物和复验 JSON 保存在上述 `consolidation-*` 证据目录。`candidate-final-verdict.json` 核对实际 SHA 与十个 job 的 success；各平台包复验分别为 `ci-macos-package-verification.json`、`ci-ios-package-verification.json`、`ci-windows-package-verification.json`，Core 为 `ci-core-verification.json`。合仓后的主分支自动检查单独保留。

## 合仓后的主分支检查

两端 main 统一快进到 `10194d132cfbc6d73248b75c57fc3863db8c0ea9` 后，[Actions 44292707241](https://github.com/1824239290/OcPlayer/actions/runs/44292707241) 整体成功。布局、Rust、普通 macOS／iOS AppTests、SwiftPM、Core-enabled、Windows Core／app／MSI 与汇总共八个必需 job 均通过。候选 Apple 打包仅在迁移分支运行，主分支按既定条件跳过；前述候选的两端打包证据仍有效。

main 专用的 release SwiftPM 缓存初始化已实际执行成功，两端 NativeCastFacts 实库偏好用例通过。Windows 在 main 重新构建固定内核依赖、Core 和 WinUI，再通过集成、MSI、ABI 和 SDK；此轮 MSI SHA256 为 `4a620b9fd62e8a57f7c058c40880d34cfbe32a25b6ce600df5c04bb5a02ab69a`，下载哈希与 manifest 一致，receipt 指向上述 `10194d1` 与固定 v0.3.7 内核。

原工作区 `/Users/jumusu/Documents/project/OcPlayer` 已快进到同一 main，并重新通过迁移守卫。原未跟踪的 `Docs/REX-LOCAL-MEDIA-LIBRARY.md` 内容哈希保持相同；原本地配置复制到 `apps/apple/Secrets.xcconfig` 并保留旧文件，配置没有进入 Git，原有缓存保留，tracked working tree 干净。

`main-final-verdict.json`、`main-windows-package-verification.json`、`main-promotion-receipt.json` 和 `original-main-transition.json` 保存上述实际结果。最后的验收说明提交仅补充 Markdown，生产源码、脚本和工作流与这份已通过主分支 CI 的提交一致；最终远端对象 ID 再次单独核对。

当前工作不包含正式发行、旧仓库归档或覆盖安装。Windows ARM64、安装升级卸载、真实账号、长片、完整 HDR / Dolby Vision，以及 Mac 外接屏、Intel / Rosetta、系统深浅色切换等范围仍按各自报告保留为未实测。
