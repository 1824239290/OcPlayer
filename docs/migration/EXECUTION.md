# 单仓库迁移执行记录

开始日期：2026-11-17（Asia/Hong_Kong）。状态：执行中，主分支和旧仓库未切换。

| 阶段 | 状态 | 证据 |
| --- | --- | --- |
| 冻结/备份 | 完成 | 三个源基线没有变化；三份完整 bundle 均恢复为 bare mirror 并通过 `git fsck --full` |
| 非 squash 历史导入 | 完成 | Apple `14aef05d`、Core `0e595108`、Windows `303c72fc`；三源提交均为当前分支祖先 |
| 依赖/构建入口 | 已适配，验证中 | 根 global.json、Windows 默认 Core 路径、统一根脚本 |
| Swift 绑定去重 | 源码检查通过 | 23 份相同内容文件收敛；六个包和 Xcode 引用公共 SDK；706 个其他 Swift 文件及模式不变 |
| CI/发行适配 | 静态检查通过，平台运行待完成 | 保留 Apple 检查，增加 Core、Windows、实际 Core 激活与始终运行的汇总门禁；actionlint v1.7.12 通过 |
| 平台验收/切换 | 待完成 | 验收前不修改两端 main，不归档旧仓库 |

## 工作区与来源

- 独立迁移检出：`D:\OcPlayer-Monorepo`，分支 `codex/monorepo-migration`。
- 完整备份：`D:\OcPlayer-Migration-Backups\20261117-monorepo`，包含 apple/core/windows 的 `.bundle` 与已验证 `.git` mirror。
- 原 Apple、Core、Windows 工作区不移动，不纳入未提交的 `extract_frame.c`；原 Windows 的规划文档仍保持未提交。
- 源提交、树、导入提交和备份 SHA256 见 [source-manifest.json](source-manifest.json)。

## 已取得结果

`scripts/verify-monorepo.py` 通过：Apple 1050、Core 3458、Windows 282 个导入文件，导入树/文件模式准确，历史可达，依赖与 ignore 校验通过。PowerShell 根入口语法通过，MSBuild 默认 Core root 解析到本检出 `core`。

Windows 原生命令 `python` 是 Microsoft Store 别名；本次验证显式使用本机已有 Python 3.12.14，不改系统 PATH 或安装全局工具。布局报告在 `artifacts/verification/layout.json`。

已通过 Core Rust 格式检查和 217 个 Rust 测试（23 个 suite，无忽略项）；Windows C# SDK 的 mock、缺失导出和真实 DLL 检查通过，真实模式包含 31 个检查与 3 组合同。Windows ABI/HTTP/领域合同执行 218 个用例，其中 215 通过、1 失败、2 个依赖 Apple URLSession probe 的用例跳过。完整结果在 `artifacts/verification/windows-core/runtime-results.json`，不能将这次验证标成整体通过。

根入口已补充带中文/空格路径、PowerShell 调用位置与进程目录不同、相对输出目录、媒体路径/URL 的回归测试。Shell 语法检查与 GitHub Actions 静态检查通过；这些检查不替代真实平台构建。

Windows 原生依赖正从新检出的固定 liberika v0.3.7 源码构建；仅复用已有下载归档，不使用旧 Core/Windows 工作区的 DLL。Windows 构建/集成/MSI 结果在完成后追加。

## 尚未通过的验收与切换限制

- 既有 Core 命令清单仅列 370 条，生产 routing 有 372 条，缺少 `danmakuCache.clearComments`、`danmakuCache.pruneComments`。原 Core 工作区与迁移候选的差异完全相同，详见 `artifacts/verification/baseline-inventory-diff.json`；本轮不改业务/命令清单、不删除或跳过失败用例。
- Gitea 迁移分支普通推送的 dry-run 已通过。GitHub 通过本机已有代理可读取，但非交互推送失败（没有可用的 GitHub 凭据，exit 128）；因此尚不能同步 GitHub 迁移分支或启动 macOS/iOS Actions 验收。
- 在取得真实 Apple/Core-enabled、Windows 构建和打包结果，并消除验收失败前，不切换任何远端 `main`，不归档旧 Core/Windows 仓库。迁移分支可以作为候选同步，但不把它描述为已经完成切换。

Mac/CI、远端候选分支同步和最终切换提交在取得证据后记录；尚未执行或被跳过的检查均不标成通过。
