# 图片缓存隔离修复与 0.2.3 验收（2026-11-06）

最终审查新增的 P2 已修复。修复补入 App PR #97，内核升级保持独立 PR #98；本轮没有合并 PR 或发布 tag/release。

App 分支代码提交：`a688550386c90e7eee4f25302c991b3525c2eed6`。本地组合候选：`6adb83c39f224e144f770eb5013e424b4155716c`（#97 + #98 + 本修复）。新增生产代码在两个检出中一致，CHANGELOG 中的内核条目仅属于组合候选。

## 行为与迁移

- 媒体图片的 v2 身份包含服务器类型、稳定服务器 ID 与账号；UserId 不再被当作跨服务器全局身份。经服务器 ID 确认的同服多入口与 token 轮换继续共用缓存；缺少服务器 ID 的旧档案按档案及入口保守隔离。没有 App 上下文的包调用按 origin（含协议与端口）隔离。
- URLCache、NSCache、Blob、单飞请求和 SwiftUI 图片任务使用同一服务器上下文。URLCache 由管道使用原请求显式读写，本地属性不进入 HTTP 头或请求 URL，避免依赖 CFNetwork 请求副本保留上下文。后台陈旧图片刷新明确绕过 URLCache 回源；公开图床的既有字节键继续保留完整 URL。
- 会话激活、头像、Logo、氛围预热与详情预取都传递上下文，冻结的详情/整窗背景同时保留其来源上下文。登录页仅读取本档案的 v2 历史；按身份查文件也验证服务器上下文，不再恢复无归属的旧全局身份池。
- v1 图片键及历史无法证明服务器归属，不迁移到 v2。旧字节/原始报告保留，由缓存正常淘汰；升级后媒体图片需要重新下载一次。元数据与播放进度不受此迁移影响。
- `Config/App.xcconfig` 的 App 版本已从 0.2.2 更新为 0.2.3，用户可见变更已写入 CHANGELOG。

## 验证

先前已归档的负向复现仅写入服务器 A，却能从服务器 B 读到 A 的 URLCache 响应（1 个用例、2 个断言失败），见 `../2026-11-06-final-review/FINAL_REVIEW.md` 与日志包。本轮同形回归通过，并增加同 origin 不同服务器、相同 UserId/资源、同服换地址及 token、NSCache/Blob/登录页身份、重启、协议/端口与后台回源的对照。

| 分母、来源 | executed | passed | skipped | failed |
|---|---:|---:|---:|---:|
| 本地组合 macOS App：xcresult summary | 927 | 908 | 19 | 0 |
| 本地组合 iOS 模拟器 App：xcresult summary | 932 | 929 | 3 | 0 |
| 本轮 AppDesignKit 完整 SwiftPM：XCTest 汇总 + Swift Testing | 194 | 194 | 0 | 0 |

平台不相加作为唯一用例数。AppDesignKit 本轮 194 XCTest、0 Swift Testing；新增 7 个包回归。App 新增 4 个上下文对照及 1 个登录海报墙跨服回归；移除已停用的全局扫描/取消扫描测试，换为 v1 历史/全局池不恢复和 v2 历史过滤对照。既有排序、容量及租户历史断言保留。

开发过程中出现过编译错误、旧夹具未提供服务器上下文的测试失败、错误 scheme/target 选择；全部开发轮次原始输出保留，不计为最终通过。最终包全量与双端 App 全量均 exit 0，没有更改原图或降低像素/隔离断言来通过。其他未变更包沿用上一轮全项目审查记录，本报告不将它们描述为本轮又跑过全量。

Xcode 测试与打包固定现有验收依赖：GRDB 7.11.1、Jellyfin SDK 3.3.0、NIO 2.101.3、Collections 1.6.0；临时验证锁恢复后不进入 PR。

## 实际产物

组合候选双端 `package-macos.sh` / `package-ios.sh` 成功，产物为 **0.2.3 / Build 675 / 6adb83c-dirty**，内核为 #98 的 v0.3.4。dirty 来自临时依赖锁和未归档的审查文件，产物只用于本次验收，不是发布资产。

- macOS ZIP/DMG、iOS unsigned IPA 和两份 dSYM ZIP 共五个资产 SHA-256 校验通过；ZIP/IPA CRC 校验通过。
- DMG 完整性检查、只读挂载、App + Applications 链接及挂载 App 的 codesign deep/strict 验证通过；正常卸载。
- 两端各 29 份许可证文件，Erika MPL 许可证固定 SHA-256 一致。
- 从实际分发 ZIP/IPA 与 dSYM ZIP 提取的可执行文件和 DWARF UUID 匹配。

产物校验明细见 `artifact-verification.json` 与 `dmg-verification.json`；原始测试、构建、打包和校验输出及验证脚本保存在 `verification-logs.zip`。此前的图片、报告和代码证据均保留。

本轮没有安装或重签 iOS 真机，也没有新增真实服务器/问题片源的现场验收。发布流程仍需真实设备冒烟；没有把模拟器通过描述成真机通过。
