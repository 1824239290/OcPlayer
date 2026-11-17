# 单仓库迁移执行记录

开始日期：2026-11-17（Asia/Hong_Kong）。状态：合仓候选已建立，平台验收未全部通过；主分支和旧仓库未切换。

| 阶段 | 状态 | 证据 |
| --- | --- | --- |
| 冻结/备份 | 完成 | 三个源基线没有变化；三份完整 bundle 均恢复为 bare mirror 并通过 `git fsck --full` |
| 非 squash 历史导入 | 完成 | Apple `14aef05d`、Core `0e595108`、Windows `303c72fc`；三源提交均为当前分支祖先 |
| 依赖/构建入口 | 已适配，Windows 实际构建通过 | 根 global.json、Windows 默认 Core 路径、统一根脚本；从新检出的固定内核源码完成 Release 原生与 WinUI 构建 |
| Swift 绑定去重 | 源码检查通过 | 23 份相同内容文件收敛；六个包和 Xcode 引用公共 SDK；706 个其他 Swift 文件及模式不变 |
| CI/发行适配 | 构建/打包通过，完整平台门禁失败 | `fbb4ccd` 的 Rust、SwiftPM、macOS/iOS 打包、Windows 原生/WinUI/MSI 已通过；命令清单、AppTests 与 DanmakuKit 对照仍失败 |
| 双远端候选同步 | 代码候选已同步 | 两端候选均包含已测试的代码提交 `fbb4ccd26d97ab79d496fd217b422d8b65d0d361`；Core/Windows 历史主分支引用也已同步；收尾文档另作提交 |
| 平台验收/切换 | 未通过完整门禁，禁止切换 | 不修改两端 main，不归档旧仓库，不安装或发布测试 MSI |

## 工作区与来源

- 独立迁移检出：`D:\OcPlayer-Monorepo`，分支 `codex/monorepo-migration`。
- 完整备份：`D:\OcPlayer-Migration-Backups\20261117-monorepo`，包含 apple/core/windows 的 `.bundle` 与已验证 `.git` mirror。
- 原 Apple、Core、Windows 工作区不移动，不纳入未提交的 `extract_frame.c`；原 Windows 的规划文档仍保持未提交。
- 源提交、树、导入提交和备份 SHA256 见 [source-manifest.json](source-manifest.json)。
- `validationCommit` 固定结构迁移源码快照 `6be4a6f380e77aa951fe47c4b0eeb9fb82265316`，不代表完整门禁通过。两种模式都核对这份历史快照；迁移模式还核对当前 Swift/内核基线以及用户授权的精确后续修复，后续正常业务修改不会被误判为迁移破坏。

## 候选提交与同步

- `7db91c9`：公共绑定、默认依赖、根入口、平台 CI 与发行分流。
- `1e1d2fb`、`144e335`：补充仅在迁移候选上执行的 macOS/iOS 打包、校验和检查，以及大小写敏感的 Core 路径。首次 GitHub 布局检查暴露的路径大小写问题已修正。
- `6be4a6f`：修正 Windows 测试临时目录的 8.3 短路径/长路径别名比较，不改生产路径处理。已用 `D:\OCPLAY~4\ARTIFA~1\VERIFI~1\WRAPPE~1` 作为临时目录前缀复现环境并通过 20 个根回归测试。
- `fbb4ccd`：修正 Windows 云端 VS2026 的 CRT 目录兼容性，补充 x64/ARM64 目录发现、较新版本选择与禁止 debug/非 v14 runtime 的回归检查；23 个根测试通过。ARM64 仅验证目录发现 fixture，不代表 ARM64 原生构建通过。
- 用户已登录 GitHub CLI，仓库推送权限与 `workflow` scope 可用。使用已有本机代理及单次 Git credential helper，不改全局代理或凭据配置。
- 已验证 GitHub 与 Gitea `main` 均仍为源 Apple 基线 `888ccdd8a1098b4426166bb4b09b2f7dca3d8720`。候选同步仅普通快进推送，没有 force-push、发行标签或归档动作。
- 两端 `history/core/main` 为原 Core 基线 `7e3968e2c6106d87a5d0fa17602a6972905cf19f`，`history/windows/main` 为原 Windows 基线 `49e9e21f24b1ba580580a1129d51a95306bde865`。仅增加明确命名的历史引用，没有覆盖 Apple 分支或标签。

## 已取得结果

`scripts/verify-monorepo.py` 通过：Apple 1050、Core 3458、Windows 282 个导入文件，导入树/文件模式准确，历史可达，依赖与 ignore 校验通过。PowerShell 根入口语法通过，MSBuild 默认 Core root 解析到本检出 `core`。

Windows 原生命令 `python` 是 Microsoft Store 别名；本次验证显式使用本机已有 Python 3.12.14，不改系统 PATH 或安装全局工具。布局报告在 `artifacts/verification/layout.json`。

已通过 Core Rust 格式检查和 217 个 Rust 测试（23 个 suite，无忽略项）；Windows C# SDK 的 mock、缺失导出和真实 DLL 检查通过，真实模式包含 31 个检查与 3 组合同。Windows ABI/HTTP/领域合同执行 218 个用例，其中 215 通过、1 失败、2 个依赖 Apple URLSession probe 的用例跳过。完整结果在 `artifacts/verification/windows-core/runtime-results.json`，不能将这次验证标成整体通过。

根入口已补充带中文/空格路径、PowerShell 调用位置与进程目录不同、相对输出目录、媒体路径/URL、严格失败门禁和 Windows CRT 目录发现的回归测试。23 个根测试通过。Shell 语法检查与 GitHub Actions 静态检查通过；这些检查不替代真实平台构建。

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

### Windows 云端运行库兼容性修复

候选 `b5aad47` 的 [Actions 44080107173](https://github.com/1824239290/OcPlayer/actions/runs/44080107173) 已执行 Windows 原生/WinUI 构建以及存储/服务器集成，随后在 MSI 的运行库发现阶段失败。云端 VS2026 的 redist 为 `14.51.36231`，原脚本固定拼接 `Microsoft.VC143.CRT`，该目录不存在；本机 VS2022 的原有目录仍正常。

`fbb4ccd` 改为在所选官方 redist 的目标架构目录内发现 `Microsoft.VC14*.CRT`，保留必要 DLL 和 PE 架构校验，并拒绝 debug runtime。许可证目录、生成器和 205 条目录数据同步为 MSVC v14 通用描述；内容对照确认只有 Visual C++ Runtime 的版本标签与说明有实质变化，其他四条差异仅为换行形式，证据在 `artifacts/verification/runtime-catalog-v14.json`。

修复后再次完成本机 x64 自包含 MSI 打包，未安装、签名或发行。最终本地验证包在 `artifacts/verification/windows-msi-v14-final`，SHA256 `206ED57136A920272AF097642CDA6DA003BFD44B08F6A6B3D35C6FEAE056470E`；runtime 仍为本机 `14.44.35211.0`，ProductVersion 为 `1.0.0`，UpgradeCode 不变。证据包括 `windows-msi-v14-final-build.log`、`windows-msi-v14-properties.json` 和 `root-tests-v14.log`。

相同代码提交的 [Actions 44103893449](https://github.com/1824239290/OcPlayer/actions/runs/44103893449) 已完成，整体结果为失败。Windows 固定内核准备、原生 Core/WinUI 构建、存储/服务器集成与自包含 MSI 打包均通过，证明 VS2026 CRT 目录修复在真实云端生效。存储和服务器分别通过 124 与 351 个断言；真实 C# SDK 模式的 31 个检查与 3 组合同也通过。后续 Core ABI/C# SDK 步骤失败仍是公共命令清单不一致：Python 执行 218 个用例，215 通过、1 失败、2 跳过；没有把失败改成警告或移出门禁。

云端 Windows artifact 已下载到 `artifacts/verification/github-v14-windows`。MSI 的 SHA256 为 `E65F0F7F00C7CE878A387846582CE4163D893BCA62AB965B111D94DD74F8AEA1`，已与下载文件核对；receipt 的 Core 提交为 `fbb4ccd26d97ab79d496fd217b422d8b65d0d361`，内核提交为既定的 `a4f829999fe8df0c35561fe1bdf0f5ad0df0c3a5`。随包 runtime 为 `14.51.36247.0`，确认没有继续使用本机 VS2022 的旧 DLL；测试包保持 x64 自包含、未签名、未安装、未发行。

### 最终代码候选 CI 结果

完整平台证据针对代码提交 `fbb4ccd26d97ab79d496fd217b422d8b65d0d361`，上述 run 于香港时间 2026-11-17 23:06:19 完成。仅记录证据的后续文档提交不代表这些平台检查已经通过，也不能用文档专用的布局检查覆盖本次失败。

| 检查 | 最终结果 | 说明 |
| --- | --- | --- |
| Repository layout | 通过 | 历史、路径、绑定唯一性与未改变的 Swift 源码检查通过 |
| Rust Core | 通过 | 格式与 workspace 测试通过 |
| SwiftPM package tests | 通过 | 保留原工作流的 GPU/presenter 跳过范围 |
| Apple package (macos / ios) | 两端通过 | 原有打包与 checksum 检查；未创建发行 |
| Windows 原生/WinUI、存储/服务器与 MSI | 通过 | VS2026 云端从固定源码构建并完成自包含打包 |
| Windows Core ABI/C# SDK 步骤 | 失败 | 唯一 Python 失败是 `test_inventory_matches_production_routing`；370 条清单缺少生产已有的两条命令 |
| macOS / iOS AppTests | 两端失败 | 仍为 `testAllRuntimePreferencesMatchOriginalPolicyForNativeCastFacts`；iOS 报告实际 Core getter 次数为 0，预期为 29 |
| Apple Core-enabled parity | 失败 | 公共 Swift SDK 41 个测试通过；DanmakuKit 272 个 XCTest 中同一解析对照用例出现 33 次断言失败 |
| Monorepo checks | 失败 | 汇总门禁如实拒绝上述失败，不允许切换主分支 |

日志在 `artifacts/verification/github-v14-*-failed.log`，run 元数据在 `github-v14-results.json`，Core-enabled 完整分阶段证据在 `github-v14-apple-core`。本轮再次比较 `7db91c9..fbb4ccd`，Core Rust 业务代码、公共 Swift SDK 与 Apple 业务树均无变化；AppTests 的源基线对照和命令清单对照也保持此前结论。没有因结构迁移新增同名 Swift 模块编译错误，但旧 Swift 与 Rust 的行为差异不能因此被忽略。

Core-enabled 在 DanmakuKit 失败后停止，DiagnosticsKit、Core-enabled AppTests、嵌入及末尾命令清单检查仍未执行。这些步骤不标成通过；下一阶段须独立处理基线问题并重新取得完整平台证据。

### GitHub Apple 与 Rust 验证

候选 `144e335` 的 [GitHub Actions 44072917833](https://github.com/1824239290/OcPlayer/actions/runs/44072917833) 已通过历史/绑定布局、Linux Rust、SwiftPM、macOS 打包和 iOS 未签名打包。两端打包执行原有许可证、dSYM、macOS ad-hoc 签名检查，并验证产物 SHA256；仅上传候选 artifact，没有创建发行。上述候选与业务源码快照的 Apple/Core/绑定源码相同。

SwiftPM 保留原工作流对需要真实 GPU/Erika presenter 的 suite 的既有跳过范围，不能将其描述为完整 GPU 或 HDR 运行验收。macOS/iOS AppTests 的失败和 Core-enabled parity 结果另行记录，不与编译/打包结果混为一谈。

Core-enabled job 已完成并失败。真实公共 Swift SDK 的 41 个测试、执行到的 Python 领域/传输合同，以及 JellyfinKit、MetadataKit、MoviePilotKit、BangumiKit、PlaybackKit 的测试通过；DanmakuKit 共运行 272 个 XCTest，同一个 `RustDanmakuPolicyTests.testFilenameAndCanonicalPolicyAgainstNativeCorpus` 用例出现 33 次断言失败。示例 `Title.S01E01`：Rust 返回季/集为 1/1，旧 Swift 返回 nil/nil。两个解析实现与这份 Swift 测试的源码均未因迁移改变；本轮不更改解析规则或测试预期来制造通过结果。

完整下载证据在 `artifacts/verification/github-apple-core-initial`。脚本在 DanmakuKit 失败处以非零状态退出，因此后续 DiagnosticsKit、Core-enabled AppTests、嵌入和末尾公共命令清单检查没有执行，不能将它们标成通过。普通 AppTests 的 macOS/iOS 失败在源基线与迁移候选中同为 NativeCastFacts 用例，iOS 对照日志在 `github-ios-baseline.log`、`github-ios-initial.log`。

## 修复前的验收阻塞与切换限制（fbb4ccd）

- 既有 Core 命令清单仅列 370 条，生产 routing 有 372 条，缺少 `danmakuCache.clearComments`、`danmakuCache.pruneComments`。原 Core 工作区与迁移候选的差异完全相同，详见 `artifacts/verification/baseline-inventory-diff.json`；本轮不改业务/命令清单、不删除或跳过失败用例。
- Apple 源基线 `888ccdd8` 的 [既有 Actions 43596895993](https://github.com/1824239290/OcPlayer/actions/runs/43596895993) 已经有 macOS/iOS AppTests 失败。候选 macOS 的失败与基线同为 `CoreRuntimePreferenceParityTests.testAllRuntimePreferencesMatchOriginalPolicyForNativeCastFacts`，该测试要求实际 Rust 库；未修改该 Swift 测试或跳过它。基线元数据和日志在 `artifacts/verification/github-apple-baseline.json`、`github-macos-baseline.log`，候选日志在 `github-macos-initial.log`。
- 首轮 GitHub Windows job 的 8.3 路径别名差异已由 `6be4a6f` 修正；随后云端 MSI 暴露的 VS2026 CRT 目录变化已由 `fbb4ccd` 修正。最新云端原生/WinUI、存储/服务器和 MSI 均通过，后续 ABI/SDK 步骤仍因上述既有命令清单失败而不通过。
- Core-enabled DanmakuKit 的 Rust/旧 Swift 解析语料不一致仍未解决。虽然两边源码均与迁移前相同，但这项差异确实阻止行为归属验收，不能仅凭去重或打包成功宣称不存在双后端行为差异。
- 在取得真实 Apple/Core-enabled、Windows 构建和打包结果，并消除验收失败前，不切换任何远端 `main`，不归档旧 Core/Windows 仓库。迁移分支可以作为候选同步，但不把它描述为已经完成切换。

最终代码候选的完整 CI 与 Core-enabled parity 均未通过；只完成候选合仓与双远端同步，不宣称完成主分支切换。尚未执行、失败或被跳过的检查均不标成通过。

## 用户授权的基线问题修复

完整候选 CI 出结果后，用户明确要求“接着修吧”。此阶段独立修复已有问题，不把业务修复混入原始结构迁移证明，不改写历史报告或原源清单：

- 公共命令清单补齐 `danmakuCache.clearComments` 和 `danmakuCache.pruneComments`，现在与生产 routing 的 372 条一致。原有全命令非对象参数、requestId 及副作用边界合同不变；本机真实 DLL 的 6 个公共合同测试通过。
- Swift `parseNative` 只删除已知媒体后缀；季数、年份和分辨率排除仅作用于裸数字，不再吞掉 `S01E01`、显式 E1080 或无后缀点号命名。增加固定预期回归，既检查原生兜底也检查公共入口；Rust 业务代码、canonical 语义和原差分 corpus 不改。
- 普通 macOS / iOS simulator AppTests 先构建对应平台的真实 Rust dylib，嵌入并签名测试宿主，再运行全部 AppTests。全局 Core 默认仍关闭，偏好用例自行切换 override；实库存在和每轮 29 次调用的断言全部保留。正式打包和 Core-enabled macOS 验证仍是独立入口。
- 冻结快照仍证明 706 个 Apple Swift 文件与源基线一致。当前修复只允许 [审计清单](follow-up-repairs.json) 中两份文件的精确前后 blob，另外 704 份和全部文件模式保持不变；额外变化、原 blob 被改写、绑定复制或修改均由迁移守卫拒绝。
- 本机 40 个根回归测试通过，包含平台目标选择、带中文/空格路径、缺库构建/架构/签名失败门禁与 Swift 精确修复审计。Apple 工具链调用使用 mock fixture 验证，不将其标成真实 macOS/iOS 运行结果；真实平台结果须由新候选完整 CI 提供。
- 本机完整 Windows Core 验证已通过：217 个 Rust 测试、真实 C# SDK 的 31 个检查与 3 组合同；Python C ABI 执行 218 个用例，216 通过、0 失败、0 错误，2 个既有 Apple URLSession probe 用例仍跳过。原清单失败已经消除；完整证据在 `artifacts/verification/ci-fixes-windows-core`，跳过项不能记为通过。

修复候选尚待完整云端验收，`main` 和旧仓库保持不动；未发布、签名或安装新的正式发行包。
