# Erika 内核弹幕：大文件播放时进程内存飙到 ~2GB

**提交方**：OcPlayer (macOS) 集成方
**内核版本**：Erika v0.1.7（macOS arm64，静态链接，push-model presenter）
**影响**：内核弹幕路线在大（>1GB）媒体文件上内存峰值 = 基线 + ≈ 文件体积，直接顶到 2GB+；App 只能默认关闭内核弹幕、改用自身 overlay 弹幕规避。

## 复现步骤

1. host App 用 `erika_presenter_create_with_config` 建 presenter，`erika_presenter_attach_metal_layer` 挂 CAMetalLayer。
2. `erika_presenter_open_with_headers` 打开 1.8GB MP4（HTTP，Jellyfin `/Videos/{id}/stream?Static=true`，支持 Range）。
3. `erika_presenter_add_danmaku_track_json` 注入一条 3778 条的弹幕 track（约 1-2MB JSON）。
4. `erika_presenter_play` + host 逐帧 `render_tick`。
5. **open 后 ~5 秒内**，进程 `phys_footprint`（task_vm_info）从 ~320MB 跳到 ~2020MB，持续到 `stop()` 后才释放。
   - 同一文件、同一媒体打开流程，**不注入内核弹幕**（走 App overlay 弹幕）时峰值仅 ~390MB → 与媒体本身无关，是内核弹幕激活触发的一笔 ~1.7GB 分配。

## 采样证据（open/播放中每 5s 各打一条）

`erika_presenter_get_resource_status` + `task_vm_info.phys_footprint` 同一时刻读：

| 时刻 | phys_footprint | device_allocated | renderer_tracked | video_frame | danmaku_atlas | danmaku_vertex | cpu_danmaku_atlas | drawable |
|---|---|---|---|---|---|---|---|---|
| open | 321 MB | 1 MB | 0 | 0 | 0 | 0 | 0 | 0 |
| +5s | **2021 MB** | 94 MB | 20.5 MB | 5.9 MB | 1.0 MB | 0 | 1.0 MB | 3 |
| +10s | 2023 MB | 100 MB | 20.3 MB | 5.9 MB | 1.0 MB | 0 | 1.0 MB | 3 |
| +15s | 2025 MB | 100 MB | 20.3 MB | 5.9 MB | 1.0 MB | 0 | 1.0 MB | 3 |
| stop | 2031 MB | 103 MB | 14.5 MB | 0 | 1.0 MB | 0.1 | 0 | 3 |

对照（同一 1.8GB 文件，**无内核弹幕**，App overlay 弹幕）：

| 时刻 | phys_footprint | device_allocated | renderer_tracked | danmaku_atlas |
|---|---|---|---|---|
| 播放中 | 367–389 MB | ~90 MB | ~19.4 MB | 0 |

## 结论与疑点

- ~1.7GB 增量**不在 presenter 记账的任何分项里**（danmaku atlas 只有 1MB、vertex 0、renderer_tracked 20MB、device 95MB），且与文件大小高度相关（1.8GB 文件 → +1.7GB；小文件无此现象）。
- 强烈怀疑：内核弹幕激活后，弹幕时间线/轨道规划触发了对整份媒体的**全量读取/扫描**（把整个 HTTP 文件读进解封装/网络缓冲），或一笔与媒体体积成正比的一次性分配——而 `get_resource_status` 不覆盖这条路径。
- **请求**：
  1. 修正/公开「只在内核弹幕激活时整读媒体」的行为（若为有意为之，希望有上限或流式读取）；
  2. 在 `ErikaPresenterResourceStatus`（或新接口）中加入 HTTP/解封装读取缓冲的字节数，便于宿主观测和告警。

## 附：观测环境

- macOS 25.5 arm64，Metal 软件栈；host App 用 C ABI 每次调用持锁串行化；采样间隔 5s 无画面卡顿影响。
- 复现用的介质：约 29 分钟、1.8GB、H.264 1080p MP4（远程 HTTP）。

## 附 2：对照证据（2026-08-25 追加）

同一进程、同一 1.8GB 文件的 **App overlay 弹幕路线**（不注入内核弹幕）连播多集的进程采样
（`task_vm_info.phys_footprint` + 系统 malloc 各 zone 之和，5s 一次）：

| 阶段 | phys_footprint | malloc | 说明 |
|---|---|---|---|
| 播放中（稳定段） | 330–354 MB | 323–343 MB | malloc 全程恒定，无堆增长 |
| 停止后 5s | 192–287 MB | 222–236 MB | 停止即归还，跨集无残留、基线不抬高 |

结论：**overlay 路线无内存泄漏**，进程内存随播放结束完全回收。2G 峰值严格对应「内核弹幕激活 + 大文件」，
与媒体读取、解码、渲染器、App 侧均无关——进一步收窄到内核弹幕激活时对整份媒体的一次性大分配。
