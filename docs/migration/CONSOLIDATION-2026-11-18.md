# 合仓收尾接收记录（2026-11-18）

macOS 与 Windows 追加修复均已接收并合入最终候选。Windows 修复的 Git blob 与本机实测报告一致；候选正在完成新提交的必需 CI，main 尚未切换。

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

## 最终候选门禁

1. 候选包含 Mac 修复与 Windows 已实测的精确修复，保留冻结迁移快照、公共绑定唯一性和两端独立 liberika 钉点。
2. 对组合后的实际候选提交运行迁移守卫与必需 CI；此前 `c4f53462115f52df47023e629e8766e3ea841ee6` / Actions `44161047381` 的十个成功 job 不能冒充这份新源码的 CI。
3. 同步两端候选并核对对象 ID，所有必需 job 成功后才具备主分支切换的验证依据。

当前工作不包含正式发行、旧仓库归档或覆盖安装。Windows ARM64、安装升级卸载、真实账号、长片、完整 HDR / Dolby Vision，以及 Mac 外接屏、Intel / Rosetta、系统深浅色切换等范围仍按各自报告保留为未实测。
