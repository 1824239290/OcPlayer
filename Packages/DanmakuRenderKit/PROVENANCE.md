# DanmakuRenderKit 来源说明

本目录 vendored 自 [qyz777/DanmakuKit](https://github.com/qyz777/DanmakuKit)（MIT License，见 LICENSE）：

- 上游版本：`1.6.0`
- 上游 commit：`ea0f2b6235f97f2747e7ccfb002455e89354c25f`
- 取回日期：2026-08-22

改动（相对上游）：

1. 模块名 `DanmakuKit` → `DanmakuRenderKit`（本仓库 `Packages/DanmakuKit` 是弹幕取数层，
   两个模块不能同名）。源码无自引用 import，改名只涉及 Package.swift 与目录名。
2. Package.swift 重写为本仓库惯例（swift-tools 6.0、macOS 14 / iOS 17、Swift v5 语言模式）；
   未带入上游 Example / podspec / 图片资源。
3. 后续对轨道分配、动画时钟等的本地修补都只改这个副本，并在本文件追加记录。

已应用的本地修补：

- `DanmakuView.swift`：`shoot / canShoot / play() / pause() / stop() / clean /
  recalculateTracks / play(_:)/pause(_:)/sync` 十个控制方法 upstream 为 internal
  （其 SwiftUI 适配器同模块调用所以没暴露），App 侧调用需要，已加 `public`。
  行为零改动，纯访问级别。
- `DanmakuView.swift`：`private extension` → `extension`（轨道选择
  `findSuitableTrack / findLeastNumberDanmakuTrack / findSuitableSyncTrack` 与复用池
  `cellFromPool / appendCellToPool` 从 private 放宽到 internal），供包内测试 target
  以 `@testable` 覆盖这些纯逻辑。行为零改动，纯访问级别。
- `Package.swift`：新增 `DanmakuRenderKitTests` test target（纯 macOS 离屏，
  不碰 GPU / 网络 / UIKit；GIF 侧因 `#if canImport(UIKit)` 不在 macOS 上测试）。

选型背景：替换 Erika 内核 DFM+ 弹幕子系统（滑窗重放非单调导致在屏弹幕跳轨）。
该库的轨道模型是「入轨时追击判定、入轨后不换轨」，结构上杜绝跳轨。
