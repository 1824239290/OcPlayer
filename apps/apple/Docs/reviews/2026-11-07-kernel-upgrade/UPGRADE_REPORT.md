# liberika v0.3.6 升级验收

从 v0.3.4 升到官方 [v0.3.6](https://github.com/AimesSoft/liberika/releases/tag/v0.3.6)，上游发布于 2026-11-07 19:07:37（北京时间），对应提交 `e38a511561cb30ca57bd370b944d2e99b12737c7`。

## 变更与来源

同步更新 `Config/Erika.version`、生成的 Swift 版本与官方 C 头。新增头文件接口 `erika_embedded_fallback_font`；现有打开选项布局与宿主调用不需要调整。v0.3.6 改进字体回退、彩色 Emoji 与包体积，并包含 v0.3.5 的外挂字幕 BOM 处理与错误隔离修复。App 弹幕使用自己的 DanmakuRenderKit，内核新增 Emoji 能力不等同于 App 弹幕已接入该能力。

`Scripts/erika-v0.3.6.sha256` 固定全部四个 Apple 平台归档哈希；官方 SHA256SUMS 自身及各归档哈希与 GitHub Release API 的 digest 一致。实际下载的 macOS arm64、iOS 归档通过固定哈希校验。框架约 317 MiB，包含 macOS arm64、iOS arm64、iOS 模拟器 arm64/x86_64，缓存复用检查通过。

## macOS 归档兼容

首次合成失败：新版 compiler-rt 的 Catalyst `LC_BUILD_VERSION` 包含工具版本，长度由 24 字节变为 32 字节，旧修复脚本只处理 24 字节声明。

脚本现在将声明改为 24 字节 `LC_UUID`，必要时前移后续命令、更新 `sizeofcmds`，并在原命令区末尾补零。节数据与符号的绝对偏移保持一致。官方库逐成员核对：3121 个非符号索引成员全部保留，285 个成员仅改变平台命令，265802 个 Mach-O 符号及字符串表逐字节一致，其他节数据和 LLVM bitcode 成员完整保留；剩余构建平台均为 macOS。

系统 nm 无法解析部分新版 Rust LLVM bitcode，因此完整性结论使用逐成员原始字节与 Mach-O 符号表核对，不以 nm 输出作为完整符号分母。

新增脚本回归覆盖旧/新声明、后续符号命令的偏移保持、纯 macOS 输入及异常命令拒绝，接入测试和发布 CI。

## 验证结果

| 检查 | 通过 | 跳过 | 失败 |
|---|---:|---:|---:|
| macOS App（988 项） | 969 | 19 | 0 |
| iOS 模拟器 App（996 项） | 993 | 3 | 0 |
| ErikaKit XCTest | 28 | 0 | 0 |
| ErikaKit Swift Testing | 65 | 0 | 0 |
| 开启密集中文字幕探针 | 1 | 0 | 0 |
| 归档修复 Python 回归（含两种命令长度子用例） | 3 | 0 | 0 |

ErikaKit 全量测试未使用 CI 的渲染测试过滤；环境门控探针单独启用。密集字幕探针使用 1280×720 本地 H.264、0.25 秒 cue 间隔，采样 6 秒，实际视频与字幕覆盖层渲染，失败事件 0。仍有系统 PingFangUI 字体打开失败日志，随后成功使用内置 Droid Sans Fallback。

macOS 与 iOS 通用设备目标的 Release 构建均通过，关闭本地签名；核对两端实际可执行文件包含 `v0.3.6`。既有诊断代码和弹幕代码的编译警告仍存在。保持项目依赖锁与原有未提交编辑，哈希核对通过。

完整官方元数据、下载与初次失败日志、重试与缓存日志、测试和构建日志、探针采样、归档及源文件哈希保留在 `verification-logs.zip`；结构化摘要与 Release 产物路径另列在本目录。未发布安装包，iOS 真机播放尚未实测。

## PR 独立验收

PR 从最新 main `93dd6e3` 分出，仅包含内核升级和构建兼容改动。在独立工作树重新执行 ErikaKit 全量（XCTest 28 + Swift Testing 65）、归档修复回归 3 项和固定哈希/缓存检查，全部通过；日志保存在 `pr-validation-logs.zip`。

前述双端 App 与 Release 本地结果来自升级准备工作区，该工作区另有未提交的播放编辑，未纳入本 PR；双端 App 的 PR 提交验收由 CI 重新执行。
