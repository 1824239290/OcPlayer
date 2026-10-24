# iOS 小窗播放（PiP）方案调研

> 调研日期：2026-10-24。结论先行：**走系统级 PiP，用 Erika 内核现成的 flutter texture 渲染通路 + `AVSampleBufferDisplayLayer` + `AVPictureInPictureController`**。这是自绘内核播放器唯一正路（VLC iOS 2025-01 合并的同款路线），项目地基（后台音频档、audio session、RemoteCommands）已备齐，主要风险集中在两个内核侧未知数，建议先做 spike。

## 0. 两条「小窗」路线的区别

| | A. 系统级 PiP | B. App 内迷你浮窗 |
|---|---|---|
| 形态 | 系统悬浮窗，跨 App，可拖到边缘收起 | App 内角落浮窗（B 站站内迷你窗） |
| 技术 | `AVPictureInPictureController` + sample buffer 喂帧 | 纯 SwiftUI 布局态，播放器视图缩角 |
| 内核改动 | 需要（新渲染通路 + 新后台档） | **零**（surface / 驱动全不动） |
| 能力边界 | 窗口内无弹幕（字幕有）；EDR 降 SDR | 一切照旧（弹幕/HUD 都在） |
| 工作量 | 大（估 1-2 周含 spike） | 小（1-2 天） |

两者不互斥：B 可先行落地或长期共存，A 是真「小窗」的主线。

## 1. 为什么没有 AVPlayer 捷径

`AVPlayerLayer` 是 PiP 的零成本入口，但意味着换 AVPlayer 播——丢掉 Erika 的全部（弹幕、字幕样式、ArtCNN、后台音频档、intro-skip、片尾逻辑）。Swiftfin 的 PiP 正是只在它的「Native player」（AVPlayer 路线）里有效，自绘内核路线（VLCKit）至今没有——[Swiftfin issue #998](https://github.com/jellyfin/Swiftfin/issues/998)、[#1760](https://github.com/jellyfin/Swiftfin/issues/1760)（1.4 还出过回归 [#1850](https://github.com/jellyfin/Swiftfin/issues/1850)）。对 OcPlayer 这条路否决。

mpv 上游也无内建支持：[mpv#8910](https://github.com/mpv-player/mpv/issues/8910) 请求 `AVSampleBufferDisplayLayer` VO，至今没有官方实现。**Erika 的 texture 通路反而是现成的**（见 §2.1），内核条件比裸 mpv 好。

## 2. 方案 A：系统级 PiP 技术架构

### 2.1 API 面（已用本机 SDK 头文件核实，非二手资料）

`AVKit/AVPictureInPictureController_AVSampleBufferDisplayLayerSupport.h`：

```objc
// 全部 iOS 15.0+ / tvOS 15.0+ / macOS 12.0+ / visionOS 1.0+
- (instancetype)initWithSampleBufferDisplayLayer:(AVSampleBufferDisplayLayer *)layer
                                playbackDelegate:(id<AVPictureInPictureSampleBufferPlaybackDelegate>)delegate;
```

项目部署目标 iOS 17（`Packages/ErikaKit/Package.swift:8`），无版本障碍；**同一 API macOS 12+ 可用**（见 §6）。PlayBack delegate 关键方法：

| 方法 | 用途 |
|---|---|
| `setPlaying(_:)` | PiP 窗口播放/暂停按钮 → 转发 `PlaybackController` |
| `skipByInterval(_:completion:)` | ±快进退按钮（completion 必须调，否则 UI 卡 seeking） |
| `timeRangeForPlayback()` / `isPlaybackPaused()` | 进度条与状态，配合 `controller.invalidatePlaybackState()` 主动推 |
| `didTransitionToRenderSize(_:)` | **PiP 窗口尺寸变化**——按此缩小离屏渲染分辨率省功耗 |

### 2.2 渲染通路（内核能力已确认，`erika.h:749-761`）

内核头文件原文：*"before every render_tick, select the host-owned GPU target with `set_flutter_texture_buffer`. On Apple, `raw_texture` is an id<MTLTexture> using BGRA8Unorm. The texture remains owned by the host."*

零拷贝喂帧链（WebRTC/Agora 标准做法）：

```
宿主分配 IOSurface
  → MTLTexture(BGRA8Unorm, 同一 IOSurface)          [每 tick]
  → erika_presenter_set_flutter_texture_buffer + render_tick_with_timing
  → CVPixelBuffer(IOSurface backed, 零拷贝)
  → CMSampleBuffer(PTS = host clock, 单调递增)
  → displayLayer.enqueue(_:)
```

要点：
- `displayLayer.controlTimebase = CMTimebase(referenceClock: CMClockGetHostTimeClock(), rate: 1)`，**必须设**，PTS 与 timebase 同源，否则帧不渲染 / PiP 黑屏（[SO #69799535](https://stackoverflow.com/questions/69799535/picture-in-picture-from-avsamplebufferdisplaylayer-not-loading) 最常见坑）。
- 暂停/恢复：`timebase.setRate(0/1)` + `invalidatePlaybackState()`。
- 失败恢复：layer 进 `.failed` / `requiresFlushToResumeDecoding == true` 时必须 `flush()` 再喂（[requiresFlushToResumeDecoding 文档](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/requiresflushtoresumedecoding)）。
- **layer 必须挂在 window 内的视图树上**（可用零尺寸/隐藏 host view）PiP 才能启动。

### 2.3 驱动与档位（关键改造点）

`CADisplayLink` 后台停转（[SO #35977411](https://stackoverflow.com/questions/35977411/can-cadisplaylink-be-run-while-in-application-is-in-background)）。但 **audio-only 后台档已实证 16ms `DispatchSourceTimer` 在后台稳定运行**（`ErikaEngine.swift:501` `setBackgroundAudioOnly`，timer 队列 `dev.jumusu.OcPlayer.audio-only`）。PiP 档同理，只是 tick 类型不同：

| 档位 | 驱动 | tick | 渲染目标 |
|---|---|---|---|
| 前台（现状） | CADisplayLink | `render_tick_with_timing` | CAMetalLayer |
| 后台音频（现状，`ErikaEngine.swift:501`） | DispatchSourceTimer 16ms | `audio_only_tick`（挂起视频解码） | 无 |
| **PiP（新增）** | DispatchSourceTimer 16ms | `render_tick_with_timing` | 宿主 MTLTexture |

surface 互斥：`attach_metal_layer` / `attach_flutter_texture` 共用 `detach_surface`（一 presenter 一 surface）。PiP 激活 = detach metal layer → attach texture；关闭反向。音频完全不动（内核 AudioQueue 自管）。

### 2.4 PiP 控件接线

`AVPictureInPictureSampleBufferPlaybackDelegate`（新 `PipCoordinator` 实现）↔ `PlaybackController` 现有能力一一对应：play/pause/seek 全是现成方法，`skipByInterval` 走既有 seek；`NowPlayingCenter` / `installRemoteCommandHandlers()`（`RootView.swift:166`）已就绪，锁屏控件与 PiP 并行不冲突。

### 2.5 已备齐的地基（无需新增）

- `UIBackgroundModes: audio`（`Config/Info.plist:21`）——PiP 存活的必要条件 ✅
- `AVAudioSession` `.playback` + 每次播放前激活（`ErikaAudioSession.swift:27`）✅
- scenePhase 前后台分叉（`RootView.swift:159-171` → `AppModel+Playback.swift:553`）——PiP 档只需在此分叉出第三条路 ✅

## 3. 风险与未知数（spike 必答项）

1. **后台 `render_tick` 进 texture 从未被验证**（最大风险）：flutter texture 通路为 Flutter 宿主前台设计；audio-only 档挂起视频解码恰是内核对后台的既定姿势。PiP 要求后台继续视频 tick。需 spike 确认内核无主线程/CAMetalLayer 假设、VideoToolbox 在 audio mode 后台持续解码无碍（理论上可以，FaceTime 类 App 如此）。
2. **surface 切换是否闪断**：进/出 PiP 各一次 detach/attach，内核 flush 重建的行为要实测。
3. **timebase/PTS 细节**：同源时钟 + 单调 PTS + 暂停语义，一次调对终身受益，但首调有试错成本（参照 [LiveKit #458](https://github.com/livekit/client-sdk-swift/issues/458)）。
4. **EDR/HDR 降 SDR**：BGRA8Unorm 是 8bit SDR。`AppleEdr` 输出模式下进 PiP 画面动态范围会缩，SDR 内容无感。
5. **PiP 窗口无弹幕**：弹幕是 App 侧 overlay（`DanmakuOverlayHost`），不在内核渲染管线，PiP 窗口看不到；字幕有（内核渲染）。远期可将弹幕合成进纹理。
6. **功耗**：用 `didTransitionToRenderSize` 按窗口尺寸缩渲染，避免全分辨率离屏。

## 4. 方案 B：App 内迷你浮窗（可选先行/共存）

- PlayerScreen 已是 `RootView.swift:79-91` 的全屏 overlay，引入 `mini` 布局态：视频区缩至角落可拖动卡片（保留 gesture 层最小集：点按开 HUD、拖动移位、双击还原/关闭）。
- **零内核改动、零新通路**，风险全在 SwiftUI 布局与手势取舍，估 1-2 天。
- 局限：出 App 即无。可与方案 A 共存（站内迷你 + 站外 PiP）。

## 5. 先例对照

| 播放器 | 内核 | PiP 路线 | 状态 |
|---|---|---|---|
| VLC iOS | libvlc（自绘 GLES/Metal） | sample buffer 喂帧（同方案 A） | 2025-01 合并（[公告](https://x.com/BWidlarz/status/1877317618161340799)），App Store 已上线 |
| react-native-video | ExoPlayer/AVPlayer + 自绘 | 同作者（BWidlarz/TheWidlarzGroup）踩坑记录 | 已上线 |
| Swiftfin | AVPlayer / VLCKit 双路线 | 仅 AVPlayer 路线有 PiP | 自绘路线无 |
| mpv 系 | libmpv | 无内建（[#8910](https://github.com/mpv-player/mpv/issues/8910) open） | 社区靠自行喂帧 |

## 6. 建议切分（若立项）

1. **Spike（1-2 天）**：ErikaKit 封装 `attachFlutterTexture` / `setFlutterTextureBuffer`（现仅 `captureFrameRGBA` 有封装）；前台手动切换 texture 通路喂 displayLayer（不进 PiP），验证帧流与 timebase；再退后台验证 timer 驱动视频 tick。两个未知数在此出结论，不通则回退方案 B 并向内核提需求。
2. **M1 手动 PiP**：HUD 加小窗按钮，`startPictureInPicture()`，surface 切换，播放/暂停控件。
3. **M2 自动 PiP + 完整控件**：`canBeginPictureInPictureAutomatically`、`skipByInterval`、进度条、failed 恢复、分辨率自适应、设置开关。
4. **远期**：弹幕进 PiP、macOS（`ContentSource` macOS 12+ 同款可用，或 IINA 式自定义 borderless 窗——后者无喂帧成本，macOS 上更常见）。

## 参考

- [Adopting Picture in Picture in a custom player（Apple）](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player) / [WWDC21 What's new in AVKit](https://developer.apple.com/videos/play/wwdc2021/10290)
- [Demystifying Picture in Picture on iOS（Artem Novichkov, 2025）](https://artemnovichkov.com/blog/demystifying-picture-in-picture-on-ios)
- [PiP for Live Video Calls（踩坑实录）](https://erseltrhn.medium.com/picture-in-picture-for-live-video-calls-on-ios-the-feature-that-took-3x-longer-than-we-estimated-8bf5ae327ead) / [ForaSoft PiP 指南](https://www.forasoft.com/blog/article/picture-in-picture-mode-on-ios-implementation-and-peculiarities-1662)
- [AVSampleBufferDisplayLayer 文档](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer) / [requiresFlushToResumeDecoding](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/requiresflushtoresumedecoding)
- 项目内坐标：`erika.h:749-761`（texture 通路）、`erika.h:823-840`（tick 族）、`ErikaEngine.swift:501`（后台音频档）、`RootView.swift:159-171`（scenePhase）、`Config/Info.plist:21`（后台音频）
