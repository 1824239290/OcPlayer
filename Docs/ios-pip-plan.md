# iOS 小窗播放（PiP）实施方案

> 2026-10-24。依据 [ios-pip-research.md](ios-pip-research.md) 的调研结论细化。总原则：**零内核改动**——依赖的 C API（`attach_flutter_texture` / `set_flutter_texture_buffer` / `render_tick_with_timing` / `detach_surface` / 隐式 `try_resume_video_decode`）全部已暴露，改动全落在 ErikaKit（我们的 Swift 包）与 App 层。所有新代码 `#if os(iOS)` 包裹，macOS 本期不动。

## 0. 里程碑总览

| 阶段 | 内容 | 出口判据 |
|---|---|---|
| **Spike**（1-2 天） | 打通「texture 通路 → displayLayer」最小帧流，前台+后台各验一次 | GO/NO-GO。NO-GO 则整理复现报上游内核，方案 B（App 内迷你窗）顶上 |
| **M1 手动 PiP** | HUD 小窗按钮进出 PiP，播放/暂停/进度可用，回前台恢复 | 真机验收清单 §5.1 |
| **M2 自动+完善** | 退后台自动 PiP（设置开关）、skip 按钮、分辨率自适应、failed/中断全路径 | 真机验收清单 §5.2 |
| **M3 打磨（可选）** | 弹幕合成进 PiP、iPad 专项、功耗调优 | — |

## 1. 组件设计与文件清单

### 1.1 ErikaKit 层（渲染帧到纹理，不懂 AVKit）

**`ErikaPresenter.swift` 补 3 个封装**（C API 已有，纯包装，与 `attachMetalLayer:115` / `detachSurface:128` 同款式）：

```swift
public func attachFlutterTexture(textureID: Int64, kind: ErikaFlutterTextureKind,
                                 pixelWidth: Int, pixelHeight: Int, scale: Double) throws
public func setFlutterTextureBuffer(_ rawTexture: UInt64, pixelWidth: Int, pixelHeight: Int) throws
```

**`ErikaEngine.swift` 加 texture 档**——完全复刻 `setBackgroundAudioOnly`（`:501`）的骨架（stop RenderLoop → 起 16ms/4ms-leeway DispatchSourceTimer → `step` 档位闸门），差异只有三点：

```swift
public func beginTextureRendering(onFrame: @Sendable (_ pixelBuffer: CVPixelBuffer, _ pts: CMTime) -> Void) throws
public func endTextureRendering() throws   // 退档：停 timer → 切回 metal layer → restartRenderLoop
```

1. timer 拍下执行的是「渲染帧」而非「纯音频 tick」：取 pool 中的 IOSurface texture → `setFlutterTextureBuffer` → `renderTick(at:presentationDelay:)` → 把同一 IOSurface 的 `CVPixelBuffer` + PTS 交给 `onFrame`；
2. 进档先 `detachSurface()` 再 `attachFlutterTexture(...)`；`endTextureRendering` 里 `detachSurface()` → `attachMetalLayer(...)`（复用 `storedAttachedView()` 持有的 layer 与尺寸）→ `restartRenderLoop()`；
3. 与 `setBackgroundAudioOnly` 互斥（`step` 闸门统一管三态：`display / texture / audioOnly`）。**audioOnly → texture 切换不需要额外内核调用**——内核注释明确「切回 render_tick 走 `try_resume_video_decode` flush + 回关键帧」，退后台档注释（`ErikaEngine.swift:507`）已确认此路径。

**新文件 `ErikaKit/Sources/ErikaKit/FrameSurfacePool.swift`**：3 架 IOSurface 循环池。

- `IOSurfaceCreate`（BGRA、宽高按 §2.1）→ `CVPixelBufferCreateWithIOSurface` → `MTLTexture`（**`MTLCreateSystemDefaultDevice()`——iOS 上系统唯一 device，与内核 device 同一，不存在跨 device 导入问题**；macOS 将来做时再处理多 device）；
- 背压：被 `enqueue` 占用/未消费的 surface 不复用；`displayLayer.isReadyForMoreMediaData == false` 时跳过本拍（丢帧优于堆帧）；
- 尺寸变更（M2 的 `didTransitionToRenderSize`）时整体重建。

边界约定：**ErikaKit 到此为止，输出 `(CVPixelBuffer, CMTime)` 回调；AVKit/PiP 语义一概在 App 层**。ErikaKit 现有依赖已含 Metal/CoreVideo/IOSurface（`ErikaKit/Package.swift:24-42`），无需加链接。

### 1.2 App 层（PiP 语义）

| 文件 | 改动 |
|---|---|
| **`App/Shared/Features/Player/PipCoordinator.swift`（新）** | 核心新组件，见 §2.3-2.5 |
| `PlayerScreenComponents.swift` | 加 `PipHostView`（`UIViewRepresentable`，承载 displayLayer 的零尺寸 host view，**必须在 window 树内 PiP 才能启动**）；与 `PlayerVideoSurface` 并排 |
| `PlaybackController.swift` | pip 档接线：`engine.beginTextureRendering(onFrame:)` 的启动/停止点；`play/pause/seek` 的既有方法即 PiP 控件的转发目标 |
| `AppModel+Playback.swift:553` `playbackDidEnterBackground()` | 第三分叉：PiP active/启动中 → 走 pip 档，否则现有 audioOnly 档 |
| `PlayerHUDOverlay` / HUD 操作区 | 小窗按钮（`Image(systemName: "pip.enter")` / `pip.exit`，仅 `AVPictureInPictureController.isPictureInPictureSupported` 时显示） |
| 设置 | 「退出 App 时自动小窗」开关（控制 `canBeginPictureInPictureAutomatically`，默认开，仅 iOS） |

## 2. 关键机制设计

### 2.1 喂帧管线与分辨率

```
timer 拍 (16ms, 专用队列)
  → pool.acquire() ── 无空闲则丢本拍
  → engine: setFlutterTextureBuffer + render_tick_with_timing
  → onFrame(CVPixelBuffer, pts)
  → CMSampleBufferCreateReadyWithImageBuffer(单帧, formatDesc 来自 CVPixelBuffer)
  → displayLayer.enqueue(sample)          // enqueue 线程安全，可后台队列直调
```

- 初始渲染尺寸：视频宽高比锁定，长边缩到 **min(视频原生, 1280)**（PiP 窗口物理尺寸通常 ~400-700pt，1280 已足够且省解码/带宽）；M2 起 `didTransitionToRenderSize` 跟随窗口实际尺寸。
- PTS：`CMClockGetTime(CMClockGetHostTimeClock()) + 0.1s`（入队到显示的固定提前量），保证单调；暂停时不入队。

### 2.2 controlTimebase（PiP 第一坑，一次调对）

```swift
let timebase = CMTimebase(referenceClock: CMClockGetHostTimeClock(), sourceToken: nil)
timebase.setRate(1.0, time: CMClockGetTime(...))   // 与 PTS 同源，这是帧能显示的前提
displayLayer.controlTimebase = timebase
```

- 暂停/恢复：`setRate(0/1)` + `pipController.invalidatePlaybackState()`；
- App 内 seek（PiP 窗口里按 ±10s）：完成 seek 后 `timebase.setTime(当前 host time)` 并继续入队，`skipByInterval` 的 completion 在此之后调。

### 2.3 PipCoordinator 状态机

```
idle ──startPictureInPicture()──▶ starting ──didStart──▶ active
  ▲                                                    │
  │            didStop(用户关闭)──回 audioOnly 档/暂停 ◀─┤
  └── didStop(withCompletionHandler:) 用户点还原 ◀──────┘
        → restorePlayerUI() → 回前台 → endTextureRendering
```

- **didStart 时 App 可能已在后台且 audioOnly 档已先进**（自动 PiP 由系统在退后台瞬间拉起）：此时 `engine.setBackgroundAudioOnly(false)` → `beginTextureRendering(...)`，内核经 `try_resume_video_decode` 自动恢复解码——这条切换路径内核现成；
- **didStop（用户关 PiP）且 App 仍在后台**：默认切回 audioOnly 档继续出声（与现有「后台听」能力一致）；didStop 带还原 handler 则走回前台恢复全屏；
- 回前台且 PiP 已不活跃：`playbackDidEnterForeground()` 现有逻辑里补「若 texture 档则退档切回 metal layer」。

### 2.4 PiP 控件 ↔ 现有能力映射

| delegate 方法 | 转发目标（全是现成的） |
|---|---|
| `setPlaying(_:)` | `controller.play()` / `pause()`（含 `ErikaAudioSession.activateForPlayback` 既有前置） |
| `skipByInterval` | `controller.seek(by:)`（走既有片尾 margin 钳位） |
| `timeRangeForPlayback()` | `0..duration`（CMTimeRange） |
| `isPlaybackPaused()` | `controller.rate == 0` |
| `didTransitionToRenderSize` | M2：pool 按新尺寸重建 |

播放/暂停/seek 状态变化处调 `invalidatePlaybackState()`（进度条与按钮状态刷新的唯一驱动）。

### 2.5 失败恢复

- `displayLayer.status == .failed` 或 `requiresFlushToResumeDecoding == true`：`flush(removingDisplayedImage: true)` 后等待下一关键帧再入队（内核 render_tick 输出的即完整帧，直接恢复入队即可）；
- 来电/中断：现有 `PlaybackAudioInterruptions.swift` 照常工作（PiP 窗口只是显示层，不碰音频），中断结束恢复后 `invalidatePlaybackState()`；
- 自然播完：现有 `.stopped` 收口（含 PR#68 EOF 折叠）触发 `stopPictureInPicture()`。

## 3. Spike 计划（先行，逐级判据）

| 步骤 | 内容 | 判据 | 失败分支 |
|---|---|---|---|
| S1 | ErikaKit 补封装 + pool，编译+既有测试绿 | 编译过 | — |
| S2 | 前台最小帧流：播放中 `detach metal layer → attach flutter texture`，displayLayer 以缩略图摆在 PlayerScreen 角落（**不进 PiP**） | 角落出现实时画面（即跨 device/通路 OK） | 内核侧问题 → 报上游；期间用 `capture_frame_rgba` 降级通路（720p CPU 拷贝）保 M1 |
| S3 | 包上 `AVPictureInPictureController`，真机点按钮进 PiP | PiP 窗口出画面，播放/暂停按钮可控 | timebase/PTS 细节，按 §2.2 逐项对 |
| S4 | PiP 保持时手动退到主屏（App 后台） | 后台画面持续 ≥10 分钟、无掉帧雪崩、内存平稳 | 后台 tick 被内核拒绝/崩溃 → **NO-GO 主判据**，报上游 |
| S5 | PiP 中点还原回前台 | 全屏恢复无黑屏/闪断（允许 1 次短暂重attach） | 闪断不可接受 → 评估「保留 metal layer 不 detach、双通路共存」需问内核 |

## 4. M1 / M2 范围

**M1（手动 PiP 最小可用）**：§1 全部文件 + §2.1-2.3 + 播放/暂停/进度；不含自动 PiP、skip、分辨率自适应、failed 全路径。预估 3-4 天。

**M2（自动+完善）**：`canBeginPictureInPictureAutomatically` + 设置开关；`skipByInterval`；`didTransitionToRenderSize` 分辨率跟随；failed/中断全路径；iPad 多任务验证。预估 2-3 天。

## 5. 验收与测试

### 单测（随 M1）
- ErikaEngine 三态闸门状态机（display/texture/audioOnly 互切、迟到 tick 丢弃）——照现有后台档测试的写法；
- PipCoordinator delegate 映射（mock engine + mock controller）；
- pool 背压（isReadyForMoreMediaData=false 时不复用未归还 surface）。

### 真机验收清单（iPhone，对照 [ios-simulator-visual-verification] 通道可先行模拟器冒烟）
- [ ] M1：按钮进/出 PiP 各 10 次无闪断；PiP 中播放/暂停/进度正确
- [ ] M1：回前台 surface 恢复，弹幕/HUD 完整回来
- [ ] M2：退后台自动进 PiP；关 PiP 后台继续出声；还原按钮回全屏
- [ ] M2：PiP 中 ±10s、来电中断恢复、锁屏+PiP 共存、自然播完 PiP 自动关
- [ ] 稳定性：PiP 连续 30 分钟，内存水位 vs audioOnly 档无异常增长（Instruments Allocations）
- [ ] 字幕在 PiP 中显示正常（内核渲染）；确认 EDR 片源进 PiP 降 SDR 的观感可接受

## 6. 风险表

| 风险 | 等级 | 缓解 |
|---|---|---|
| 后台视频 tick 内核不支持（S4） | 高 | Spike S4 即 NO-GO 判据；报上游（有 5 个已合并 PR 的合作通道）；方案 B 顶上 |
| 跨 device texture（S2） | 中 | iOS 单 device 基本排除；万一失败用 capture_rgba 降级通路 |
| surface 切换闪断（S5） | 中 | 允许一次重 attach；不可接受再谈双通路（需内核） |
| timer 时序精度 → 音画不同步 | 低 | `render_tick_with_timing` 的 presentation delay 吸收；16ms±4ms 与 audio-only 档同级实证 |
| EDR 观感回退 | 低 | 仅 EDR 片源可见；文档明示 |
| App Store 审核 | 低 | PiP 是标准能力，`UIBackgroundModes: audio` 已声明（PiP 无需额外 background mode） |
