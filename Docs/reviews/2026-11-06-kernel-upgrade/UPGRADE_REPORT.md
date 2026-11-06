# liberika v0.3.4 升级验收

基线 `66de8ebdf8844131a6f5aecbeff25be84d0ab567`，从官方 v0.3.0 升到 [v0.3.4](https://github.com/AimesSoft/liberika/releases/tag/v0.3.4)，独立于 App 修复 PR。没有修改本地 liberika 仓库。

## 来源与接口

release 于 2026-11-06 08:44:32 UTC 发布，macOS/iOS 资产固定为官方 SHA-256。`Config/Erika.version`、生成的 Swift 版本、官方 C 头同步更新；包标记对应提交 `a62e45fe991db11c17eeefd033eccd654d15f617`。实际使用的 macOS arm64 和 iOS zip 均通过 fetch 脚本哈希校验，xcframework 包含 macOS arm64、iOS arm64、iOS 模拟器 arm64/x86_64 三组 slice。

`ErikaOpenOptions` 仍为 48 字节，新 `start_position_micros` 使用偏移 32 的旧保留槽；Swift 显式设置 0，保留 App 既有续播流程。ABI 回归校验默认值、偏移及非零位置，确保预读/回退预算仍分别在偏移 16/24。

## 密集字幕崩溃复验

旧 v0.3.0 在同一探针（1280×720 本地 H.264、密集 CJK ASS、cue 间隔 0.25 秒、采样 6 秒）触发 Metal 纹理宽度 18768 超过 16384 并收到 signal 6。原始复现日志保留于 App 审查的历史 `fix-verification-logs.zip`。

上游 [c99c248](https://github.com/AimesSoft/liberika/commit/c99c2481dbca2e0eaf59acc6c23523cacefcfc15) 改为二维 glyph atlas 并限制纹理尺寸；GitHub compare 确认它是 v0.3.4 的祖先（ahead 59）。因此未重复提出已修复 issue。

v0.3.4 已启用该探针并通过：字幕轨成功挂载，实际渲染视频和字幕覆盖层，采样期间 failed 事件为 0，未出现 abort。探针新增这些输出断言，防止未挂字幕或未渲染画面也报通过。完整 stdout、stderr、逐 tick 与进程采样随报告归档。

探针仍有系统 PingFangUI 字体打开失败日志，随后使用内置 Droid Sans Fallback；未把它误记为零日志告警。

## 自动化验收

两端 Xcode 验收固定项目原有依赖锁（GRDB 7.11.1、Jellyfin SDK 3.3.0、NIO 2.101.3、Collections 1.6.0），不混入其他依赖更新。

| 分母/来源 | executed | passed | skipped | failed |
|---|---:|---:|---:|---:|
| macOS App：xcresult summary | 918 | 899 | 19 | 0 |
| iOS 模拟器 App：xcresult summary | 923 | 920 | 3 | 0 |
| ErikaKit：XCTest 28 + Swift Testing 65 | 93 | 93 | 0 | 0 |
| 开启密集字幕探针：Swift Testing | 1 | 1 | 0 | 0 |

各平台独立计数，探针也不叠加成唯一用例数。ErikaKit 全量使用默认环境门控；密集字幕探针另行启用。实际跑过 HTTP 认证、打开/seek/停止/关闭、离屏渲染、字幕外观与上采样回归，没有沿用 CI 的七组耗时测试过滤。

初次编译发现打开选项新增字段，已修正宿主与布局用例。初次全量的上采样回归把异步 `building` 当成已计算，同时两秒片源已播完；用例改用持续有效的片源、逐档重新定位，并最多等待 20 秒构建完成，仍要求计算后端有实际上采样帧。单独回归及随后完整套件通过，初始失败日志也归档。

完整日志、官方 release/compare JSON、资产哈希、探针采样及汇总保留在 `verification-logs.zip`。

## 发布边界

此 PR 更新官方二进制及宿主兼容层。新增超分型号/自定义模型等 API 随官方 C 头提供，App 设置继续使用既有档位。真实问题片源与 iOS 真机运行仍需发布前实测，本次不签名、不分发、不发布。

## Release 构建与符号

macOS 与 iOS 通用设备目标的 Release 构建均通过（关闭本地签名）。逐端读取实际 App Info.plist 并核对可执行文件与 dSYM UUID，全架构匹配；产物明细保留在 `release-artifacts.json`。
