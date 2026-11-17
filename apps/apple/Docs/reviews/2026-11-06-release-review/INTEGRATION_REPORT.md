# App 修复 PR 整合验收

基线 `66de8ebdf8844131a6f5aecbeff25be84d0ab567`（已合并 #96），内核仍为 v0.3.0。初始审查、修复计划、旧版复现、原始图片/代码/报告和两份历史日志压缩包完整保留。

## 最终代码范围

- MoviePilot 请求固定服务器与配置代次，切服后取消旧重试、401 处理和 SSE 回调；迟到旧 token 的 401 使用已更新 token，避免破坏有效会话。
- 保存并登录先验证 token 和用户资料，再原子提交凭据；失败保留原会话，登出或较新尝试作废旧结果，UI 使用同一尝试代次。
- Jellyfin/Emby 外挂字幕沿用实际播放媒体源，缓存身份包含租户、条目、媒体源、轨道和格式；字幕批次身份阻止旧收尾影响新播放。
- 显式续播支持 1–29 秒，拒绝 0、负值和非有限值，保留现有 ready、源代次和片尾边界。
- 详情已看/未看写回固定会话，避免重复写入或迟到操作污染新会话；仓储在 shutdown 和取消后的网络响应不落盘。

#96 已完整实现独立播放进度、SQLite v4、保护记录和末次写回。整合时保留这些实现，仅补取消等待及迟到已看操作的守卫；未将旧修复快照中的仓储或时间戳实现覆盖回主分支。

## 自动化验收

Xcode 两端固定使用项目原有 `Package.resolved`，加 `-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution -skipPackageUpdates`。MetadataKit 临时复用同一依赖锁后测试，结束恢复原锁。锁定依赖包括 GRDB 7.11.1、Jellyfin SDK 3.3.0、NIO 2.101.3、Collections 1.6.0；本 PR 不升级这些依赖。

| 分母/来源 | executed | passed | skipped | failed |
|---|---:|---:|---:|---:|
| macOS App：xcresult summary | 926 | 907 | 19 | 0 |
| iOS 模拟器 App：xcresult summary | 931 | 928 | 3 | 0 |
| MoviePilotKit：XCTest 82 + Swift Testing 20 | 102 | 102 | 0 | 0 |
| JellyfinKit：XCTest | 224 | 224 | 0 | 0 |
| MetadataKit：XCTest 267 + Swift Testing 34 | 301 | 301 | 0 | 0 |

两个平台的用例数分别统计，不相加当作唯一用例数。跳过项延续主分支的平台条件。新增仓储回归同时覆盖已看/未看、shutdown/取消，确认迟到响应不改原磁盘进度。其余测试包括旧 401、跨服重试、失败登录、冷建库切服、精确 seek、多源字幕身份和旧批次收尾。

完整原始日志及汇总 JSON 已归档在 `integration-verification-logs.zip`；`integration-changes.patch` 记录该 PR 的代码差异，历史 `fix-changes.patch` 保持原样。

## 发布边界

内核升级另一个独立 PR 验收。真实 MoviePilot 改绑、Jellyfin/Emby 多版本媒体换源与真机后台恢复仍需发布前实测；自动化回归不能替代这些真实环境检查。本 PR 不执行签名、DMG/IPA 分发或发布。

## Release 构建与符号

macOS 与 iOS 通用设备目标的 Release 构建均通过（关闭本地签名）。逐端读取实际 App Info.plist 并核对可执行文件与 dSYM UUID，全架构匹配；产物明细保留在 `integration-release-artifacts.json`。
