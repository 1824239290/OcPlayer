# 单仓库迁移执行记录

开始日期：2026-11-17（Asia/Hong_Kong）。状态：合仓候选已建立，平台验收未全部通过；主分支和旧仓库未切换。

| 阶段 | 状态 | 证据 |
| --- | --- | --- |
| 冻结/备份 | 完成 | 三个源基线没有变化；三份完整 bundle 均恢复为 bare mirror 并通过 `git fsck --full` |
| 非 squash 历史导入 | 完成 | Apple `14aef05d`、Core `0e595108`、Windows `303c72fc`；三源提交均为当前分支祖先 |
| 依赖/构建入口 | 已适配，Windows 实际构建通过 | 根 global.json、Windows 默认 Core 路径、统一根脚本；从新检出的固定内核源码完成 Release 原生与 WinUI 构建 |
| Swift 绑定去重 | 源码检查通过 | 23 份相同内容文件收敛；六个包和 Xcode 引用公共 SDK；706 个其他 Swift 文件及模式不变 |
| CI/发行适配 | 静态检查通过，平台检查部分通过 | Rust、SwiftPM、macOS/iOS 无发布打包已通过；AppTests 有既有失败，Core-enabled 验收结果待记录 |
| 双远端候选同步 | 已开始同步 | GitHub gh 登录与推送权限已验证，两个远端均已有 `codex/monorepo-migration`；最终候选 SHA 在收尾时核对 |
| 平台验收/切换 | 未通过完整门禁，禁止切换 | 不修改两端 main，不归档旧仓库，不安装或发布测试 MSI |

## 工作区与来源

- 独立迁移检出：`D:\OcPlayer-Monorepo`，分支 `codex/monorepo-migration`。
- 完整备份：`D:\OcPlayer-Migration-Backups\20261117-monorepo`，包含 apple/core/windows 的 `.bundle` 与已验证 `.git` mirror。
- 原 Apple、Core、Windows 工作区不移动，不纳入未提交的 `extract_frame.c`；原 Windows 的规划文档仍保持未提交。
- 源提交、树、导入提交和备份 SHA256 见 [source-manifest.json](source-manifest.json)。
- `validationCommit` 固定业务源码候选 `6be4a6f380e77aa951fe47c4b0eeb9fb82265316`，不代表完整门禁通过。迁移模式核对当前 Swift/内核基线，普通模式核对这份历史快照，后续正常业务修改不会被误判为迁移破坏。

## 候选提交与同步

- `7db91c9`：公共绑定、默认依赖、根入口、平台 CI 与发行分流。
- `1e1d2fb`、`144e335`：补充仅在迁移候选上执行的 macOS/iOS 打包、校验和检查，以及大小写敏感的 Core 路径。首次 GitHub 布局检查暴露的路径大小写问题已修正。
- `6be4a6f`：修正 Windows 测试临时目录的 8.3 短路径/长路径别名比较，不改生产路径处理。已用 `D:\OCPLAY~4\ARTIFA~1\VERIFI~1\WRAPPE~1` 作为临时目录前缀复现环境并通过 20 个根回归测试。
- 用户已登录 GitHub CLI，仓库推送权限与 `workflow` scope 可用。使用已有本机代理及单次 Git credential helper，不改全局代理或凭据配置。
- 已验证 GitHub 与 Gitea `main` 均仍为源 Apple 基线 `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`。候选同步仅普通快进推送，没有 force-push、发行标签或归档动作。

## 已取得结果

`scripts/verify-monorepo.py` 通过：Apple 1050、Core 3458、Windows 282 个导入文件，导入树/文件模式准确，历史可达，依赖与 ignore 校验通过。PowerShell 根入口语法通过，MSBuild 默认 Core root 解析到本检出 `core`。

Windows 原生命令 `python` 是 Microsoft Store 别名；本次验证显式使用本机已有 Python 3.12.14，不改系统 PATH 或安装全局工具。布局报告在 `artifacts/verification/layout.json`。

已通过 Core Rust 格式检查和 217 个 Rust 测试（23 个 suite，无忽略项）；Windows C# SDK 的 mock、缺失导出和真实 DLL 检查通过，真实模式包含 31 个检查与 3 组合同。Windows ABI/HTTP/领域合同执行 218 个用例，其中 215 通过、1 失败、2 个依赖 Apple URLSession probe 的用例跳过。完整结果在 `artifacts/verification/windows-core/runtime-results.json`，不能将这次验证标成整体通过。

根入口已补充带中文/空格路径、PowerShell 调用位置与进程目录不同、相对输出目录、媒体路径/URL 和严格失败门禁的回归测试。20 个根测试通过。Shell 语法检查与 GitHub Actions 静态检查通过；这些检查不替代真实平台构建。

全新 Gitea 检出 `artifacts/verification/OcPlayer 中文检出` 在中文/空格路径下通过历史、绑定、根入口与 UI-only Release 编译检查；该 UI-only 结果不替代以下真实原生验证。

### Windows 实际原生与打包验证

Windows 原生依赖已从新检出的固定 liberika v0.3.7 源码构建，内核提交为 `a4f829999fe8df0c35561fe1bdf0f5ad0df0c3a5`；仅复用已有下载归档，不使用旧 Core/Windows 工作区的 DLL。Release WinUI 编译完成，托管编译 0 警告、0 错误；上游内核 Rust 编译保留非致命警告。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 固定原生依赖、Core、liberika 与 WinUI Release 构建 | 通过 | `artifacts/verification/kernel-dependencies.log`、`windows-native-core-build.log`、`windows-release-build.log` |
| 独立存储、配置、备份/恢复与迁移 | 124 个断言通过 | `artifacts/verification/windows-storage/results.json` |
| 独立服务器、鉴权、OAuth fixture、浏览与字幕服务 | 351 个断言通过 | `artifacts/verification/windows-server/results.json` |
| 本地/HTTP 播放、视频/音频解码、暂停/跳转、字幕/弹幕、截图、续播与销毁 | 397 个断言通过 | `artifacts/verification/windows-full/results.json`、`windows-full.log` |
| x64 自包含 MSI 构建、运行时、原生 DLL receipt/hash 与 MSI 元数据 | 通过，未安装、未签名、未发行 | `artifacts/verification/windows-msi/release.json`、`windows-msi-properties.json`、`windows-msi-build.log` |

播放输入由校验过 SHA256 的临时 FFmpeg 工具生成：70 秒 MPEG4 视频、静音 FLAC 音频、SubRip 字幕，路径含中文与空格。没有读取个人媒体；工具仅用于验证，不安装到系统，也不随产品分发。来源在 `artifacts/verification/media/source.json`、`probe.json` 和 `ffmpeg-tool.json`。真实 D3D11 截图 `windows-full/captured-frame-65x49.png` 已检查，奇数尺寸 RGBA、透明度、可见像素及暂停时钟不变断言通过。

本次原生构建 receipt 对应业务源码提交 `7db91c9`，与 `6be4a6f` 的 Core、Swift SDK 和 Apple 业务源码一致；后续候选提交只调整 CI 与测试。`ocp_ffi.dll` SHA256 为 `21E5F380E6B36BDCC929562F17EAFE28C1A5E52DCD3018DB250A49B07DAB6560`，`erika_capi.dll` 为 `A58328D28ED6C3DE4B9D9E755F20D2C4FF98EE16224384DEAF25E539924979D2`。

测试 MSI 是 `OcPlayer-1.0.0-x64.msi`，SHA256 `9959553F89847DCF117D346B1DC5DA315822895B4EB28DAE219937A0F2DFC1D5`，随包 Visual C++ runtime 为 `14.44.35211.0`，ProductVersion/UpgradeCode 等元数据已通过只读检查。打包 receipt 删除本机内核绝对路径后保留源码、固定版本、补丁和 DLL 哈希。

### GitHub Apple 与 Rust 验证

候选 `144e335` 的 [GitHub Actions 44072917833](https://github.com/1824239290/OcPlayer/actions/runs/44072917833) 已通过历史/绑定布局、Linux Rust、SwiftPM、macOS 打包和 iOS 未签名打包。两端打包执行原有许可证、dSYM、macOS ad-hoc 签名检查，并验证产物 SHA256；仅上传候选 artifact，没有创建发行。上述候选与业务源码快照的 Apple/Core/绑定源码相同。

SwiftPM 保留原工作流对需要真实 GPU/Erika presenter 的 suite 的既有跳过范围，不能将其描述为完整 GPU 或 HDR 运行验收。macOS/iOS AppTests 的失败和 Core-enabled parity 结果另行记录，不与编译/打包结果混为一谈。

## 尚未通过的验收与切换限制

- 既有 Core 命令清单仅列 370 条，生产 routing 有 372 条，缺少 `danmakuCache.clearComments`、`danmakuCache.pruneComments`。原 Core 工作区与迁移候选的差异完全相同，详见 `artifacts/verification/baseline-inventory-diff.json`；本轮不改业务/命令清单、不删除或跳过失败用例。
- Apple 源基线 `888ccdd8` 的 [既有 Actions 43596895993](https://github.com/1824239290/OcPlayer/actions/runs/43596895993) 已经有 macOS/iOS AppTests 失败。候选 macOS 的失败与基线同为 `CoreRuntimePreferenceParityTests.testAllRuntimePreferencesMatchOriginalPolicyForNativeCastFacts`，该测试要求实际 Rust 库；未修改该 Swift 测试或跳过它。基线元数据和日志在 `artifacts/verification/github-apple-baseline.json`、`github-macos-baseline.log`，候选日志在 `github-macos-initial.log`。
- 首轮 GitHub Windows job 在根测试阶段遇到 8.3 路径别名差异；`6be4a6f` 已按真实文件系统身份修正并在相同短路径条件下通过。最新候选的 Windows 云端原生验证仍需取得独立结果，不能用首轮未运行的步骤标为通过。
- 在取得真实 Apple/Core-enabled、Windows 构建和打包结果，并消除验收失败前，不切换任何远端 `main`，不归档旧 Core/Windows 仓库。迁移分支可以作为候选同步，但不把它描述为已经完成切换。

Core-enabled parity、最新候选 CI 和双远端最终 SHA 在取得证据后补充；尚未执行、失败或被跳过的检查均不标成通过。
