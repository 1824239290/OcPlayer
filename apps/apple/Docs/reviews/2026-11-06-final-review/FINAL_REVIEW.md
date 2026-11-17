# 最终发版审查（2026-11-06）

审查对象为 #97（`a0494f1f8befe6ca87cd9f38c8570d75aeb0e822`）与 #98（`f6a03565a516303319fdd42f023855cfbae35a68`）合并后的本地候选提交 `38fabfe3ef3ad3b11b00ada56d8898562a6d2049`。工作树的生产代码未修改；验证用依赖锁结束后恢复。没有合并远端 PR、推送 tag 或发布。

**结论：新增 1 个已离线复现的 P2，建议修复后再发版。现有回归和 CI 通过不能覆盖这个新场景。**

## [P2] 图片缓存身份缺少服务器维度

位置：`Packages/AppDesignKit/Sources/AppDesignKit/Images/CanonicalImageURLCache.swift:105–110`；规范化 URL 同时丢弃原 host。`ImagePipeline.swift:536–548` 的内存/字节缓存也复用该身份。

触发条件明确：两台不同服务器返回相同 UserId，同一设备请求相同图片路径及查询参数。新认证身份仅由 DeviceId + UserId 产生，Token 与服务器地址均不参与；而 `ServerProfile` 明确还有独立 serverID/profile.id 维度，不能把 UserId 当作跨服务器全局唯一键。

离线复现使用两个 `.invalid` host、相同用户/条目、不同合成 token。两个键都成为 `http://ocplayer.invalid/Items/42/Images/Primary?maxWidth=720&_auth=bb27d5fda761`；仅写入 A 后，B 的真实 `CanonicalImageURLCache.cachedResponse` 返回 A 的响应。1 个用例失败，含 2 个断言失败，分别确认身份碰撞和跨服读缓存；不包含真实账号、图片或网络访问。源码保存在 `ImageIsolationReproduction.swift.txt`，完整输出在日志包的 `ocplayer-final-image-isolation-repro.log`。

影响是跨服务器海报/头像缓存串读，不是 token 跨服务器发送。只有满足上述身份及资源路径/查询相同的组合才命中，不描述成所有多服务器使用都会发生。

建议将修复补入 App 批次：在图片请求的缓存上下文中纳入稳定服务器身份（`resolvedServerID`，无值保守使用 profile/origin），同时覆盖 URLCache、内存缓存、Blob 和登录页身份历史；继续保留同服换地址、重新登录共用缓存的行为。旧无服务器维度的缓存应有迁移边界。增加不同服务器/相同用户和资源、同服不同地址、token 轮换及无服务器 ID 的对照回归。

## 发版版本准备

当前 `Config/App.xcconfig` 仍为 0.2.2，公开最新 release 也是 v0.2.2（2026-10-24 发布）。本轮打包不带 tag 参数，产物因此为 `v0.2.2 Build 674 · 38fabfe-dirty`，仅作审查验证，不是新的分发版。新发版建议使用 v0.2.3，并同步源码版本和发布说明；发布流程对已存在 tag 的资产有 `--clobber` 行为，不应把新修复覆盖到旧 v0.2.2。

## 已完成的检查

重点复查认证/切服/取消和登录提交、仓储冷建库及末次进度、SQLite v4 迁移与进度保护、外挂字幕源/缓存/批次、显式续播和内核事件/生命周期、SwiftUI 状态/异步显示、发布 tag 门禁/版本/内核资产、许可证/签名/符号/打包。没有将常量正则的 try!、只从代码创建的 init(coder:) fatalError 或静态信息行索引一概判成发布阻塞。

#97 与 #98 的 macOS/iOS/SwiftPM 共六项 GitHub CI 均为 SUCCESS，具体 head 与 check URL 保留在 ci97/ci98 JSON 中。两个 PR 仍 OPEN，没有执行远端合并。

最终候选 Xcode 回归固定项目原依赖版本，实际打包日志也确认 GRDB 7.11.1、Jellyfin SDK 3.3.0、NIO 2.101.3、Collections 1.6.0，没有将早期本地诊断时的自动更新版本混入验收。SwiftPM 的已有锁临时复用 App 锁，结束后原样恢复。

| 分母与来源 | executed | passed | skipped | failed |
|---|---:|---:|---:|---:|
| 合并候选 macOS App：xcresult summary | 926 | 907 | 19 | 0 |
| 合并候选 iOS 模拟器 App：xcresult summary | 931 | 928 | 3 | 0 |
| 11 个 SwiftPM 包：最终 XCTest + Swift Testing 汇总 | 1421 | 1421 | 0 | 0 |
| 新图片隔离复现：逐用例结果 | 1 | 0 | 0 | 1 |

不同平台不相加作为唯一用例数，新增复现单独列出。SwiftPM 逐包明细见 `package-results.json`。AppDesignKit 首轮已有 `testPurgeRunsOnceOnly` 失败并出现 CFNetwork 缓存数据库告警，未修改源码/断言；单独回归及随后完整 187 项均通过。首轮失败、单独回归、全量重跑全部保留，最终表采用最后完整轮次；未用一次选择性通过抹掉首轮失败事实。新图片隔离复现属于独立的确定性失败。

ErikaKit 完整运行 28 XCTest + 65 Swift Testing，没有 CI 的七组 presenter 测试过滤。密集字幕 abort 的上游修复与已启用探针证据沿用 #98 的同一 v0.3.4 二进制验收；本轮再次验证它与 App 修复合并后的构建和完整内核套件。

## 实际打包验证

双端 Release 构建及 `Scripts/package-macos.sh` / `Scripts/package-ios.sh` 均成功。复用已校验 v0.3.4，独立输出目录避免校验文件互相覆盖。macOS App/ZIP/DMG 与 iOS unsigned IPA 实际生成，含各自 dSYM zip。

- 所有五个资产 SHA-256 与打包生成的校验文件一致。
- DMG 内部验证通过，只读挂载可见 OcPlayer.app 和 Applications 链接，挂载内 App 的 codesign deep/strict 验证通过；之后正常卸载。
- IPA CRC 验证通过，Payload/OcPlayer.app 结构和 Info.plist 已检查。
- 两端各有 29 份许可证文件，许可证固定哈希通过。
- 两端实际可执行文件与 dSYM UUID 匹配，内核 tag 都为 v0.3.4；明细见 `release-artifacts.json`。

本轮未安装/重签 iOS 真机，真实服务的改绑、真实多版本片源和真机后台恢复也未新增现场验收。构建/模拟器/离线复现不被描述成这些场景已完成。

## 证据

`verification-logs.zip` 保存全部原始测试/构建/打包/复现输出、CI 状态、产物校验和 manifest。原有审查、修复与内核升级报告及图片/代码均完整保留。没有第三个 PR；待修问题建议并入 #97。
