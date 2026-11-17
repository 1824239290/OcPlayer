# 架构与平台边界

```text
apps/apple (Swift / SwiftUI) ── core/bindings/apple/OcPlayerCore ─┐
                                                              ├─ C ABI ─ core/crates
apps/windows (C# / WinUI) ─── core/bindings/windows ────────────┘
           │
           └─ 平台播放器 / liberika / 原生渲染与音频
```

`core/Cargo.toml` 是 Rust workspace；Windows solution 在 `apps/windows`；Xcode 工程及平台 Swift 包在 `apps/apple`。仅共享业务决策和 ABI/SDK，不把三个平台塞进同一个构建系统。根 `scripts` 负责定位组件与工作目录，组件 `Scripts` 负责实际构建。

## Swift 与 Rust 的归属

公共 Swift SDK 唯一源码在 `core/bindings/apple/OcPlayerCore`。Xcode 与六个 SwiftPM 消费者引用同一路径，发行 XCFramework 的源码副本是生成产物。

Apple 的平台服务、SwiftUI、原生 DTO、UI 状态投影、凭据保存、UserDefaults 及渲染实现仍保留。部分领域的原 Swift 业务实现仍承担关闭模式、加载失败或注入依赖时的路径，不能因名称包含 Core 就删除。职责、实际后端判定和退出条件见 [清单](migration/APPLE-SWIFT-OWNERSHIP.md)。

Core 功能开关与实际激活不同：`OCP_CORE_ENABLED` / UserDefaults / Info.plist 控制策略，但还必须成功加载正确 ABI 的原生库。结构迁移不改变这些规则。

## 外部内核与数据

Apple `apps/apple/Config/Erika.version` 固定 `v0.3.6`，Windows `apps/windows/Config/Kernel.version.json` 固定 `v0.3.7`。各自补丁、工具链、功能与分发合同不变。liberika 不纳入此次历史导入。

应用标识、数据库格式、配置键、用户数据目录与迁移策略保持不变。验证使用独立测试目录和本地 fixtures，不在用户真实账户上执行写入、OAuth 更新或进度上报。

## Git 与来源

原 Apple、Core、Windows 提交未重写；Core 和 Windows 以非 squash subtree 合入。当前文件有新前缀，导入前历史仍使用原路径。源提交、树和导入提交见 [source-manifest.json](migration/source-manifest.json)。

构建 receipt 的源码提交现在表示 monorepo 提交。Apple 构建号和 dirty 标记读取整仓库 Git 状态；组件钉点仍独立维护。CI 使用新布局缓存键，避免复用旧路径的缓存。
